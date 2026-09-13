#!/usr/bin/env bash
# Pin gh's implicit base repository so an unnamed gh or gh-axi query in a fleet
# repository cannot answer for a different repository.
#
# bin/fm-gh-repo-lib.sh owns WHY and the exact rule, including which remote is
# pinned, why an existing pin is never overwritten, and why naming another
# repository explicitly keeps working. This script is that rule's executable
# surface: one repository at a time, or a sweep over this home's own checkout.
#
# Usage: fm-gh-base-repo.sh pin <repo-dir>
#          Pin one repository. Prints "<outcome>: <detail>" - pinned, unchanged,
#          skipped, or failed - and exits 0. An unpinnable repository is a
#          reported outcome, not a failure: there is no repository to guess at.
#          bin/fm-gh-repo-lib.sh owns what each outcome means.
#        fm-gh-base-repo.sh sweep
#          Pin this home's own firstmate checkout, and only it. Prints one
#          "pinned: <detail>" line when it CHANGED and one "failed: <detail>"
#          line when the write did not go through, and nothing otherwise, so a
#          converged home is silent and bin/fm-bootstrap.sh can relay a real
#          change as a BOOTSTRAP_INFO fact and a real failure as an actionable
#          one. A pin that fails silently is the worst outcome available here:
#          the fix looks applied, is not, and the session summary keeps naming
#          the wrong repository forever. Exits 0.
#
# Every path here is offline and idempotent: it resolves remotes already
# configured and writes at most one git config key, so a session that runs the
# sweep on every start converges once and stays silent afterwards. It never
# touches a working tree, a branch, or a commit.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-forge-remote-lib.sh
. "$SCRIPT_DIR/fm-forge-remote-lib.sh"
# shellcheck source=bin/fm-gh-repo-lib.sh
. "$SCRIPT_DIR/fm-gh-repo-lib.sh"

# The header above IS the help, read to its own end rather than to a line number
# a later edit would silently truncate.
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

pin_one() {  # <repo-dir>; echoes "<outcome>\t<detail>"
  fm_gh_repo_base_pin "$1"
}

case "${1-}" in
  pin)
    [ -n "${2-}" ] || { echo "usage: fm-gh-base-repo.sh pin <repo-dir>" >&2; exit 2; }
    answer=$(pin_one "$2")
    printf '%s: %s\n' "${answer%%$'\t'*}" "${answer#*$'\t'}"
    ;;
  sweep)
    # This home's own checkout, and only it. It is the repository whose
    # session-start summary reported another repository's issues and pull
    # requests under this repository's name, which is the symptom an operator
    # actually sees.
    #
    # A project clone is deliberately NOT swept. bin/fm-spawn.sh settles every
    # clone the fleet actually works in - a task worktree is a linked worktree,
    # so that pin lands in the clone's own shared config - and pinning a clone
    # the fleet never spawns into would decide something that is not this rule's
    # to decide: the base repository also governs where an unnamed publish goes,
    # so in a fork-and-contribute project it would redirect a pull request away
    # from the parent it was meant for. What is given up is the operator's own
    # ad-hoc unnamed call in a clone the fleet has never entered, where AGENTS.md
    # already says to name the repository.
    #
    # A clone root only. git discovery walks up, so a home that is itself a plain
    # directory inside another repository would otherwise resolve to - and be
    # pinned as - the enclosing one.
    if [ -d "$FM_ROOT" ] \
      && top=$(git -C "$FM_ROOT" rev-parse --show-toplevel 2>/dev/null) \
      && top_real=$(cd "$top" 2>/dev/null && pwd -P) \
      && root_real=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) \
      && [ "$top_real" = "$root_real" ]; then
      answer=$(pin_one "$FM_ROOT")
      case "$answer" in
        pinned$'\t'*) printf 'pinned: %s\n' "${answer#*$'\t'}" ;;
        failed$'\t'*) printf 'failed: %s\n' "${answer#*$'\t'}" ;;
      esac
    fi
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
