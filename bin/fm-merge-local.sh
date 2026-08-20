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
# only thing it reads there is which branch that copy is parked on. Every emitted
# line stays at or under FM_LANDING_LINE_MAX characters, every interpolated value
# is single-quoted, a long path is built up across several short assignment
# lines, and the block is verified against the cap before it is printed. The
# dated measurements behind those rules, and the three failures they close, are
# owned by docs/verification/captain-landing.md.
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
# See docs/verification/captain-landing.md for the failures every rule below
# closes and the measurements behind them.

# Widest line the captain's terminal can take from a paste without breaking it.
FM_LANDING_LINE_MAX=50

LANDING_LINES=()

landing_quote() {  # <string> -> LANDING_QUOTED: single-quoted for a shell line
  LANDING_QUOTED="'${1//\'/\'\\\'\'}'"
}

join_quoted() {  # <item...> -> "'a', 'b'" for a human-readable note
  local out= item
  for item in "$@"; do
    [ -z "$out" ] || out="$out, "
    out="$out'$item'"
  done
  printf '%s' "$out"
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

# The dependency manifests this guard recognizes. The list is closed on purpose:
# a name that is not here is not a manifest as far as the landing command is
# concerned, and nothing about the project is inferred by any other means.
FM_LANDING_MANIFESTS='package.json requirements.txt pyproject.toml Cargo.toml go.mod Gemfile'

# Every install command the landing block may ever name, and the in-repo
# evidence that has to be present before it is named. Rows are
# <manifest>|<evidence>|<command>, tried top to bottom. Evidence is a file the
# repo carries, except the token `packageManager`, which is package.json's own
# declaration of its manager.
#
# A manifest with no row here, or whose rows find no evidence, gets the
# manifest-touched note and never a command. That is the whole rule, held in one
# place: an existing manifest cannot drift out of it and a new one cannot be
# added without an evidence column, because there is nowhere else to name a
# command. requirements.txt has no row on purpose - it says which packages, never
# into which interpreter, and a bare `pip install` with nothing active installs
# into the captain's system Python.
FM_LANDING_INSTALL_RULES='
package.json|packageManager|
package.json|pnpm-lock.yaml|pnpm install
package.json|yarn.lock|yarn install
package.json|bun.lockb|bun install
package.json|bun.lock|bun install
package.json|package-lock.json|npm install
pyproject.toml|uv.lock|uv sync
pyproject.toml|poetry.lock|poetry install
pyproject.toml|pdm.lock|pdm install
Cargo.toml|Cargo.lock|cargo fetch
go.mod|go.sum|go mod download
Gemfile|Gemfile.lock|bundle install
'

# landing_unnamed_reason <manifest>: why no command was named, in the captain's
# terms. requirements.txt gets its own reason because the generic one - "nothing
# names a package manager" - reads as an invitation to reach for pip, which is
# the command this guard refuses to hand over.
landing_unnamed_reason() {
  case "$1" in
    requirements.txt)
      printf '%s' "which names which packages but never which interpreter; with no environment active a bare pip install goes into the captain's system Python, so the captain must activate the project's environment first and install there themselves." ;;
    *)
      printf '%s' "but nothing in $PROJ names a package manager for it, so the captain must install dependencies themselves." ;;
  esac
}

landing_declared_install_cmd() {  # package.json's own packageManager field
  local declared
  [ -f "$PROJ/package.json" ] || return 1
  declared=$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([a-z]*\)@.*/\1/p' "$PROJ/package.json" | head -1)
  case "$declared" in
    npm|pnpm|yarn|bun) printf '%s install\n' "$declared"; return 0 ;;
  esac
  return 1
}

# landing_install_cmd <manifest>: the install command the repo's own evidence
# names, or nothing. This is the single point that decides; no manifest answers
# for itself. A missing answer stays missing, because guessing is how the captain
# gets told to run a command their project does not use.
landing_install_cmd() {
  local manifest=$1 m evidence cmd
  # A manifest the landing deleted has no install step to name.
  [ -f "$PROJ/$manifest" ] || return 1
  while IFS='|' read -r m evidence cmd; do
    [ "$m" = "$manifest" ] || continue
    if [ "$evidence" = packageManager ]; then
      landing_declared_install_cmd && return 0
      continue
    fi
    [ -f "$PROJ/$evidence" ] || continue
    printf '%s\n' "$cmd"
    return 0
  done <<RULES
$FM_LANDING_INSTALL_RULES
RULES
  return 1
}

# landing_touched_manifests <from> <to>: fill TOUCHED_MANIFESTS with the
# recognized manifest names this landing changed, in first-seen order.
landing_touched_manifests() {
  local f m
  TOUCHED_MANIFESTS=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for m in $FM_LANDING_MANIFESTS; do
      [ "${f##*/}" = "$m" ] || continue
      case " ${TOUCHED_MANIFESTS[*]-} " in
        *" $m "*) ;;
        *) TOUCHED_MANIFESTS+=("$m") ;;
      esac
    done
  done < <(git -C "$PROJ" diff --name-only "$1" "$2" 2>/dev/null || true)
  [ "${#TOUCHED_MANIFESTS[@]}" -gt 0 ]
}

