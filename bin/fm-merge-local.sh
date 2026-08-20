#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# After a successful landing it PRINTS the captain's pull command, ready to
# paste. It never runs anything in the captain's copy and never changes it; the
# only thing it reads there is which branch that copy is parked on. The three
# failures that command has already caused, all measured 2026-08-19:
#   - The captain's terminal is about 56 columns wide, and a paste inserts a
#     REAL newline at the last space that fits, so zsh runs two commands: a
#     mutilated first half that silently drops flags, and a second half that
#     fails on its own. One `git pull` broke at 53 and at 18 characters across
#     three attempts. Worst recorded case: a `git pull <long path>` split INSIDE
#     the path becomes a fetch against the WRONG repository. So every emitted
#     line stays at or under FM_LANDING_LINE_MAX characters, a long path is
#     built up across several short assignment lines instead of being wrapped,
#     and the block is verified against that cap before it is printed - an
#     over-long line suppresses the block loudly rather than shipping a command
#     that breaks where nobody is looking.
#   - "just run git pull" is harmful advice when the captain's copy is parked on
#     another branch, so the command switches first and the `&&` chain stops if
#     that switch cannot happen.
#   - A landing that changed the dependency manifest leaves the captain's
#     node_modules behind, and that failure surfaces much later and disguised
#     (ERR_MODULE_NOT_FOUND, mid-way through a six-step production sequence), so
#     the install step is emitted with the pull. Which package manager to name
#     is read from the repo; when the repo does not say, no command is invented.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

# --- the captain's landing command ------------------------------------------
# See this script's header for the three failures every rule below closes.

# Widest line the captain's terminal can take from a paste without breaking it.
FM_LANDING_LINE_MAX=50

LANDING_LINES=()

landing_quote() {  # <string> -> LANDING_QUOTED: single-quoted for a shell line
  LANDING_QUOTED="'${1//\'/\'\\\'\'}'"
}

# landing_assign <var> <value>: append assignment lines that build <value> in
# <var>, each within the cap. A value that fits goes on one line; a longer one
# is split across `var=$var'...'` continuations, so the split points are chosen
# HERE, at safe boundaries, instead of being chosen by the captain's terminal in
# the middle of a path. Fails only if a single character cannot fit.
landing_assign() {
  local var=$1 val=$2 piece cand line first=1
  [ -n "$val" ] || return 1
  while [ -n "$val" ]; do
    piece=
    while [ -n "$val" ]; do
      cand=$piece${val:0:1}
      landing_quote "$cand"
      if [ "$first" = 1 ]; then line="$var=$LANDING_QUOTED"; else line="$var=\$$var$LANDING_QUOTED"; fi
      [ "${#line}" -le "$FM_LANDING_LINE_MAX" ] || break
      piece=$cand
      val=${val:1}
    done
    [ -n "$piece" ] || return 1
    landing_quote "$piece"
    if [ "$first" = 1 ]; then
      LANDING_LINES+=("$var=$LANDING_QUOTED")
      first=0
    else
      LANDING_LINES+=("$var=\$$var$LANDING_QUOTED")
    fi
  done
}

# landing_install_cmd: the install command this repo itself names, or nothing.
# A missing answer stays missing: guessing a package manager is how the captain
# gets told to run a command their project does not use.
landing_install_cmd() {
  local declared=
  [ -f "$PROJ/package.json" ] || return 1
  declared=$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([a-z]*\)@.*/\1/p' "$PROJ/package.json" | head -1)
  case "$declared" in
    npm|pnpm|yarn|bun) printf '%s install\n' "$declared"; return 0 ;;
  esac
  if [ -f "$PROJ/pnpm-lock.yaml" ]; then printf 'pnpm install\n'; return 0; fi
  if [ -f "$PROJ/yarn.lock" ]; then printf 'yarn install\n'; return 0; fi
  if [ -f "$PROJ/bun.lockb" ] || [ -f "$PROJ/bun.lock" ]; then printf 'bun install\n'; return 0; fi
  if [ -f "$PROJ/package-lock.json" ]; then printf 'npm install\n'; return 0; fi
  return 1
}

landing_touched_manifest() {  # <from> <to>
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "${f##*/}" in package.json) return 0 ;; esac
  done < <(git -C "$PROJ" diff --name-only "$1" "$2" 2>/dev/null || true)
  return 1
}

