#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# MessageDisplay LLM rewrite hook  (buffer-to-final, fail-open)
#
# Claude Code fires the MessageDisplay event once PER STREAMED CHUNK of an
# assistant message. Each fire is a separate process and carries:
#   .message_id  groups chunks of one message
#   .index       chunk order (0,1,2,...)
#   .final       true on the last chunk
#   .delta       this chunk's text fragment (NOT cumulative)
#
# To rewrite a whole message we buffer every .delta to disk (keyed by
# message_id) and only call the LLM on the final chunk, once the whole
# message is known.
#
# On the final chunk we also read the RECENT CONVERSATION from
# .transcript_path — the user's newest question with the replies to it so far,
# then the CLAUDISH_CONTEXT_TURNS exchanges before it, oldest first — and pass
# it to the model as CONTEXT ONLY, which helps the rewrite stay on-topic. The
# excerpt counts every message it leaves out, so the model knows the
# conversation is longer than what it sees. The model is told never to rewrite,
# answer, or repeat that context; only the assistant message is rewritten.
# Missing/unreadable transcript -> no context, still rewrites.
#
# FAIL-OPEN CONTRACT: on ANY problem (disabled, no jq, parse error, LLM down,
# timeout, empty rewrite) we emit nothing and exit 0, which leaves Claude's
# ORIGINAL text on screen. A display hook must never be able to swallow the
# assistant's answer.
#
# Config (all via env, with safe defaults):
#   CLAUDISH_ENABLED   1|0            master switch (default 1)
#   CLAUDISH_OFF_FILE  <path>         flag file checked per message; when it
#                                          exists, rewrites pause (default
#                                          ~/.claude/claudish-off) — lets a
#                                          hotkey/script toggle mid-session
#   CLAUDISH_MODE      append|replace display strategy (default append)
#   CLAUDISH_MODEL     <ollama model> (default gemma4:26b-mlx)
#   CLAUDISH_OLLAMA    <base url>     (default http://localhost:11434)
#   CLAUDISH_MIN_CHARS <n>            skip messages shorter than this
#                                           (prose, code stripped) (default 200)
#   CLAUDISH_STUB      1|0            deterministic stub instead of ollama
#                                           (for display-mechanics testing)
#   CLAUDISH_TIMEOUT   <seconds>      LLM client timeout (default 45)
#   CLAUDISH_CONTEXT   1|0            send recent conversation as context
#                                          (default 1); 0 sends the message alone
#   CLAUDISH_CONTEXT_TURNS <n>        exchanges before the current one to
#                                          include, compressed to their user
#                                          message and final reply (default 5)
#   CLAUDISH_CONTEXT_TURN_MSGS <n>    replies kept from the CURRENT exchange,
#                                          newest first (default 3)
#   CLAUDISH_CONTEXT_CHARS <n>        per-message truncation inside that
#                                          context (default 800)
#   CLAUDISH_DEBUG     1|0            write a debug log (default 0)
#   CLAUDISH_NOTICE    1|0            once-per-session on-screen notice when the
#                                           rewrite is skipped because ollama is
#                                           unreachable, times out, or the model
#                                           is missing (default 1)
# ---------------------------------------------------------------------------
set -uo pipefail

ENABLED="${CLAUDISH_ENABLED:-1}"
# Runtime kill switch: env is frozen at session launch, so a hotkey or script
# can't flip CLAUDISH_ENABLED mid-session. A flag file can be checked fresh on
# every invocation. Create it to pause rewrites instantly; remove it to resume.
[ -f "${CLAUDISH_OFF_FILE:-$HOME/.claude/claudish-off}" ] && ENABLED=0
MODE="${CLAUDISH_MODE:-append}"
MODEL="${CLAUDISH_MODEL:-gemma4:26b-mlx}"
OLLAMA="${CLAUDISH_OLLAMA:-http://localhost:11434}"
MIN_CHARS="${CLAUDISH_MIN_CHARS:-200}"
STUB="${CLAUDISH_STUB:-0}"
LLM_TIMEOUT="${CLAUDISH_TIMEOUT:-45}"
CTX_ON="${CLAUDISH_CONTEXT:-1}"
CTX_TURNS="${CLAUDISH_CONTEXT_TURNS:-5}"
CTX_TURN_MSGS="${CLAUDISH_CONTEXT_TURN_MSGS:-3}"
CTX_CHARS="${CLAUDISH_CONTEXT_CHARS:-800}"
DEBUG="${CLAUDISH_DEBUG:-0}"
NOTICE="${CLAUDISH_NOTICE:-1}"

