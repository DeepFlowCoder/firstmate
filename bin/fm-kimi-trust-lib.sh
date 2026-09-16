#!/usr/bin/env bash
# fm-kimi-trust-lib.sh - the ONE owner of Kimi Code's workspace-trust dialog
# contract: how to recognize the dialog, which row may be selected, when
# selecting anything at all is refused, and how an accepted grant is proven.
#
# Measured 2026-09-15 against the real Kimi Code CLI 0.43.0 (vendor source:
# @moonshot-ai/kimi-code dist/main.mjs, src/tui/components/dialogs/trust-prompt.ts).
# The adapter row in .agents/skills/harness-adapters/references/harness/kimi.md
# and docs/verification/runtime-backends.md carry the operator-facing record;
# this file carries the executable contract.
#
# WHY THIS EXISTS. Kimi asks "Trust this folder?" the first time it launches in
# a workspace root it has no trust record for. The adapter reference used to
# claim no dialog existed, because firstmate's own pooled worktree paths are
# reused and were granted trust once, long before the claim was written - so
# firstmate-repo spawns stopped seeing it while every FRESH project worktree
# still met it, aborted the spawn at the ready gate, and never received a brief.
#
# WHY KEYS AND NOT A FLAG. The Cursor adapter simply launches with `--trust`.
# Kimi has no equivalent: no trust flag, no trust environment override, and a
# programmatic `trustWorkspace` only on the ACP/RPC surface `kimi acp` serves
# rather than on the interactive CLI. Answering the dialog is the only in-band
# route, and docs/verification/runtime-backends.md records that search.
#
# THE DIALOG, EXACTLY AS THE VENDOR BUILDS IT:
#
#   OPTIONS = [ {value:"trust",    label:"Trust this folder"},
#               {value:"distrust", label:"Don't trust"} ]
#   selectedIndex starts at 0; Up clamps with Math.max(0, i-1) and Down clamps
#   with Math.min(len-1, i+1), so NEITHER wraps. Enter and Space select the
#   highlighted row. Escape selects "distrust" outright.
#   The highlighted row is marked with a hardcoded "❯" (pointer = selected ?
#   "❯" : " "), not a theme symbol and not colour alone, so it survives a plain
#   pane capture.
#
# THE ROW THAT KILLS THE WORKER. "Don't trust" is "Exit Kimi Code" - selecting
# it ends the process with status 0 and writes no record, which reads to a
# supervisor exactly like a worker that quit on its own. On 0.43.0 the dialog
# opens on the accept row, but the captain measured an earlier build that opened
# on the refuse row. A fixed key recipe is therefore wrong in one direction or
# the other depending on the build, which is why NOTHING here presses Enter on a
# position it assumed: fm_kimi_trust_accept_is_selected must first read the "❯"
# back on the accept row from a live capture. Up is used to reach it because Up
# clamps at the top, so a press that is already correct costs nothing.
#
# THE MCP CONSEQUENCE. Accepting is not cosmetic: it starts this repo's
# project-level MCP servers. Kimi merges three files (vendor
# resolveMcpJsonPaths), of which exactly two are project-level and gated by
# trust:
#
#   <project root>/.mcp.json   project root = nearest git worktree root from cwd
#   <cwd>/.kimi-code/mcp.json
#
# (the third, <KIMI_CODE_HOME>/mcp.json, is user-global and not gated).
# Firstmate never starts servers nobody reviewed, so a worktree that declares
# any project-level MCP server is REFUSED rather than accepted - the captain
# decides, exactly as AGENTS.md section 9 requires for security-sensitive
# choices. Two independent signals answer that question and either one refuses:
# Kimi's own rendered "Project MCP targets:" list, and firstmate's own read of
# the two files above. An unreadable or malformed declaration file also refuses,
# because "cannot tell" is not "declares nothing".
#
# Every function here is pure apart from reading files the caller names. It
# sends no key, runs no backend command, and writes nothing, so a test can
# source it as a contract.

# The vendor strings this contract keys on, named once.
#
# WIDTH MATTERS when choosing these. The vendor renders the title and the
# navigation hint with a direct `lines.push`, but puts the workspace path and
# the long "Project-level MCP servers are disabled until you explicitly choose
# Trust." sentence through `wrapTextWithAnsi(text, max(20, width - 2))`, then
# truncates every line to the pane width at the end. Measured at 60 columns,
# that sentence really does break across three lines. Keying detection on it
# would therefore stop matching on a narrow pane, the dialog would go
# unrecognized, and the launch would fall through to exactly the ready-timeout
# abort this contract exists to prevent. So detection uses the two lines the
# vendor never wraps, and matches them by short leading fragments that survive
# end-truncation far below any usable pane width.
FM_KIMI_TRUST_TITLE='Trust this folder?'
FM_KIMI_TRUST_HINT_RE='navigate.*Enter select'
FM_KIMI_TRUST_ACCEPT_LABEL='Trust this folder'
FM_KIMI_TRUST_MCP_HEADING='Project MCP targets:'
FM_KIMI_TRUST_POINTER='❯'

# fm_kimi_trust_prompt_present: whether <pane> is showing the trust dialog.
# Two independent vendor signals must BOTH be present - the dialog title and its
# navigation hint - so an ordinary agent turn that happens to quote one of them
# back (a worker reading this very file, for instance) is not mistaken for a
# dialog that is waiting on a keypress.
#
# The hint is matched as "navigate" and "Enter select" on one line rather than
# as its literal text, because the separator between them is a vendor glyph and
# nothing here should depend on how a terminal renders it.
fm_kimi_trust_prompt_present() {  # <pane>
  printf '%s\n' "${1-}" | grep -Fq "$FM_KIMI_TRUST_TITLE" || return 1
  printf '%s\n' "${1-}" | grep -Eq "$FM_KIMI_TRUST_HINT_RE" || return 1
  return 0
}

