#!/usr/bin/env bash
# fm-scripts-inventory-check.sh - single owner of the bijection between
# docs/scripts.md's toolbelt table and the files under bin/.
#
# Usage:
#   bin/fm-scripts-inventory-check.sh
#   bin/fm-scripts-inventory-check.sh --root <repo> [--doc <path>]
#   bin/fm-scripts-inventory-check.sh --help
#
# Exit 0 prints one ok line carrying both counts. Exit 1 names every file that
# has no row and every row that names no file.
#
# THE ROW CONTRACT. The table opens at the one "| Script | Purpose |" header,
# whose delimiter row must follow it, and closes at the first later line that
# does not begin with "|". Each row between them names exactly one file in its
# first cell, spelled relative to bin/, in one of two accepted forms:
#
#   | `fm-lock.sh`                      | one purpose clause |
#   | [`fm-lock.sh`](../bin/fm-lock.sh) | one purpose clause |
#
# The link form's target must be the same file the row names, so no row can
# point a reader at a different script than the one it is about. Both forms take
# a path under bin/, which is what lets `backends/tmux.sh` hold a row of its own.
# The purpose cell must say something: an empty one is a row that names a script
# and tells a reader nothing about it.
#
# THE INVENTORY is every file git reports under bin/, tracked plus untracked and
# not ignored. Untracked files count so that a script written but not yet staged
# is already inside the check, rather than passing locally and failing once its
# author has committed it.
#
# REFUSING, because the entire value of this check is that nobody can trust the
# list while it is wrong. An input it cannot evaluate must never read as no
# drift, so a row it cannot parse, a doc with no table, a second table, a
# repository it cannot query, and an inventory it could not establish are each
# exit 1 naming the concrete thing that could not be determined. Absent,
# unreadable, and unreachable are three different answers and are reported as
# three, because "not there" is a fact and the other two are failures to look.
# tests/fm-scripts-inventory.test.sh owns the proof, including the matrix that
# makes each input channel unevaluable in turn; read the header of
# tests/fm-lane-degradation.test.sh for the invariant that matrix holds to.
set -eu

SELF=fm-scripts-inventory-check

refuse() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  exit 1
}

usage() {
  awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC=

while [ "$#" -gt 0 ]; do
  case $1 in
    --help | -h)
      usage
      exit 0
      ;;
    --root)
      [ "$#" -ge 2 ] || refuse "--root needs a path"
      ROOT=$2
      shift 2
      ;;
    --root=*)
      ROOT=${1#--root=}
      shift
      ;;
    --doc)
      [ "$#" -ge 2 ] || refuse "--doc needs a path"
      DOC=$2
      shift 2
      ;;
    --doc=*)
      DOC=${1#--doc=}
      shift
      ;;
    *) refuse "unknown argument: $1" ;;
  esac
done

[ -d "$ROOT" ] || refuse "repository root is not a directory: $ROOT"
[ -x "$ROOT" ] || refuse "repository root cannot be searched: $ROOT"
[ -n "$DOC" ] || DOC="$ROOT/docs/scripts.md"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/$SELF.XXXXXX") || refuse "could not create a work directory"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- the doc side -----------------------------------------------------------
#
# Absent, present-but-unreadable, and hidden behind a directory nobody may
# search are answered apart. An existence test that could not run is not
# evidence of non-existence, so the unsearchable-parent case is named as the
# failure to look that it is rather than reported as an absent file.
if [ ! -r "$DOC" ]; then
  if [ -e "$DOC" ]; then
    refuse "the toolbelt reference is present but unreadable: $DOC"
  fi
  DOC_DIR=$(dirname "$DOC")
  if [ -d "$DOC_DIR" ] && [ -x "$DOC_DIR" ] && [ -r "$DOC_DIR" ]; then
    refuse "the toolbelt reference is absent: $DOC"
  fi
  refuse "whether the toolbelt reference exists could not be determined, because its directory cannot be read or searched: $DOC_DIR"
fi
[ -f "$DOC" ] || refuse "the toolbelt reference is not a regular file: $DOC"