# jq gets these as --argjson numbers, so a non-numeric value must not reach it.
case "$CTX_ON"        in 0|1) ;; *) CTX_ON=1        ;; esac
case "$CTX_TURNS"     in ''|*[!0-9]*) CTX_TURNS=5   ;; esac
case "$CTX_TURN_MSGS" in ''|*[!0-9]*) CTX_TURN_MSGS=3 ;; esac
case "$CTX_CHARS"     in ''|*[!0-9]*) CTX_CHARS=800 ;; esac

BUF_ROOT="${TMPDIR:-/tmp}/claudish-to-english"
SEP=$'\n\n────────────────────────\n💬 In plain English:\n\n'

mkdir -p "$BUF_ROOT" 2>/dev/null || true

dbg() { [ "$DEBUG" = "1" ] && printf '%s [%s] %s\n' "$(date '+%H:%M:%S')" "$$" "$*" >> "$BUF_ROOT/debug.log" 2>/dev/null; return 0; }

# Fail-open: keep the original delta on screen.
pass_through() { dbg "pass_through"; exit 0; }

# Replace this chunk's on-screen text with $1 (a temp file, read and then
# removed here — the opportunistic find below only sweeps buffer DIRECTORIES,
# so without this these would pile up in TMPDIR one per assistant message).
emit() {
  jq -n --rawfile dc "$1" \
    '{hookSpecificOutput:{hookEventName:"MessageDisplay",displayContent:$dc}}' \
    2>/dev/null || { rm -f "$1" 2>/dev/null; pass_through; }
  rm -f "$1" 2>/dev/null
  exit 0
}

# Emit an empty string (used to suppress intermediate chunks in replace mode).
emit_empty() {
  jq -n '{hookSpecificOutput:{hookEventName:"MessageDisplay",displayContent:""}}' 2>/dev/null || pass_through
  exit 0
}

[ "$ENABLED" = "1" ] || pass_through
command -v jq  >/dev/null 2>&1 || pass_through
command -v curl >/dev/null 2>&1 || pass_through

payload="$(cat)"
[ -n "$payload" ] || pass_through

mid="$(printf '%s' "$payload"   | jq -r '.message_id // empty' 2>/dev/null)"
sid="$(printf '%s' "$payload"   | jq -r '.session_id // "nosession"' 2>/dev/null)"
idx="$(printf '%s' "$payload"   | jq -r '(.index // 0) | tostring' 2>/dev/null)"
final="$(printf '%s' "$payload" | jq -r '.final // false' 2>/dev/null)"
tpath="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$mid" ] || pass_through
case "$idx" in ''|*[!0-9]*) idx=0 ;; esac

# Opportunistic cleanup of abandoned buffers (older than 30 min), then of the
# session directories they leave behind once empty.
find "$BUF_ROOT" -mindepth 2 -maxdepth 2 -type d -mmin +30 -exec rm -rf {} + 2>/dev/null || true
find "$BUF_ROOT" -mindepth 1 -maxdepth 1 -type d -empty -mmin +30 -exec rmdir {} + 2>/dev/null || true

mdir="$BUF_ROOT/$sid/$mid"
mkdir -p "$mdir" 2>/dev/null || pass_through

# Persist this chunk's delta exactly (jq -j = no added trailing newline).
printf '%s' "$payload" | jq -j '.delta // ""' > "$mdir/$(printf '%08d' "$idx").part" 2>/dev/null || pass_through
dbg "chunk idx=$idx final=$final mid=$mid mode=$MODE"

# ---- non-final chunks ----------------------------------------------------
if [ "$final" != "true" ]; then
  # append: let the original stream through untouched.
  # replace: suppress the streamed original; the whole rewrite lands on final.
  if [ "$MODE" = "replace" ]; then emit_empty; else pass_through; fi
fi

# ---- final chunk: reconstruct + rewrite ----------------------------------
full="$(cat "$mdir"/*.part 2>/dev/null)"
final_part="$mdir/$(printf '%08d' "$idx").part"

# Prose length gate (strip fenced code blocks, then count non-space chars).
prose_len="$(printf '%s' "$full" \
  | awk 'BEGIN{f=0} /^```/{f=!f; next} f==0{print}' \
  | tr -d '[:space:]' | wc -c | tr -d ' ')"
dbg "final: prose_len=$prose_len min=$MIN_CHARS mode=$MODE full_bytes=${#full}"

cleanup() { rm -rf "$mdir" 2>/dev/null || true; }