# fm_kimi_trust_accept_is_selected: whether the dialog's highlight is currently
# on the accept row. This is the ONLY thing that authorizes a select keypress.
# It demands the pointer glyph and the accept label on one line, so a pane where
# the highlight is absent, unreadable, or truncated answers no and the caller
# refuses rather than pressing Enter into an unknown position.
fm_kimi_trust_accept_is_selected() {  # <pane>
  printf '%s\n' "${1-}" \
    | grep -q "${FM_KIMI_TRUST_POINTER}[[:space:]]\{1,\}${FM_KIMI_TRUST_ACCEPT_LABEL}\([[:space:]]\|$\)"
}

# fm_kimi_trust_rendered_mcp_targets: the project MCP servers KIMI ITSELF says
# this grant would start, read off the dialog. Prints one trimmed target line
# per server and nothing at all when the dialog lists none. This is signal one
# of the two-signal refusal: it is the vendor's own verdict over its own merge
# of the project files, so it stays correct even if the file layout changes
# under us.
#
# Two things end the list. The vendor's own blank line before the option rows is
# the ordinary one. The accept row is the backstop, and it is not redundant: a
# reader that drops blank lines would otherwise collect the option rows
# themselves as targets, and that refuses EVERY launch meeting the dialog rather
# than failing harmlessly. Only the accept row is checked, because the vendor
# renders it before the refuse row. Both the heading and that label reach awk
# through -v rather than being written into the program text, so the apostrophe
# in the refuse label is never escaped and nothing here depends on how one awk
# implementation reads \x27 (BWK awk and gawk differ from mawk, which is
# Ubuntu CI's default).
fm_kimi_trust_rendered_mcp_targets() {  # <pane>
  printf '%s\n' "${1-}" \
    | awk -v heading="$FM_KIMI_TRUST_MCP_HEADING" \
          -v accept="$FM_KIMI_TRUST_ACCEPT_LABEL" '
    index($0, heading) { collecting = 1; next }
    collecting {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") { collecting = 0; next }
      if (index(line, accept)) { collecting = 0; next }
      print line
    }
  '
}

# fm_kimi_trust_declared_mcp_files: the two trust-gated project MCP files for a
# worktree, printed as "<path>" one per line whether or not they exist. Named
# separately from the reader below so a caller can report the exact paths it
# consulted.
fm_kimi_trust_declared_mcp_files() {  # <worktree>
  local wt=${1-}
  printf '%s/.mcp.json\n' "$wt"
  printf '%s/.kimi-code/mcp.json\n' "$wt"
}

# fm_kimi_trust_declared_mcp_servers: firstmate's own read of those files, which
# is signal two. Prints one "<path>: <server-or-reason>" line per declaration
# found and nothing when the worktree declares none. An existing file that
# cannot be parsed prints a reason line instead of being silently skipped, so
# "cannot tell" refuses exactly like "declares one".
#
# The worktree IS the project root for a task worktree, which is what Kimi's own
# nearest-git-worktree resolution returns for a cwd of <worktree>; a caller that
# launches Kimi somewhere else must pass that directory instead.
fm_kimi_trust_declared_mcp_servers() {  # <worktree>
  local wt=${1-} file names
  while IFS= read -r file; do
    [ -e "$file" ] || continue
    if ! command -v jq >/dev/null 2>&1; then
      printf '%s: unreadable (jq is required to tell what it declares)\n' "$file"
      continue
    fi
    if ! names=$(jq -r 'if (.mcpServers | type) == "object" then (.mcpServers | keys[]) else empty end' \
                   "$file" 2>/dev/null); then
      printf '%s: unreadable (malformed JSON)\n' "$file"
      continue
    fi
    [ -n "$names" ] || continue
    printf '%s\n' "$names" | while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf '%s: %s\n' "$file" "$name"
    done
  done <<EOF
$(fm_kimi_trust_declared_mcp_files "$wt")
EOF
  return 0
}

# fm_kimi_trust_home: Kimi's data root, resolved the way the vendor resolves it
# (resolveKimiHome: KIMI_CODE_HOME, else $HOME/.kimi-code).
fm_kimi_trust_home() {
  printf '%s' "${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}"
}

# fm_kimi_trust_record_present: whether Kimi has a durable trust grant for
# <worktree>. This is the accepted grant's POSTCONDITION, and it is deliberately
# not a rendered one: Kimi writes {"root":...,"trustedAt":...} into
# <kimi home>/workspace-trust/wd_<slug>_<hash>, so a grant that landed is
# provable from disk even if the pane never redraws legibly.
#
# The records are matched on their own "root" field rather than by recomputing
# the vendor's key hash, and both the given and the physically resolved path are
# accepted because a worktree reached through a symlinked parent records its
# real path.
fm_kimi_trust_record_present() {  # <worktree>
  local wt=${1-} dir real file root
  [ -n "$wt" ] || return 1
  dir=$(fm_kimi_trust_home)/workspace-trust
  [ -d "$dir" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  wt=${wt%/}
  real=$(cd "$wt" 2>/dev/null && pwd -P) || real=$wt
  for file in "$dir"/*; do
    [ -f "$file" ] || continue
    root=$(jq -r '.root // empty' "$file" 2>/dev/null) || continue
    root=${root%/}
    [ -n "$root" ] || continue
    if [ "$root" = "$wt" ] || [ "$root" = "$real" ]; then
      return 0
    fi
  done
  return 1
}
