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
# holding a `reference-transaction` hook plus a forwarder for every other hook
# name a worker's git looks up through `core.hooksPath`. Git runs the
# reference-transaction hook inside every reference transaction and aborts the
# transaction when it exits non-zero, so the refusal comes from git itself
# rather than from a worker's willingness to follow instructions. The hook
# refuses only transactions that touch refs/stash, and only while the repository
# actually has more than one working copy: a repository with a single working
# copy shares nothing and keeps ordinary `git stash` untouched.
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
# HOW FAR IT REACHES, AND WHY NOTHING HERE IS BAKED IN
# An exported variable is not scoped to the task worktree: it applies to every
# repository the worker's git touches. The stash refusal is meant to reach that
# far, because every repository with more than one working copy has the same
# shared stack. Hook CHAINING must not reach that far, so nothing in this
# directory is resolved from the task's repository. Each file here re-resolves,
# at run time, the hook that the repository it is CURRENTLY running in would
# have used, reading `core.hooksPath` with `GIT_CONFIG_COUNT=0` so the injection
# above is invisible to that lookup. A repository the worker wanders into
# therefore keeps its own hooks, and the task repository's hooks do not follow
# the worker around.
#
# That is also why a forwarder exists for every client-side hook name rather
# than only the names the task's repository happens to use: git looks a hook up
# by name in this directory, so a name missing here is a hook of some other
# repository silently not run. The receive-side names are absent on purpose. Git
# clears GIT_CONFIG_COUNT when it enters another repository over a local
# transport, so this directory never reaches `git receive-pack` and a forwarder
# there could only lie - a `push-to-checkout` stub exiting 0 would tell git it
# had updated a working tree it never touched. `fsmonitor-watchman` is absent
# for the same kind of reason: git invokes it by the explicit path in
# `core.fsmonitor`, never by name through `core.hooksPath`.
#
# WHAT RESOLVING AT RUN TIME COSTS
# A known and accepted tradeoff, written down because someone will one day
# notice the cost without knowing where it comes from. Every hook invocation
# forks `sh` plus `git config`, and `git rev-parse` when no hooks path is
# configured, in every repository the worker's git touches, including
# repositories that have no hooks at all. The guard's own `forward` pays it on
# each reference-transaction phase, so one ref update costs roughly three extra
# `git config` forks. A forwarder also sits at `post-index-change`, which fires
# on ordinary index writes. Baking the delegate in at prepare time would avoid
# all of it, and that is exactly what used to make the task repository's hooks
# follow the worker into every other repository.
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
#   fm-stash-guard.sh prepare <hooks-dir>
#   fm-stash-guard.sh env <hooks-dir>
#
# prepare builds or refreshes <hooks-dir>. It is idempotent, and what it writes
# depends on no repository: the chaining is decided when a hook runs, not here.
#
# env prints one shell line to export into a worker's shell. The line appends to
# any git configuration already injected through the environment rather than
# overwriting entry zero, so it cannot silently drop someone else's injection.
set -u

MARKER='fm-stash-guard v1'

# Every hook name git resolves by name through core.hooksPath for a worker's own
# git invocation, from githooks(5). The receive-side names and fsmonitor-watchman
# are excluded for the reasons in the header.
HOOK_NAMES=(
  applypatch-msg pre-applypatch post-applypatch
  pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit
  pre-rebase post-checkout post-merge pre-push post-rewrite
  pre-auto-gc sendemail-validate post-index-change
  p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit
)

die() {
  printf 'fm-stash-guard.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: fm-stash-guard.sh prepare <hooks-dir>
       fm-stash-guard.sh env <hooks-dir>
EOF
}

# Emitted into every generated hook. It answers, at the moment the hook runs,
# which hook the repository it is running in would have used with no guard in
# the way. GIT_CONFIG_COUNT=0 hides the entries the `env` verb exports, so a
# legitimately file-configured core.hooksPath is still honored while the guard's
# own injection cannot make a hook chain to itself or to another task's guard.
# `--type=path` is what git itself applies to that value when it runs a hook, so
# a `~`-spelled directory resolves to the same place for the guard as it does
# for git. A relative value stays relative: git runs a hook from the directory
# those values resolve against.
emit_delegate_resolver() {
  cat <<'RESOLVER'
fm_delegate_hook() {  # <hook-name>
  fm_dir=$(GIT_CONFIG_COUNT=0 git config --get --type=path core.hooksPath 2>/dev/null) || fm_dir=
  if [ -z "$fm_dir" ]; then
    fm_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    fm_dir=$fm_dir/hooks
  fi
  printf '%s\n' "$fm_dir/$1"
}
RESOLVER
}

write_forwarder() {  # <path>
  local path=$1
  {
    printf '#!/bin/sh\n'
    printf '# %s forwarder. Firstmate points git at this directory to guard\n' "$MARKER"
    printf '# refs/stash; this file exists only so the hook that the repository\n'
    printf '# this runs in would otherwise have run still runs. Nothing here is\n'
    printf '# firstmate policy.\n'
    printf '\n'
    emit_delegate_resolver
    cat <<'FORWARDER'

fm_hook=$(fm_delegate_hook "${0##*/}") || exit 0
[ -x "$fm_hook" ] || exit 0
exec "$fm_hook" "$@"
FORWARDER
  } > "$path" || return 1
  chmod 0755 "$path"
}

write_guard() {  # <path>
  local path=$1
  {
    printf '#!/bin/sh\n'
    printf '# %s - written by firstmate'"'"'s bin/fm-stash-guard.sh.\n' "$MARKER"
    printf '#\n'
    printf '# refs/stash is repository-wide, not per-working-copy. While this repository has\n'
    printf '# more than one working copy, a stash written here can be popped, and destroyed,\n'
    printf '# from any of the others, silently. This hook makes that attempt fail instead.\n'
    printf '\n'
    emit_delegate_resolver
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
  fm_hook=$(fm_delegate_hook reference-transaction) || exit 0
  if [ -x "$fm_hook" ]; then
    printf '%s' "$buffer" | "$fm_hook" "$@"
    exit $?
  fi
  exit 0
}

[ "$state" = prepared ] || forward "$@"
[ "$saw_stash" = 1 ] || forward "$@"

# git's own inventory of working copies, so nothing has to be inferred about the
# repository's shape: a bare main repository holds no working tree at all, and a
# worktree whose directory is gone is no copy either. Counting either of them
# would refuse on behalf of a copy that does not exist.
listing=$(git worktree list --porcelain 2>/dev/null) || listing=
if [ -z "$listing" ]; then
  # Refusing stash operations, and only stash operations, when the repository's
  # shape cannot be read at all is a bounded and loud failure. Guessing
  # "probably safe" here is how the silent case comes back.
  echo "fm-stash-guard: refusing a refs/stash change: could not read how many working copies this repository has." >&2
  exit 1
fi
copies=$(printf '%s\n' "$listing" | awk '
  /^worktree /{ n++ }
  /^bare$/{ n-- }
  /^prunable/{ n-- }
  END{ print n+0 }')

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
    [ -n "$HOOKS_DIR" ] || { usage >&2; exit 2; }
    mkdir -p "$HOOKS_DIR" || die "could not create $HOOKS_DIR"
    # Rebuild from empty so a re-prepare after this script's hook set changed
    # cannot leave a file behind that no longer belongs here.
    find "$HOOKS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    for name in "${HOOK_NAMES[@]}"; do
      write_forwarder "$HOOKS_DIR/$name" \
        || die "could not write the $name forwarder into $HOOKS_DIR"
    done
    write_guard "$HOOKS_DIR/reference-transaction" \
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
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