# The captain's working copy IS this clone's origin on a local-only project;
# firstmate never pushes there, which is why the landing is invisible until they
# pull. Anything else (a real remote, a bare repo, a missing path) means this
# topology does not hold, and then no command is emitted at all.
#
# A relative origin is rejected with the rest: this script resolves it against
# its own working directory while the emitted `cd` would resolve it against the
# captain's, so the two would name different directories. `git clone` records an
# absolute path, but `git remote set-url origin ../copy` keeps what it was given.
CAPTAIN_COPY=$(git -C "$PROJ" remote get-url origin 2>/dev/null || true)
case "$CAPTAIN_COPY" in file://*) CAPTAIN_COPY=${CAPTAIN_COPY#file://} ;; esac
case "$CAPTAIN_COPY" in /*) ;; *) CAPTAIN_COPY= ;; esac
if [ -z "$CAPTAIN_COPY" ] || [ ! -d "$CAPTAIN_COPY" ] \
  || [ "$(git -C "$CAPTAIN_COPY" rev-parse --is-bare-repository 2>/dev/null || echo true)" != false ]; then
  echo "note: origin of $PROJ is not a local working copy at an absolute path, so no paste-ready landing command was emitted."
  exit 0
fi
COPY_BRANCH=$(git -C "$CAPTAIN_COPY" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# The install step has to cover what the PULL brings, not what this landing
# added. Landings accumulate while the captain has not pulled - that is the
# normal state this guard exists for - so a landing that touched no manifest can
# still deliver one that an earlier unpulled landing did. The span is therefore
# the captain's copy's own default branch; when that ref cannot be read, or names
# a commit this clone does not have, this landing is the honest fallback.
PULL_FROM=$before
copy_default=$(git -C "$CAPTAIN_COPY" rev-parse --verify --quiet "refs/heads/$DEFAULT" 2>/dev/null || true)
if [ -n "$copy_default" ] && git -C "$PROJ" cat-file -e "$copy_default^{commit}" 2>/dev/null; then
  PULL_FROM=$copy_default
fi

TOUCHED_MANIFESTS=()
INSTALL_CMDS=()
UNNAMED_MANIFESTS=()
if landing_touched_manifests "$PULL_FROM" "$after"; then
  for manifest in "${TOUCHED_MANIFESTS[@]}"; do
    cmd=$(landing_install_cmd "$manifest" || true)
    if [ -n "$cmd" ]; then
      INSTALL_CMDS+=("$cmd")
    else
      UNNAMED_MANIFESTS+=("$manifest")
    fi
  done
fi

# Build the block: every path lands in a variable first, then one `&&` chain, so
# a step that cannot run stops the ones after it instead of running in the wrong
# directory or on the wrong branch. The pull is `--ff-only` for the same reason
# this script refuses a diverged branch: a captain's copy holding commits the
# clone does not have must get a readable refusal, never a merge-commit editor
# in a 56-column terminal or a half-pasted conflicted merge.
LANDING_OK=1
landing_assign fmw "$CAPTAIN_COPY" || LANDING_OK=0
landing_assign fmc "$PROJ" || LANDING_OK=0

# landing_chain <branch-expression>: the steps the captain pastes, in order.
# <branch-expression> must already be quoted for the captain's shell: a git ref
# may contain `;`, `&`, `$`, a quote, or a backtick, and this block is pasted
# verbatim, so an unquoted branch name would execute as extra commands - exactly
# the damage the block exists to prevent.
# The `$fmw` / `$fmc` references stay literal on purpose - they are text for the
# captain's shell, not expansions for this one, and they are what keeps a long
# path off a line that would break on paste.
# shellcheck disable=SC2016
landing_chain() {
  local cmd
  CHAIN=('cd "$fmw"')
  [ "$COPY_BRANCH" = "$DEFAULT" ] || CHAIN+=("git switch $1")
  CHAIN+=("git pull --ff-only \"\$fmc\" $1")
  for cmd in ${INSTALL_CMDS[@]+"${INSTALL_CMDS[@]}"}; do CHAIN+=("$cmd"); done
}

landing_quote "$DEFAULT"
DEFAULT_QUOTED=$LANDING_QUOTED
landing_chain "$DEFAULT_QUOTED"
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
    echo "note: the captain's copy is parked on '$COPY_BRANCH', not '$DEFAULT'; the command switches it first and the pull stops if git refuses that switch."
  else
    echo "note: the captain's copy is not on a branch (detached HEAD); the command switches to '$DEFAULT' first and the pull stops if git refuses that switch."
  fi
  echo "note: git only refuses the switch when it would overwrite an uncommitted change; anything it can carry across - an edit to a file that matches on both branches, or an untracked file - lands on '$DEFAULT' with the captain. A dirty tree is the captain's to commit or stash before pasting."
fi
if [ "${#INSTALL_CMDS[@]}" -gt 0 ]; then
  echo "note: this landing changed the dependency manifest, so the command installs dependencies with $(join_quoted "${INSTALL_CMDS[@]}")."
fi
for manifest in ${UNNAMED_MANIFESTS[@]+"${UNNAMED_MANIFESTS[@]}"}; do
  echo "note: this landing changed the dependency manifest '$manifest', $(landing_unnamed_reason "$manifest")"
done

if [ "$LANDING_OK" != 1 ]; then
  echo "warning: no paste-ready landing command could be emitted within $FM_LANDING_LINE_MAX characters per line for $PROJ; give the captain the pull another way rather than a command that breaks on paste." >&2
  exit 0
fi

echo "CAPTAIN COMMAND (relay these lines to the captain verbatim, never reflowed):"
printf '%s\n' "${LANDING_LINES[@]}"
echo "END CAPTAIN COMMAND"
