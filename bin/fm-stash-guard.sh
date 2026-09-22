#!/usr/bin/env bash
# fm-stash-guard.sh - stop one working copy's `git stash` from reaching another's.
#
# WHY THIS EXISTS
# `git stash` looks like private, per-copy scratch space. It is not. refs/stash
# lives in the repository's COMMON git directory, so the primary checkout and
# every pooled task worktree of one repository share a single stash stack.
# Firstmate dispatches several workers onto one repository as its normal mode,
# which makes that sharing routine rather than exotic. One worker's
# `git stash pop` then takes whatever the last worker stashed, drops it from the
# stack, and reports complete success. Nothing fails, nothing warns, and the
# worker whose work just moved never finds out. The measured incident is in
# tests/fm-stash-guard.test.sh as the baseline case.
#
# WHAT THIS BUILDS
# A hooks directory, owned by firstmate and living outside every repository,
# holding a `reference-transaction` hook. Git runs that hook inside every
# reference transaction and aborts the transaction when it exits non-zero, so
# the refusal comes from git itself rather than from a worker's willingness to
# follow instructions. The hook refuses only transactions that touch refs/stash,
# and only while the repository actually has more than one working copy: a
# repository with a single working copy shares nothing and keeps ordinary
# `git stash` untouched.
#
# HOW GIT IS POINTED AT IT
# Through `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`, printed by the `env` verb and
# exported into the worker's shell. That placement is deliberate:
#   - it writes NOTHING into any repository, so no project state changes and the
#     captain's own checkouts keep exactly the hooks they had;
#   - it outranks every configuration file, including a `core.hooksPath` set
#     globally, which on a home-manager machine points at a generated directory
#     that must not be edited. A hook dropped in `.git/hooks` there would be
#     silently ignored, which is worse than no guard: it reads as protection
#     while protecting nothing;
#   - it is inherited by every child process, so it holds even when a worker
#     invokes git by absolute path, which a PATH shim would not survive.
#
# Hooks that would otherwise have applied to the repository are chained, so
# pointing git here never costs a worker a hook its project or the machine
# relies on. Chaining is resolved when the directory is prepared, which is once
# per task, and a task worktree is disposable.
#
# WHAT THE REFUSAL COSTS
# Measured, not assumed (tests/fm-stash-guard.test.sh):
#   - a refused `git stash push` leaves the working tree exactly as it was, so
#     the worker loses nothing and can park the work the way the message names;
#   - a refused `git stash pop` or `drop` leaves the stashed commit at refs/stash
#     byte for byte, so the entry's owner keeps their work. Git truncates the
#     stash reflog before the transaction it then aborts, so `git stash list`
#     reads empty afterwards even though the entry survives; the refusal says so
#     and names the command that reads it back.
# Refusing is therefore never the destructive choice. Staying silent is.
#
# WHAT THE GUARD DOES NOT COVER
# A measured, known limit rather than an oversight. The guard sees only
# reference-transaction events, and git fires that hook only for a stash removal
# that goes through `update-ref -d`: `git stash clear` and the drop of the LAST
# remaining entry, both of which the guard refuses. When refs/stash holds MORE
# THAN ONE entry, `git stash pop`, `git stash drop`, `git stash drop stash@{N}`,
# and `git stash branch` remove an entry through a reflog rewrite
# (`git reflog delete --updateref --rewrite`). No reference-transaction hook
# fires on a reflog rewrite, so the guard neither sees nor refuses that path:
# the entry is destroyed with exit 0 and no message.
#
# The reachable sequence: a stack of two or more entries can only be built where
# the guard does not apply, which is the captain's unguarded primary checkout or
# a state predating the worktree pool. A guarded worker's pop, drop, or branch
# then destroys one of those entries silently. Creation is still refused, so a
# worker can never ADD to such a stack from a guarded copy, but the pre-existing
# stack itself stays reachable. That boundary is deliberate and measured.
#
# Usage:
#   fm-stash-guard.sh prepare <hooks-dir> <repository-path>
#   fm-stash-guard.sh env <hooks-dir>
#   fm-stash-guard.sh status <hooks-dir>
#
# prepare builds or refreshes <hooks-dir> for the repository at
# <repository-path>, chaining whatever hooks that repository would otherwise
# run. It is idempotent.
#
# env prints one shell line to export into a worker's shell. The line appends to
# any git configuration already injected through the environment rather than
# overwriting entry zero, so it cannot silently drop someone else's injection.
#
# status exits 0 when <hooks-dir> holds a prepared guard and non-zero otherwise.
set -u

MARKER='fm-stash-guard v1'

die() {
  printf 'fm-stash-guard.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: fm-stash-guard.sh prepare <hooks-dir> <repository-path>
       fm-stash-guard.sh env <hooks-dir>
       fm-stash-guard.sh status <hooks-dir>
EOF
}