# Below threshold -> do not rewrite.
if [ "${prose_len:-0}" -lt "$MIN_CHARS" ]; then
  dbg "skip: below min_chars"
  cleanup
  # replace mode already blanked the intermediate chunks, so it MUST re-show
  # the full original here; append mode already streamed it.
  if [ "$MODE" = "replace" ]; then
    out="$mdir.orig"; printf '%s' "$full" > "$out" 2>/dev/null && emit "$out"
  fi
  pass_through
fi

# ---- obtain the rewrite --------------------------------------------------
rewrite=""
curl_rc=0
err=""
if [ "$STUB" = "1" ]; then
  nparts="$(ls "$mdir"/*.part 2>/dev/null | wc -l | tr -d ' ')"
  rewrite="STUB-SIMPLIFIED ✦ mode=$MODE chunks=$nparts prose_len=$prose_len ✦ (this text came from the hook, not the model)"
  dbg "stub rewrite"
else
  sys="You rewrite the assistant's message into much simpler, plain English. Keep every fact, name, number, and file path. Use short sentences and everyday words. Leave fenced code blocks unchanged. Output ONLY the rewritten message with no preamble, labels, or commentary."

  # Context only: the current exchange (the user's newest question and the
  # replies to it so far), plus the CLAUDISH_CONTEXT_TURNS exchanges before it.
  #
  # An exchange starts at a user message and runs to the next one. Older
  # exchanges are compressed to their user message and final reply, because the
  # replies between those are tool-step preambles that add length without
  # grounding. Every message left out is counted, so the model is told the
  # excerpt is partial rather than being left to assume it is whole.
  #
  # One assistant message spans several transcript lines that share
  # .message.id, so lines are merged by id; blocks that are not text (thinking,
  # tool_use, tool_result) hold no prose and drop out, as do sidechain
  # (subagent) and meta lines. The message being rewritten is excluded — it is
  # the payload, not context. Truncation happens inside jq, which is safe on
  # multibyte boundaries.
  convo=""
  if [ -n "$tpath" ] && [ -f "$tpath" ] && [ "$CTX_ON" = "1" ]; then
    convo="$(jq -rs --argjson t "$CTX_TURNS" --argjson tm "$CTX_TURN_MSGS" \
                    --argjson c "$CTX_CHARS" --arg mid "$mid" '
      def txt:
        if (.message.content | type) == "string" then .message.content
        else [ .message.content[]? | select(.type == "text") | .text // "" ] | join("\n")
        end;
      def fmt:
        "[" + .role + "] "
        + (.text | if length > $c then .[0:$c] + " […truncated]" else . end);
      def render($current):
        (.[0].role == "user") as $hasu
        | (if $hasu then [ .[0] ] else [] end) as $head
        | (if $hasu then .[1:] else . end) as $rest
        | (if $current
           then (if $tm < 1 then []                                    # .[-0:] is .[0:], so 0 needs its own branch
                 elif ($rest | length) > $tm then $rest[-$tm:]
                 else $rest end)
           else (if ($rest | length) > 1 then $rest[-1:] else $rest end)
           end) as $kept
        | (($rest | length) - ($kept | length)) as $cut
        | { n: (($head | length) + ($kept | length)),
            lines: ( ($head | map(fmt))
                     + (if $cut > 0
                        then [ "[… \($cut) more repl\(if $cut == 1 then "y" else "ies" end) in this exchange, not shown]" ]
                        else [] end)
                     + ($kept | map(fmt)) ) };
      [ .[]
        | select((.type == "user" or .type == "assistant")
                 and (.isMeta // false) == false
                 and (.isSidechain // false) == false)
        | { role: (.message.role // .type), id: (.message.id // ""), text: txt }
        | select((.text | gsub("[[:space:]]"; "") | length) > 0)
      ]
      | reduce .[] as $m ([];
          if length > 0 and $m.id != "" and .[-1].id == $m.id
          then .[0:-1] + [ .[-1] | .text += "\n" + $m.text ]
          else . + [$m]
          end)
      | map(select(.id != $mid))
      | length as $total
      | [ foreach .[] as $m (0;
            . + (if $m.role == "user" then 1 else 0 end);
            { ex: ., msg: $m }) ]
      | group_by(.ex)
      | map(map(.msg))
      | (if length > ($t + 1) then .[-($t + 1):] else . end)
      | length as $ng
      | [ to_entries[] | . as $e | ($e.value | render($e.key == $ng - 1)) ]
      | ([ .[].n ] | add // 0) as $shown
      | ($total - $shown) as $hidden
      | if $shown == 0 then ""
        else
          "Recent conversation, oldest first. It shows \($shown) of the \($total) messages in this session"
          + (if $hidden > 0 then "; \($hidden) message(s) are not shown" else "" end)
          + ".\n\n"
          + ([ .[].lines[] ] | join("\n\n"))
        end' "$tpath" 2>/dev/null)"
  fi
  if [ -n "$convo" ]; then
    sys="$sys"$'\n\n'"$convo"$'\n\n'"Use this context only to understand the message. Do NOT rewrite, answer, or repeat any of it — rewrite only the assistant's message that follows."
    dbg "context: convo_bytes=${#convo} turns=$CTX_TURNS turn_msgs=$CTX_TURN_MSGS"
  fi

  req="$(jq -n --arg m "$MODEL" --arg s "$sys" --arg u "$full" \
        '{model:$m,stream:false,think:false,options:{temperature:0.3},messages:[{role:"system",content:$s},{role:"user",content:$u}]}' 2>/dev/null)"
  [ -n "$req" ] || { dbg "req build failed"; cleanup; [ "$MODE" = "replace" ] && { out="$mdir.orig"; printf '%s' "$full" > "$out" && emit "$out"; }; pass_through; }
  resp="$(printf '%s' "$req" | curl -sS --max-time "$LLM_TIMEOUT" \
          -H 'Content-Type: application/json' -X POST "$OLLAMA/api/chat" -d @- 2>/dev/null)"
  curl_rc=$?
  rewrite="$(printf '%s' "$resp" | jq -j '.message.content // empty' 2>/dev/null)"
  err="$(printf '%s' "$resp" | jq -r '.error // empty' 2>/dev/null)"
  dbg "ollama curl_rc=$curl_rc resp_bytes=${#resp} rewrite_bytes=${#rewrite} err=${err:-none}"
fi

# Empty/failed rewrite -> fail open (or re-show original in replace mode).
if [ -z "$rewrite" ]; then
  dbg "empty rewrite -> fail open (curl_rc=$curl_rc)"

  # One-time, per-session notice when the cause is a FIXABLE setup problem:
  # ollama unreachable (curl_rc!=0 — connection refused, timeout, DNS), or
  # ollama up but returning an error (curl_rc=0 with .error set, e.g. the model
  # was never pulled). A merely empty completion — ollama up, no error — stays
  # silent; a notice would be wrong then.
  # The notice only APPENDS one line to the original; it never suppresses
  # content, so the fail-open contract still holds.
  notified="$BUF_ROOT/$sid.notified"
  if [ "$NOTICE" = "1" ] && [ ! -e "$notified" ] && { [ "$curl_rc" != "0" ] || [ -n "${err:-}" ]; }; then
    : > "$notified" 2>/dev/null || true
    last_delta="$(cat "$final_part" 2>/dev/null)"
    if [ "$curl_rc" = "28" ]; then
      why="the rewrite timed out after ${LLM_TIMEOUT}s (model too slow for this message) — raise CLAUDISH_TIMEOUT or set CLAUDISH_MODEL to a smaller model"
    elif [ "$curl_rc" != "0" ]; then
      why="can't reach ollama at $OLLAMA — start it with \`ollama serve\` (see the plugin README)"
    elif printf '%s' "${err:-}" | grep -qi 'not found'; then
      why="ollama model '$MODEL' isn't available — pull it with \`ollama pull $MODEL\`, or set CLAUDISH_MODEL to a model you have"
    else
      why="ollama returned an error: ${err:-unknown}"
    fi
    note=$'\n\n────────────────────────\n'"⚠️ claudish-to-english: $why. Showing Claude's original text unchanged. Shown once per session; set CLAUDISH_NOTICE=0 to silence."
    out="$BUF_ROOT/$sid.$mid.notice"
    if [ "$MODE" = "replace" ]; then
      { printf '%s' "$full"; printf '%s' "$note"; } > "$out" 2>/dev/null
    else
      { printf '%s' "$last_delta"; printf '%s' "$note"; } > "$out" 2>/dev/null
    fi
    cleanup
    emit "$out"
  fi

  cleanup
  if [ "$MODE" = "replace" ]; then
    out="$mdir.orig"; printf '%s' "$full" > "$out" 2>/dev/null && emit "$out"
  fi
  pass_through
fi

# ---- build displayContent for the final chunk ----------------------------
out="$BUF_ROOT/$sid.$mid.out"
if [ "$MODE" = "replace" ]; then
  # Everything before was suppressed; show only the rewrite.
  printf '%s' "$rewrite" > "$out"
else
  # append: keep the streamed original (final chunk = its last delta),
  # then append the simplified version.
  { cat "$final_part" 2>/dev/null; printf '%s' "$SEP"; printf '%s' "$rewrite"; } > "$out"
fi
cleanup
emit "$out"
