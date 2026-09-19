#!/usr/bin/env bash
# fm-process-name-lib.sh - the ONE owner of firstmate's process-name
# vocabulary: given a process path and argv[0], is this an agent, a shell, or
# something else?
#
# The vocabulary is firstmate's, not any one runtime backend's. It started
# inside the tmux adapter because tmux was the only backend reading process
# names; it moved here when a second one needed the same answer, so the two
# adapters cannot drift into disagreeing about what a given name means. Every
# liveness signal, every agent-state verdict, and every agent-process lookup
# across the backends resolves names through this single function.
#
# Dependencies are the caller's to provide, unchanged from when this lived in
# the tmux adapter: fm_harness_path_name (bin/fm-session-lock-lib.sh) and
# fm_cursor_process_matches (bin/fm-cursor-lib.sh). Each sourcing backend
# already loads both.

# fm_process_classify_name: `agent` for a verified harness, `shell` for an idle
# login/interactive shell, `other` for anything else.
fm_process_classify_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the liveness callers fold into `ambiguous` rather than `dead`, so
      # a stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}