# The captain's working copy IS this clone's origin on a local-only project;
# firstmate never pushes there, which is why the landing is invisible until they
# pull. Anything else (a real remote, a bare repo, a missing path) means this
# topology does not hold, and then no command is emitted at all.
CAPTAIN_COPY=$(git -C "$PROJ" remote get-url origin 2>/dev/null || true)
case "$CAPTAIN_COPY" in file://*) CAPTAIN_COPY=${CAPTAIN_COPY#file://} ;; esac
if [ -z "$CAPTAIN_COPY" ] || [ ! -d "$CAPTAIN_COPY" ] \
  || [ "$(git -C "$CAPTAIN_COPY" rev-parse --is-bare-repository 2>/dev/null || echo true)" != false ]; then
  echo "note: origin of $PROJ is not a local working copy, so no paste-ready landing command was emitted."
  exit 0
fi
COPY_BRANCH=$(git -C "$CAPTAIN_COPY" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

INSTALL_CMD=
TOUCHED_MANIFEST=0
if landing_touched_manifest "$before" "$after"; then
  TOUCHED_MANIFEST=1
  INSTALL_CMD=$(landing_install_cmd || true)
fi

# Build the block: every path lands in a variable first, then one `&&` chain, so
# a step that cannot run stops the ones after it instead of running in the wrong
# directory or on the wrong branch.
LANDING_OK=1
landing_assign fmw "$CAPTAIN_COPY" || LANDING_OK=0
landing_assign fmc "$PROJ" || LANDING_OK=0

# landing_chain <branch-expression>: the steps the captain pastes, in order.
# The `$fmw` / `$fmc` references stay literal on purpose - they are text for the
# captain's shell, not expansions for this one, and they are what keeps a long
# path off a line that would break on paste.
# shellcheck disable=SC2016
landing_chain() {
  CHAIN=('cd "$fmw"')
  [ "$COPY_BRANCH" = "$DEFAULT" ] || CHAIN+=("git switch $1")
  CHAIN+=("git pull \"\$fmc\" $1")
  [ -z "$INSTALL_CMD" ] || CHAIN+=("$INSTALL_CMD")
}

landing_chain "$DEFAULT"
# A branch name long enough to push a chain line over the cap goes into its own
# variable too, rather than being emitted as a line that will break on paste.
for line in "${CHAIN[@]}"; do
  if [ "$(( ${#line} + 3 ))" -gt "$FM_LANDING_LINE_MAX" ]; then
    landing_assign fmb "$DEFAULT" || LANDING_OK=0
    landing_chain "\"\$fmb\""
    break
  fi
done
i=0
for line in "${CHAIN[@]}"; do
  i=$((i + 1))
  [ "$i" -eq "${#CHAIN[@]}" ] || line="$line &&"
  LANDING_LINES+=("$line")
done

# Verify the block against the cap before printing it. A command that breaks
# where nobody is looking is worse than no command.
for line in "${LANDING_LINES[@]}"; do
  [ "${#line}" -le "$FM_LANDING_LINE_MAX" ] || LANDING_OK=0
done

if [ "$COPY_BRANCH" != "$DEFAULT" ]; then
  if [ -n "$COPY_BRANCH" ]; then
    echo "note: the captain's copy is parked on '$COPY_BRANCH', not '$DEFAULT'; the command switches it first and stops if that is not possible."
  else
    echo "note: the captain's copy is not on a branch (detached HEAD); the command switches to '$DEFAULT' first and stops if that is not possible."
  fi
fi
if [ -n "$INSTALL_CMD" ]; then
  echo "note: this landing changed the dependency manifest, so the command installs dependencies with '$INSTALL_CMD'."
elif [ "$TOUCHED_MANIFEST" = 1 ]; then
  echo "note: this landing changed package.json, but nothing in $PROJ names a package manager, so the captain must install dependencies themselves."
fi

if [ "$LANDING_OK" != 1 ]; then
  echo "warning: no paste-ready landing command could be emitted within $FM_LANDING_LINE_MAX characters per line for $PROJ; give the captain the pull another way rather than a command that breaks on paste." >&2
  exit 0
fi

echo "CAPTAIN COMMAND (relay these lines to the captain verbatim, never reflowed):"
printf '%s\n' "${LANDING_LINES[@]}"
echo "END CAPTAIN COMMAND"
