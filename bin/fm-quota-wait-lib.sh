#!/usr/bin/env bash
# Observed provider-quota waits, independent of a worker-written paused: line.
# Requires fm-backend.sh for the task reader; the screen predicate is pure.
#
# Codex quota recognition requires the usage-limit and rate-limit strings
# from 2026-10-06, anchored to the modal footer from the September capture.
# The regression viewport is reconstructed, not a full live capture; provenance
# and the deliberately excluded Claude case live in docs/verification/vendor-dialogs.md.
# This is observation only: it authorizes no keypress, model switch or quota reset.
# An unsupported harness/backend, unreadable viewport or unproven live agent
# establishes no wait and leaves ordinary supervision in force.

fm_quota_wait_screen() {  # <harness> <visible-capture>
  local flat
  [ "${1-}" = codex ] || return 1
  flat=$(printf '%s' "${2-}" | tr '\n\r\t' '   ' | tr -s ' ')
  case "$flat" in
    *"You've hit your usage limit"*'Approaching rate limits'*'Press enter to confirm or esc to go back'*) return 0 ;;
  esac
  return 1
}

fm_quota_wait_task() {  # <state-dir> <task-id>
  local meta="$1/$2.meta" harness backend target capture
  [ -f "$meta" ] || return 1
  harness=$(sed -n 's/^harness=//p' "$meta" | tail -1)
  [ "$harness" = codex ] || return 1
  # A remote endpoint belongs to that host's supervisor, never a local capture.
  [ -z "$(sed -n 's/^remote_host=//p' "$meta" | tail -1)" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  # Never read scrollback: the old error can survive a resumed or exited worker.
  capture=$(fm_backend_capture_visible "$backend" "$target" 2>/dev/null) || return 1
  fm_quota_wait_screen "$harness" "$capture" || return 1
  [ "$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null)" = alive ]
}
