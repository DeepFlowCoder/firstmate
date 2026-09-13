#!/usr/bin/env bash
# Pin gh's implicit base repository so an unnamed gh or gh-axi query in a fleet
# repository cannot answer for a different repository.
#
# bin/fm-gh-repo-lib.sh owns WHY and the exact rule, including which remote is
# pinned, why an existing pin is never overwritten, and why naming another
# repository explicitly keeps working. This script is that rule's executable
# surface: one repository at a time, or a sweep over everything this home reaches.
#
# Usage: fm-gh-base-repo.sh pin <repo-dir>
#          Pin one repository. Prints "<outcome>: <detail>" - pinned, unchanged,
#          skipped, or failed - and exits 0. An unpinnable repository is a
#          reported outcome, not a failure: there is no repository to guess at.
#          bin/fm-gh-repo-lib.sh owns what each outcome means.
#        fm-gh-base-repo.sh sweep
#          Pin this home's own firstmate checkout and every clone root under its
#          projects dir. Prints one "pinned: <detail>" line per repository that
#          CHANGED and nothing else, so a converged fleet is silent and
#          bin/fm-bootstrap.sh can relay a real change as a BOOTSTRAP_INFO fact.
#          Exits 0.
#        fm-gh-base-repo.sh slug <url>
#          Print the owner/repo a github.com URL names, or exit 1 printing
#          nothing. This is the only spelling that actually names a repository to
#          gh-axi; see the library header.
#
# Every path here is offline and idempotent: it resolves remotes already
# configured and writes at most one git config key per repository, so a session
# that runs the sweep on every start converges once and stays silent afterwards.
# The sweep writes into project clones for the same reason bin/fm-fleet-sync.sh
# does, and like it, it never touches a working tree, a branch, or a commit.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

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
  slug)
    [ -n "${2-}" ] || { echo "usage: fm-gh-base-repo.sh slug <url>" >&2; exit 2; }
    slug=$(fm_gh_repo_slug "$2") || exit 1
    printf '%s\n' "$slug"
    ;;
  sweep)
    # The home's own checkout first: it is the repository whose session-start
    # summary reported another repository's issues and pull requests under this
    # repository's name, which is the symptom an operator actually sees.
    for dir in "$FM_ROOT" "$PROJECTS"/*; do
      [ -d "$dir" ] || continue
      # A clone root only. git discovery walks up, so a plain nested directory
      # would otherwise resolve to - and be pinned as - the enclosing repository.
      top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || continue
      top_real=$(cd "$top" 2>/dev/null && pwd -P) || continue
      dir_real=$(cd "$dir" 2>/dev/null && pwd -P) || continue
      [ "$top_real" = "$dir_real" ] || continue
      answer=$(pin_one "$dir")
      case "$answer" in
        pinned$'\t'*) printf 'pinned: %s\n' "${answer#*$'\t'}" ;;
      esac
    done
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
