#!/usr/bin/env bash
# Task-copy occupancy, independent of branches, harnesses, and runtime backends.
# The worktree's private Git directory holds fm-task-owner: exactly two lines,
# the canonical state directory and the task id. It survives a pool return and
# cannot be cleaned by a worker's git reset/clean. Fresh provider allocations
# replace it; reuse/recovery and teardown must match it. --force does not bypass
# occupancy: permission to discard one task never means discarding another.
# Callers hold fm-task-owner.lock from inspection/claim through publication or
# destructive cleanup. This is a per-copy lock shared across Firstmate homes.
#
# Spawn (non-destructive) acquires with wait: a bounded loop against a fixed
# deadline, overridable by FM_WORKTREE_OWNER_WAIT_DEADLINE (seconds). Teardown
# (destructive) acquires with try-only (non-blocking): it must not hold pane
# locks while waiting for another task's cleanup to finish. Both refuse when a
# live or recently-live task occupies the copy.
#
# Legacy copies have no record. Within the recorded home, a sole metadata claim
# is accepted; with multiple claims, only the unique task whose fm/<id> branch
# is actually checked out may adopt the copy. Ambiguity refuses, including a
# detached copy with conflicting claims. Branches only bootstrap legacy copies;
# once recorded, occupancy is authoritative even at detached HEAD or on a
# differently named branch. Successful legacy checks publish that same record.
# Secondmate homes themselves are not task copies; their child copies are.
# Requires fm_lock_* and fm_meta_get from the caller's existing libraries.

fm_worktree_owner_acquire() {  # <worktree> [wait]; sets RECORD and LOCK globals
  local wt=$1 mode=${2:-try} actual top gitdir deadline start rc
  FM_WORKTREE_OWNER_RECORD=
  FM_WORKTREE_OWNER_LOCK=
  if ! actual=$(cd -- "$wt" 2>/dev/null && pwd -P) \
    || ! top=$(git -C "$actual" rev-parse --show-toplevel 2>/dev/null) \
    || ! top=$(cd -- "$top" 2>/dev/null && pwd -P) \
    || [ "$actual" != "$top" ] \
    || ! gitdir=$(git -C "$actual" rev-parse --absolute-git-dir 2>/dev/null) \
    || ! gitdir=$(cd -- "$gitdir" 2>/dev/null && pwd -P); then
      echo "REFUSED: cannot establish task-copy occupancy for $wt (uninspectable Git worktree)." >&2
      return 1
  fi
  FM_WORKTREE_OWNER_RECORD="$gitdir/fm-task-owner"
  FM_WORKTREE_OWNER_LOCK="$gitdir/fm-task-owner.lock"
  if [ "$mode" = wait ]; then
    deadline=${FM_WORKTREE_OWNER_WAIT_DEADLINE:-60}
    start=$(date +%s)
    while :; do
      rc=0
      fm_lock_try_acquire "$FM_WORKTREE_OWNER_LOCK" || rc=$?
      [ "$rc" -eq 0 ] && return 0
      [ "$rc" -eq 2 ] && {
        echo "REFUSED: task-copy occupancy lock directory is unwritable for $wt." >&2
        FM_WORKTREE_OWNER_LOCK=
        return 1
      }
      if [ $(($(date +%s) - start)) -ge "$deadline" ]; then
        echo "REFUSED: task-copy occupancy is locked for $wt; cannot acquire after bounded wait ($deadline seconds)." >&2
        FM_WORKTREE_OWNER_LOCK=
        return 1
      fi
      sleep 0.1
    done
  elif ! fm_lock_try_acquire "$FM_WORKTREE_OWNER_LOCK"; then
    echo "REFUSED: task-copy occupancy is locked for $wt; another allocation or cleanup is in progress." >&2
    FM_WORKTREE_OWNER_LOCK=
    return 1
  fi
}

fm_worktree_owner_read() {
  local record=$FM_WORKTREE_OWNER_RECORD value
  FM_WORKTREE_OWNER_STATE=
  FM_WORKTREE_OWNER_ID=
  if [ ! -f "$record" ] || [ -L "$record" ] || [ ! -r "$record" ] \
    || ! value=$(awk '
      NR == 1 && $0 !~ /^\// { exit 1 }
      NR == 2 && $0 !~ /^[a-zA-Z0-9._-]+$/ { exit 1 }
      { print }
      END { if (NR != 2) exit 1 }
    ' "$record"); then
      echo "REFUSED: cannot read task-copy owner at $record; preserving the copy." >&2
      return 1
  fi
  FM_WORKTREE_OWNER_STATE=${value%%$'\n'*}
  FM_WORKTREE_OWNER_ID=${value#*$'\n'}
}

fm_worktree_owner_publish() {  # <state-dir> <task-id>, lock must be held
  local state=$1 id=$2 record=$FM_WORKTREE_OWNER_RECORD tmp
  state=$(cd -- "$state" 2>/dev/null && pwd -P) || return 1
  case "$state" in *$'\n'*) return 1 ;; esac
  case "$id" in ''|*[!a-zA-Z0-9._-]*) return 1 ;; esac
  # Refuse malformed existing authority, even on a new provider allocation.
  if [ -e "$record" ] || [ -L "$record" ]; then
    fm_worktree_owner_read || return 1
  fi
  tmp=$(mktemp "$record.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$state" "$id" > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_worktree_owner_read && [ "$FM_WORKTREE_OWNER_STATE" = "$state" ] \
    && [ "$FM_WORKTREE_OWNER_ID" = "$id" ]
}

fm_worktree_owner_require() {  # <worktree> <state-dir> <task-id>, lock held
  local wt=$1 state=$2 id=$3 record=$FM_WORKTREE_OWNER_RECORD actual other path branch candidate claim claims=0
  state=$(cd -- "$state" 2>/dev/null && pwd -P) || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    fm_worktree_owner_read || return 1
    if [ "$FM_WORKTREE_OWNER_STATE" = "$state" ] && [ "$FM_WORKTREE_OWNER_ID" = "$id" ]; then
      return 0
    fi
    echo "REFUSED: task $id does not own $wt; current occupant is $FM_WORKTREE_OWNER_ID (state $FM_WORKTREE_OWNER_STATE)." >&2
    return 1
  fi
  actual=$(cd -- "$wt" 2>/dev/null && pwd -P) || return 1
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  candidate=
  for other in "$state"/*.meta; do
    [ -e "$other" ] || [ -L "$other" ] || continue
    [ -f "$other" ] && [ ! -L "$other" ] && [ -r "$other" ] || {
      echo "REFUSED: cannot inspect legacy task-copy claim $other." >&2
      return 1
    }
    if ! claim=$(cat -- "$other") || ! path=$(printf '%s\n' "$claim" | awk '
      /^worktree=/ { count++; path=substr($0, 10) }
      END { if (count > 1) exit 1; print path }
    '); then
      echo "REFUSED: cannot read an unambiguous legacy task-copy claim from $other." >&2
      return 1
    fi
    [ -n "$path" ] || continue
    path=$(cd -- "$path" 2>/dev/null && pwd -P) || continue
    [ "$path" = "$actual" ] || continue
    claims=$((claims + 1))
    other=${other##*/}
    other=${other%.meta}
    [ "$branch" != "fm/$other" ] || candidate=$other
  done
  if [ "$claims" -gt 1 ] && [ "$candidate" != "$id" ]; then
    echo "REFUSED: task $id cannot claim legacy copy $wt; current occupant is ${candidate:-unestablished (conflicting task records)}." >&2
    return 1
  fi
  fm_worktree_owner_publish "$state" "$id"
}