# Echoes the hooks directory this repository's git would use with no guard in
# the way, so the guard can chain to it instead of displacing it.
resolve_delegate_dir() {  # <repository-path>
  local repo=$1 configured common
  configured=$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)
  if [ -n "$configured" ]; then
    case $configured in
      /*) printf '%s\n' "$configured" ;;
      *) printf '%s\n' "$repo/$configured" ;;
    esac
    return 0
  fi
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case $common in
    /*) : ;;
    *) common=$(cd "$repo" && cd "$common" && pwd) || return 1 ;;
  esac
  printf '%s\n' "$common/hooks"
}

write_forwarder() {  # <path> <delegate-hook>
  local path=$1 delegate=$2
  # The delegate path is written as a single-quoted shell literal, so a hook
  # living under a path that contains shell metacharacters still forwards.
  {
    printf '#!/bin/sh\n'
    printf '# %s forwarder. Firstmate points git at this directory to guard\n' "$MARKER"
    printf '# refs/stash; this file exists only so the hook the repository would\n'
    printf '# otherwise have run still runs. Nothing here is firstmate policy.\n'
    printf 'exec %s "$@"\n' "'${delegate//\'/\'\\\'\'}'"
  } > "$path" || return 1
  chmod 0755 "$path"
}

write_guard() {  # <path> <delegate-hook-or-empty>
  local path=$1 delegate=$2
  # The chained hook is baked in ahead of every line that reads it, so the guard
  # stays readable on its own and cannot be re-pointed by a stray environment
  # variable.
  {
    printf '#!/bin/sh\n'
    printf '# %s - written by firstmate'"'"'s bin/fm-stash-guard.sh.\n' "$MARKER"
    printf '#\n'
    printf '# refs/stash is repository-wide, not per-working-copy. While this repository has\n'
    printf '# more than one working copy, a stash written here can be popped, and destroyed,\n'
    printf '# from any of the others, silently. This hook makes that attempt fail instead.\n'
    printf '\n'
    printf '# The hook this repository would have run, resolved when the guard was prepared.\n'
    printf 'FM_STASH_GUARD_DELEGATE=%s\n' "'${delegate//\'/\'\\\'\'}'"
    printf '\n'
  } > "$path" || return 1
  cat >> "$path" <<'GUARD' || return 1
state=$1
stash_old=
saw_stash=0
buffer=

# Read every line before deciding anything: git must never find a closed pipe,
# and a chained hook downstream still needs the same input.
while IFS= read -r line; do
  buffer=$buffer$line'
'
  case $line in
    *' refs/stash') saw_stash=1; stash_old=${line%% *} ;;
  esac
done

forward() {
  if [ -n "$FM_STASH_GUARD_DELEGATE" ] && [ -x "$FM_STASH_GUARD_DELEGATE" ]; then
    printf '%s' "$buffer" | "$FM_STASH_GUARD_DELEGATE" "$@"
    exit $?
  fi
  exit 0
}

[ "$state" = prepared ] || forward "$@"
[ "$saw_stash" = 1 ] || forward "$@"

common=$(git rev-parse --git-common-dir 2>/dev/null) || common=
if [ -z "$common" ]; then
  # Refusing stash operations, and only stash operations, when the repository's
  # shape cannot be read at all is a bounded and loud failure. Guessing
  # "probably safe" here is how the silent case comes back.
  echo "fm-stash-guard: refusing a refs/stash change: could not read how many working copies this repository has." >&2
  exit 1
fi

copies=0
if [ "$(git rev-parse --is-bare-repository 2>/dev/null)" != true ]; then
  copies=1
fi
if [ -d "$common/worktrees" ]; then
  for entry in "$common"/worktrees/*/; do
    [ -f "$entry/gitdir" ] || continue
    recorded=$(cat "$entry/gitdir" 2>/dev/null) || continue
    case $recorded in
      /*) : ;;
      # Git may record this path relative to the worktree's metadata directory.
      *) recorded=$entry/$recorded ;;
    esac
    # A pruned worktree leaves its metadata behind. Counting it would refuse on
    # behalf of a copy that no longer exists, so only a live one counts.
    [ -e "$recorded" ] || continue
    copies=$((copies + 1))
  done
fi

# One working copy means nothing is shared and nothing is at risk.
[ "$copies" -gt 1 ] || forward "$@"

# A create - the old value is all zeros - is a `git stash push`: nothing has been
# applied anywhere and the refusal costs the worker nothing. Anything else is the
# drop half of `git stash pop`, `drop`, or `clear`, where the entry being removed
# may be another working copy's work.
case $stash_old in
  *[!0]*) creating=0 ;;
  *) creating=1 ;;
esac

{
  echo
  if [ "$creating" = 1 ]; then
    echo "fm-stash-guard: refusing 'git stash' - this repository's stash is SHARED, not yours."
    echo
    echo "refs/stash lives in the common git directory, so all $copies working copies of this"
    echo "repository share ONE stash stack. Anything you stash here can be popped, and"
    echo "destroyed, from another copy, and neither of you would be told."
    echo
    echo "Your working tree is untouched. Park the work inside your own copy instead:"
    echo
    echo "  git add -A && git commit -m wip     # park everything on YOUR branch"
    echo "  git reset --soft HEAD~1             # unpark it later, index and all"
    echo
    echo "or carry it out of the repository as a file:"
    echo
    echo "  git diff HEAD > ../parked.patch && git checkout -- .   # tracked files only"
    echo "  git apply ../parked.patch"
  else
    echo "fm-stash-guard: refusing to remove a stash entry - this repository's stash is SHARED."
    echo
    echo "refs/stash lives in the common git directory, so all $copies working copies of this"
    echo "repository share ONE stash stack, and this entry may be another copy's work."
    echo
    echo "Nothing was destroyed. The entry is still at refs/stash:"
    echo
    echo "  git show refs/stash            # read what it holds"
    echo "  git stash apply refs/stash     # copy it here WITHOUT removing it"
    echo
    echo "'git stash list' reads empty after this refusal even though the entry survives,"
    echo "because git truncates the stash reflog before the change this hook just aborted."
    echo "If you ran 'git stash pop', its changes are already in your working tree."
  fi
  echo
} >&2
exit 1
GUARD
  chmod 0755 "$path"
}

VERB=${1:-}
case $VERB in
  prepare)
    HOOKS_DIR=${2:-}
    REPO=${3:-}
    [ -n "$HOOKS_DIR" ] && [ -n "$REPO" ] || { usage >&2; exit 2; }
    [ -d "$REPO" ] || die "not a directory: $REPO"
    git -C "$REPO" rev-parse --git-common-dir >/dev/null 2>&1 \
      || die "not a git repository: $REPO"
    DELEGATE_DIR=$(resolve_delegate_dir "$REPO") \
      || die "could not resolve the hooks directory of $REPO"
    mkdir -p "$HOOKS_DIR" || die "could not create $HOOKS_DIR"
    # Rebuild from empty so a re-prepare after the repository's own hooks changed
    # cannot leave a forwarder pointing at a hook that is no longer there.
    find "$HOOKS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    DELEGATE_GUARD=
    if [ -d "$DELEGATE_DIR" ]; then
      for hook in "$DELEGATE_DIR"/*; do
        [ -f "$hook" ] && [ -x "$hook" ] || continue
        name=$(basename "$hook")
        if [ "$name" = reference-transaction ]; then
          DELEGATE_GUARD=$hook
          continue
        fi
        write_forwarder "$HOOKS_DIR/$name" "$hook" \
          || die "could not chain the repository's $name hook"
      done
    fi
    write_guard "$HOOKS_DIR/reference-transaction" "$DELEGATE_GUARD" \
      || die "could not write the stash guard into $HOOKS_DIR"
    grep -Fq "$MARKER" "$HOOKS_DIR/reference-transaction" \
      || die "wrote $HOOKS_DIR/reference-transaction but it does not read back as the guard"
    printf 'prepared: %s\n' "$HOOKS_DIR"
    ;;
  env)
    HOOKS_DIR=${2:-}
    [ -n "$HOOKS_DIR" ] || { usage >&2; exit 2; }
    [ -f "$HOOKS_DIR/reference-transaction" ] \
      || die "no prepared guard at $HOOKS_DIR; run prepare first"
    case $HOOKS_DIR in
      *[\'\"\$\`]*|*' '*) die "hooks directory path is not safe to export: $HOOKS_DIR" ;;
    esac
    # Appends at the current count rather than assuming entry zero is free, so a
    # worker that already carries injected git configuration keeps it.
    # The `$n` and `$((n+1))` are deliberately literal: they are expanded by the
    # worker's own shell when it evaluates this line, not here.
    # shellcheck disable=SC2016
    printf 'n=${GIT_CONFIG_COUNT:-0}; export "GIT_CONFIG_KEY_$n=core.hooksPath" "GIT_CONFIG_VALUE_$n=%s"; export GIT_CONFIG_COUNT=$((n+1))\n' "$HOOKS_DIR"
    ;;
  status)
    HOOKS_DIR=${2:-}
    [ -n "$HOOKS_DIR" ] || { usage >&2; exit 2; }
    if [ -f "$HOOKS_DIR/reference-transaction" ] \
      && grep -Fq "$MARKER" "$HOOKS_DIR/reference-transaction" 2>/dev/null; then
      printf 'prepared: %s\n' "$HOOKS_DIR"
      exit 0
    fi
    printf 'absent: %s\n' "$HOOKS_DIR"
    exit 1
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
