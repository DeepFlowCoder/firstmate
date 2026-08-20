#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates from their update source.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from the update source, then fast-forwards every
# registered secondmate home. Local homes are treehouse worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# UPDATE SOURCE. The repo this home ships its own work to is not necessarily the
# repo firstmate's improvements come from: a captain who keeps a private mirror
# has origin pointing at that mirror, so pulling origin would advance a home to
# its own published state and report success while never seeing an upstream
# commit. The local, gitignored config/update-remote file names the git remote
# the update pulls FROM. Absent, empty, or comment-only means origin, which is
# byte-identical to the behavior before this file existed. A configured remote
# that does not exist in the checkout this run must prove it against is REFUSED
# there, never retried against origin, and the run exits non-zero: an update that
# cannot prove where it is pulling from must stop rather than report a success it
# did not perform.
# Format: the first non-empty, non-comment line, trimmed, holding one git remote
# name made of [A-Za-z0-9._-] and not starting with "-" or "."; anything else is
# a hard error, not a fallback. Secondmate homes inherit the file itself through
# the primary-authoritative contract in bin/fm-config-inherit-lib.sh, so a
# secondmate running its own /updatefirstmate resolves the same source.
#
# WHO THE RESOLVED SOURCE IS PROVEN AGAINST. Only the checkout that owns the
# decision - the primary one this run advances first. A local secondmate home
# inherits the RESULT, not the source: once a configured source is in play, those
# homes advance to the primary's default-branch commit, resolved AFTER the
# firstmate target moved, so a linked worktree or a standalone clone that never
# carries the source remote still lands on exactly what the primary just pulled.
# A remote secondmate route is REFUSED before any network call instead: this host
# cannot prove what a code root on another host pulls from, and that code root has
# its own config/update-remote to set. With no configured source every target
# keeps following origin exactly as before.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" or
# "remote:<name>" here, and the local-HEAD commit mode for local homes under a
# configured source); the same library drives the local-HEAD secondmate sync used
# by fm-spawn.sh and fm-bootstrap.sh, so there is one ff implementation, not
# several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
UPDATE_REMOTE_FILE="$CONFIG/update-remote"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

die() { printf 'fm-update: %s\n' "$1" >&2; exit 1; }

# --- update source ---------------------------------------------------------
# Echo the ff-lib base mode for this run: "origin" when config/update-remote is
# absent or holds nothing, "remote:<name>" when it names a source. Refuses a
# malformed or unsafe file rather than falling back to origin (see header).
resolve_update_base_mode() {
  local line value=""
  [ -e "$UPDATE_REMOTE_FILE" ] || { printf 'origin\n'; return 0; }
  [ -f "$UPDATE_REMOTE_FILE" ] && [ ! -L "$UPDATE_REMOTE_FILE" ] \
    || die "config/update-remote is not a regular file; refusing to guess the update source"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    value=$line
    break
  done < "$UPDATE_REMOTE_FILE"
  [ -n "$value" ] || { printf 'origin\n'; return 0; }
  case "$value" in
    -*|.*|*[!A-Za-z0-9._-]*)
      die "config/update-remote: '$value' is not a valid git remote name; refusing to fall back to origin"
      ;;
  esac
  printf 'remote:%s\n' "$value"
}

BASE_MODE=$(resolve_update_base_mode) || exit 1

# --- main firstmate repo ---------------------------------------------------

FF_REFUSALS=0
reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" "$BASE_MODE" no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.
#
# Local homes follow the primary's RESULT under a configured source (see header):
# the base is the primary's default-branch commit read now, after the firstmate
# target advanced, so a home inherits the new state rather than the previous one.
# FF_LOCAL_BASE_FETCH_FROM lets a standalone-clone home, which has its own object
# store, obtain that commit from the primary. Unconfigured runs pass the origin
# base mode straight through, unchanged.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

SECONDMATE_BASE_MODE=$BASE_MODE
case "$BASE_MODE" in
  remote:*)
    if primary_commit=$(primary_head_commit "$FM_ROOT"); then
      SECONDMATE_BASE_MODE=$primary_commit
      FF_LOCAL_BASE_FETCH_FROM=$FM_ROOT
    else
      SECONDMATE_BASE_MODE=""
      echo "secondmates: skipped: the primary checkout has no default-branch commit to follow" >&2
    fi
    ;;
esac

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
[ -z "$SECONDMATE_BASE_MODE" ] || sweep_live_secondmate_metas "$STATE" "$SECONDMATE_BASE_MODE" no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      echo "secondmate registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      # A remote code root resolves its OWN update source, which this host can
      # neither read nor prove. Refuse before any network call rather than
      # delegate and report whatever that host happened to pull.
      case "$BASE_MODE" in
        remote:*)
          FF_REFUSALS=$((FF_REFUSALS + 1))
          echo "remote secondmate $id: refused on $SECONDMATE_REGISTRY_HOST: this run pulls from the configured update source '${BASE_MODE#remote:}', which cannot be proven there; set config/update-remote in that host's code root $SECONDMATE_REGISTRY_ROOT"
          continue
          ;;
      esac
      if remote_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST (${remote_result#synced: })"
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
            fi
            ;;
          current:*) echo "remote secondmate $id: already current on $SECONDMATE_REGISTRY_HOST (${remote_result#current: })" ;;
          *) echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      [ -z "$SECONDMATE_BASE_MODE" ] || process_secondmate "$id" "$home" "" "$SECONDMATE_BASE_MODE" no
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"

# A target refused for an unprovable configured update source is a failed run,
# not a quiet skip: nothing was pulled from origin in its place.
if [ "$FF_REFUSALS" -gt 0 ]; then
  die "$FF_REFUSALS target(s) refused: ${BASE_MODE#remote:} is the configured update source (config/update-remote) but could not be proven there; nothing was updated from another source instead"
fi