DOC_LABEL=$DOC
case $DOC in
  "$ROOT"/*) DOC_LABEL=${DOC#"$ROOT"/} ;;
esac

ROWS="$TMP/rows"
: > "$ROWS"

# States: before the header, inside the table, past it. Reaching "past" and then
# meeting another table line is a second inventory, which is refused rather than
# ignored: a list nobody reads is exactly how the first one drifted.
state=before
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  case $state in
    before)
      case $line in
        '|'*[Ss]cript*'|'*[Pp]urpose*'|'*) state=delimiter ;;
      esac
      continue
      ;;
    delimiter)
      # A delimiter row is dashes, colons, pipes and spaces and nothing else.
      # Matching "a pipe and a dash somewhere" would accept the FIRST ROW as the
      # delimiter, because every script name in it contains a dash.
      case $line in
        '|'*-*) ;;
        *) refuse "$DOC_LABEL:$lineno: the toolbelt table header is not followed by a delimiter row" ;;
      esac
      [ -z "$(printf '%s' "$line" | sed 's/[|: -]//g')" ] ||
        refuse "$DOC_LABEL:$lineno: the toolbelt table header is not followed by a delimiter row"
      state=inside
      continue
      ;;
    past)
      case $line in
        '|'*) refuse "$DOC_LABEL:$lineno: a second table follows the toolbelt table; this check reads exactly one inventory" ;;
      esac
      continue
      ;;
  esac

  case $line in
    '|'*) ;;
    *)
      state=past
      continue
      ;;
  esac

  row=${line#|}
  case $row in
    *'|'*) ;;
    *) refuse "$DOC_LABEL:$lineno: row has no purpose cell" ;;
  esac
  cell=${row%%|*}
  rest=${row#*|}
  cell=$(printf '%s' "$cell" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  purpose=$(printf '%s' "${rest%%|*}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  name=
  shown=
  case $cell in
    '[`'*'`](../bin/'*')')
      after=${cell#'[`'}
      name=${after%%'`'*}
      target=${after#*'`'}
      if [ "$target" != "](../bin/$name)" ]; then
        shown=${target#']('}
        shown=${shown%')'}
        refuse "$DOC_LABEL:$lineno: the row for \`$name\` links to $shown instead of the ../bin/$name it names"
      fi
      ;;
    '`'*'`')
      name=${cell%'`'}
      name=${name#'`'}
      ;;
    *)
      refuse "$DOC_LABEL:$lineno: first cell is neither \`<script>\` nor [\`<script>\`](../bin/<script>): $cell"
      ;;
  esac

  case $name in
    '') refuse "$DOC_LABEL:$lineno: row names an empty script" ;;
    *'`'*) refuse "$DOC_LABEL:$lineno: row names more than one thing: $cell" ;;
    /* | ../* | */../* | */..) refuse "$DOC_LABEL:$lineno: row names a path outside bin/: $name" ;;
  esac
  [ -n "$purpose" ] || refuse "$DOC_LABEL:$lineno: the row for \`$name\` has an empty purpose cell"

  printf '%s\n' "$name" >> "$ROWS"
done < "$DOC"

case $state in
  before) refuse "$DOC_LABEL has no \"| Script | Purpose |\" toolbelt table" ;;
  delimiter) refuse "$DOC_LABEL ends at its toolbelt table header, with no rows" ;;
esac

ROW_COUNT=$(awk 'END { print NR }' "$ROWS")
[ "$ROW_COUNT" -gt 0 ] || refuse "$DOC_LABEL's toolbelt table has no rows"

SORTED_ROWS="$TMP/rows.sorted"
LC_ALL=C sort "$ROWS" > "$SORTED_ROWS"
DUPES=$(LC_ALL=C uniq -d "$SORTED_ROWS")
[ -z "$DUPES" ] || refuse "$DOC_LABEL lists the same script more than once:
$DUPES"

# --- the bin/ side ----------------------------------------------------------
#
# git is asked because git owns what is in this repository and what is ignored.
# A failed query is refused rather than read as an empty directory: unknown and
# zero are not the same value, and only one of them means no drift.
git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1 ||
  refuse "not a git repository, so the bin/ inventory cannot be established: $ROOT"

FILES="$TMP/files"
: > "$FILES"
for mode in tracked untracked; do
  out="$TMP/ls-files.$mode"
  rc=0
  if [ "$mode" = tracked ]; then
    git -C "$ROOT" ls-files -- bin > "$out" 2> "$out.err" || rc=$?
  else
    git -C "$ROOT" ls-files --others --exclude-standard -- bin > "$out" 2> "$out.err" || rc=$?
  fi
  [ "$rc" -eq 0 ] ||
    refuse "git could not list the $mode files under bin/ (exit $rc): $(tr '\n' ' ' < "$out.err")"
  cat "$out" >> "$FILES"
done

SORTED_FILES="$TMP/files.sorted"
sed -n 's|^bin/||p' "$FILES" | LC_ALL=C sort -u > "$SORTED_FILES"
FILE_COUNT=$(awk 'END { print NR }' "$SORTED_FILES")
[ "$FILE_COUNT" -gt 0 ] ||
  refuse "git established no files under bin/ in $ROOT, which is not an answer this repository can have"

# --- the comparison ---------------------------------------------------------

MISSING=$(LC_ALL=C comm -13 "$SORTED_ROWS" "$SORTED_FILES")
EXTRA=$(LC_ALL=C comm -23 "$SORTED_ROWS" "$SORTED_FILES")

if [ -n "$MISSING" ] || [ -n "$EXTRA" ]; then
  {
    printf '%s: %s and bin/ disagree\n' "$SELF" "$DOC_LABEL"
    printf '%s\n' "$MISSING" | while IFS= read -r n; do
      [ -n "$n" ] || continue
      printf '%s: bin/%s has no row in %s\n' "$SELF" "$n" "$DOC_LABEL"
    done
    printf '%s\n' "$EXTRA" | while IFS= read -r n; do
      [ -n "$n" ] || continue
      # shellcheck disable=SC2016 # The backticks quote the row as the doc spells it.
      printf '%s: the row for `%s` names no file under bin/\n' "$SELF" "$n"
    done
    printf '%s: add or remove the row in the same change as the script\n' "$SELF"
  } >&2
  exit 1
fi

printf '%s: ok scripts=%s rows=%s\n' "$SELF" "$FILE_COUNT" "$ROW_COUNT"
