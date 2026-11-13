#!/usr/bin/env bash
# Codex foreground-checkpoint continuation receipts.
# A Stop request is a single-use random token bound to the canonical home and
# session. A checkpoint snapshots that request BEFORE watching and acknowledges
# it only after an actionable wake or a quiet timeout (0/124). A failed,
# interrupted, pre-request, or other-session checkpoint cannot renew a Stop.
# The guard rotates the request under a lock before granting each continuation.
# Callers provide STATE and FM_HOME; checkpoint sessions use CODEX_THREAD_ID,
# the guard uses the native Stop payload's session_id.

fm_codex_continuity_paths() {
  local session=$1
  case "$session" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
  FM_CODEX_REQUEST="$STATE/.codex-stop-$session"
  FM_CODEX_RECEIPT="$STATE/.codex-checkpoint-$session"
  FM_CODEX_HOME=$(cd "$FM_HOME" && pwd -P) || return 1
}

fm_codex_checkpoint_request() {
  fm_codex_continuity_paths "${CODEX_THREAD_ID:-}" || return 0
  jq -cer --arg home "$FM_CODEX_HOME" --arg session "$CODEX_THREAD_ID" '
    select(.home == $home and .session == $session and (.request | type == "string"))
  ' "$FM_CODEX_REQUEST" 2>/dev/null || true
}

fm_codex_checkpoint_complete() {
  local request=$1 tmp
  [ -n "$request" ] || return 0
  fm_codex_continuity_paths "${CODEX_THREAD_ID:-}" || return 1
  tmp=$(mktemp "$STATE/.codex-checkpoint.XXXXXX") || return 1
  printf '%s\n' "$request" > "$tmp" && mv -f "$tmp" "$FM_CODEX_RECEIPT"
}

fm_codex_continue() {
  local session=$1 repeated=$2 tmp granted=0 lock
  fm_codex_continuity_paths "$session" || return 1
  lock="$FM_CODEX_REQUEST.lock"
  fm_lock_try_acquire "$lock" || return 1
  if [ "$repeated" = false ]; then
    granted=1
  elif [ -f "$FM_CODEX_REQUEST" ] && [ -f "$FM_CODEX_RECEIPT" ] &&
    jq -es --arg home "$FM_CODEX_HOME" --arg session "$session" '
      length == 2 and .[0] == .[1] and
      .[0].home == $home and .[0].session == $session and
      (.[0].request | type == "string")
    ' "$FM_CODEX_REQUEST" "$FM_CODEX_RECEIPT" >/dev/null 2>&1; then
    granted=1
  fi
  if [ "$granted" -eq 1 ]; then
    tmp=$(mktemp "$STATE/.codex-stop.XXXXXX") || granted=0
    if [ "$granted" -eq 1 ]; then
      jq -cn --arg home "$FM_CODEX_HOME" --arg session "$session" --arg request "${tmp##*/}" \
        '{home:$home,session:$session,request:$request}' > "$tmp" &&
        mv -f "$tmp" "$FM_CODEX_REQUEST" || granted=0
    fi
  fi
  fm_lock_release "$lock"
  [ "$granted" -eq 1 ]
}
