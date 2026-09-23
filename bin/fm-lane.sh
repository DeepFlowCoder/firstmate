#!/usr/bin/env bash
# fm-lane.sh - decide which review lane a delivery gets, and record it.
#
# The policy itself - the tier order, the critical-surface catalog, the evidence
# grades, and the durable record's format - is owned by bin/fm-lane-lib.sh.
# Read that header before changing anything here. This file is the command
# surface over it.
#
# Usage:
#   fm-lane.sh decide <task-id> --project <name> --repo <dir>
#                     ( --range <base>..<head> | --paths <p> [<p>...] )
#                     [--class docs-only|clean-revert] [--revert-of <sha>]
#                     [--captain-override <the captain's own words>]
#                     [--note <text>]
#   fm-lane.sh escape <task-id> --note <text> [--project <name>]
#
# decide prints one machine-readable first line:
#   lane=<no-mistakes|direct-PR> evidence=<demonstrated|declared> reason=<slug>
# followed by the evidence that produced it, and appends the decision to
# data/lane-log.tsv. Pass the printed lane to bin/fm-spawn.sh --mode (or
# bin/fm-promote.sh --mode); the cheap lane is refused at dispatch without this
# record.
#
# EVIDENCE:
#   --range         DEMONSTRATED. Paths and signals are computed from the real
#                   diff. Only this grade can produce the cheap lane. The range
#                   is the two-dot <base>..<head> form; three dots are refused
#                   rather than guessed at, because a caller who wrote them
#                   meant merge-base semantics and would get the wrong diff.
#   --paths         DECLARED. A list the caller asserts the change will touch.
#                   It routes critical surfaces to the expensive lane and stops;
#                   it can never produce the cheap lane, because a change that is
#                   not written yet cannot be shown benign.
#
# --repo is REQUIRED on BOTH grades, because the project's own
# .fm-critical-surfaces is read from it. Without it the decision would be made
# against the built-in catalog alone and the record would name no surface for a
# path that IS one in that project - a record implying a surface check that did
# not happen. A project that adds no surfaces simply has no such file.
#
# CLASSES, and how each one is demonstrated rather than alleged:
#   docs-only     every changed path carries a PROSE NAME and a PROSE OBJECT.
#                 The name is a prose markup format (.md, .markdown, .rst,
#                 .adoc) or a NAMED prose file - CHANGELOG, README, NOTICE,
#                 AUTHORS, CONTRIBUTORS, LICENCE - with or without a .txt
#                 suffix. The object is the tree entry at the range's head,
#                 which must be a regular non-executable file or absent, and no
#                 changed path may be binary: a symlink, an executable, a
#                 submodule link or a blob of binary bytes called guide.md is
#                 not documentation, whatever it is called. Nothing qualifies by
#                 where it lives: docs/ widens nothing, and docs/requirements.txt
#                 is not documentation.
#   clean-revert  with --revert-of <sha>: every changed path's content at the
#                 range's head equals its content at <sha>^, so the change is
#                 exactly that commit undone.
# A class that is claimed and fails its demonstration is not that class: the
# decision is the expensive lane with reason class-not-demonstrated.
# A range carrying a MODE CHANGE is not offered to either demonstration at all:
# no class reaches the cheap lane over one, the claim is left unevaluated, and
# the record says so with class - and reason signals:mode.
#
# THE THIRD CLASS THE CAPTAIN NAMED, mechanical-pattern, WAS REMOVED, and this
# policy is narrower than the one he approved because of it. His own condition
# decided it: si no se puede demostrar, no es de esa clase y va al caro. The
# demonstration ran a caller-supplied --reproduce command and compared the tree
# it produced against head's, and two rounds MEASURED that the command can reach
# the range's head whatever the copy it runs in - by the source repository's own
# absolute path, which the same caller supplied. Real isolation is the only
# thing that would close it, and that is machinery this delivery does not have.
# Keeping the class would have meant a footnote saying the demonstration runs on
# the honour system, which is not rigor. Both surviving classes are decided from
# git objects WITHOUT EXECUTING ANYTHING, so neither is forgeable that way.
# The cost, which is the safe direction: a mechanical sweep now routes expensive.
#
# --captain-override is the captain's explicit instruction, not a signal. It is
# the only thing that reaches the cheap lane past a critical surface (AGENTS.md
# "Captain instruction precedence"), it requires the captain's own words, and it
# records both the words and the surfaces it overrode. Never use it to carry
# firstmate's own judgment.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_ROOT FM_HOME

# shellcheck source=bin/fm-lane-lib.sh
. "$SCRIPT_DIR/fm-lane-lib.sh"

# Tier-3 thresholds. Deliberately constants rather than configuration: an
# environment-tunable rigor threshold is a silent way to lower rigor, and the
# captain reserved that choice. Their provenance is the published signal set -
# novelty and diffusion (Mockus & Weiss 2000), structural complexity (Prime
# Video 2026), size (SmartBear/Cisco, where reviewer effectiveness collapses
# past ~400 lines). Size routes a change to be looked at; it never refuses one.
LANE_MAX_DIRS=4
LANE_MAX_LINES=400
LANE_MAX_BRANCH_POINTS=10

TMPDIRS=()
cleanup() {
  local d
  for d in ${TMPDIRS[@]+"${TMPDIRS[@]}"}; do
    [ -z "$d" ] || rm -rf -- "$d"
  done
}
trap cleanup EXIT

usage() {
  awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

die() { echo "error: $*" >&2; exit 1; }

# One place the routed repository is addressed. It guarantees nothing about path
# encoding on its own; that is what -z does at each call site that reads paths.
#
# Every such call site passes -z and reads NUL-delimited, never text lines. git
# C-quotes a path holding a double quote, a backslash or a control character
# UNCONDITIONALLY, and one holding a non-ASCII byte unless core.quotePath is
# off, so a line-based read hands on `"src/billing/led\"ger.rb"` - surrounding
# quotes included. That leading quote stopped an anchored critical-surface glob
# from matching, so a change on a declared safety surface was routed cheap and
# said so silently, and it made every blob_at read fail, which made both halves
# of the clean-revert proof compare empty to empty and succeed for a revert that
# undid nothing. A path holding a newline additionally split into two paths.
# -z removes the escaping rather than turning one class of it off, so
# core.quotePath is not set here: it would cover only the non-ASCII case and
# suggest a guarantee -z already provides in full.
repo_git() { git -C "$REPO" "$@"; }

# --- shared argument state --------------------------------------------------

TASK=
PROJECT=
REPO=
RANGE=
CLASS=
REVERT_OF=
OVERRIDE=
NOTE=
PATHS=()

need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; }

# --- class demonstrations ---------------------------------------------------

# A path is documentation by its PROSE EXTENSION or by its NAME, and by nothing
# else. There is no location rule and no shape rule: being under docs/ widens
# nothing, because a prose file there already qualifies on its own.
#
# NO FURTHER CLASSIFICATION BY SHAPE IS AUTHORIZED IN THIS POLICY. That is the
# constraint on whoever edits this next, not a note about the past. Anything new
# that has to be admitted gets NAMED.
#
# The rule is written that way because shape was tried three times and the
# repository produced a counter-example every time. A shape rule says "anything
# that LOOKS like prose", and in a real repository something always looks like it
# and is not:
#   - docs/conf.py looked like prose BY LOCATION, and executes at build time.
#   - docs/Makefile looked like prose BY HAVING NO EXTENSION, which on Unix is
#     the ordinary spelling for an executable.
#   - docs/requirements.txt looks like prose BY EXTENSION, and is the manifest
#     Read the Docs INSTALLS at build time.
# Each of those reached the cheap lane LABELLED AS PROSE, which is not only a
# classification gap but a false class written into the record this policy
# exists to measure. Naming does not infer: it forces someone to write the name
# down, and writing it down forces them to look at it.
#
# Every name below is reachable. The AUTHORS spellings were not: the portable
# *auth* glob claimed them first, so a contributors list never reached this
# function and was recorded as an authentication surface instead. That glob now
# passes AUTHORS through in the spellings this function accepts as prose, derived
# from the same owner both rules read, which makes AUTHORS ordinary documentation
# for any project that says nothing else about it, and expensive in this one
# because this repository names it a governing document in .fm-critical-surfaces.
# A spelling OUTSIDE that list - AUTHORS.org - keeps the authentication label as
# an accepted residual; fm_lane_authors_spelling records why.
# PROSE_FILE_NAMES is the single owner of the named prose files, and the ".txt
# suffix" rule is applied to it rather than restated beside it: the .txt
# spellings used to be a second copy of the same seven names, so adding a name
# to one line and forgetting the other was one edit away. fm_lane_prose_extensions
# in bin/fm-lane-lib.sh is the matching owner for the extensions, read here and
# by the AUTHORS exception to the *auth* glob. If there is a list, DERIVE FROM
# IT; do not copy it.
PROSE_FILE_NAMES='changelog readme notice authors contributors license licence'

is_documentation_path() {
  local p base stem ext name
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for ext in $(fm_lane_prose_extensions); do
    case "$p" in
      *."$ext") return 0 ;;
    esac
  done
  base=${p##*/}
  stem=${base%.txt}
  for name in $PROSE_FILE_NAMES; do
    [ "$base" != "$name" ] && [ "$stem" != "$name" ] || return 0
  done
  return 1
}

# A NAME SAYS WHAT SOMETHING IS CALLED, NOT WHAT IT IS. `guide.md` can be a
# symlink or an executable, and then the name is a perfect disguise: it passes
# every prose test above while being something else entirely. So a docs-only
# demonstration needs a PROSE NAME AND A PROSE OBJECT. The first is decided by
# the list above; the second is asked of the tree. Neither is sufficient alone.
#
# The object half is asked at the range's HEAD, because that is the state the
# delivery lands. An entry absent there is a deleted prose file, which is prose
# removed rather than a foreign object introduced, so it passes.
#
# It has to be asked directly rather than inferred from the mode disqualification
# cmd_decide computes, because that one only sees entries present on BOTH sides
# of the range: an ADDED entry has no prior mode to compare against, produces no
# mode CHANGE, and the gap read as harmless. Absence of signal taken for signal
# of absence, one more time - the seventh member of the family the captain
# tracks as fm-guardas-que-degradan-a-una-comprobacion-mas-debil.
#
# THE OBJECT IS ITS TYPE AND ITS CONTENT. A blob's mode is 100644 whatever bytes
# it holds, so the type half admitted a BINARY blob called guide.md as a prose
# object, and the row it produced said class docs-only next to binary=1 - a
# record refuting itself on its own line. The binary determination is the one
# the signal tier already makes, read here rather than taken again, so this file
# keeps one owner of what binary means. A count that is not exactly zero fails
# the demonstration, "-" included: a count nobody could establish is not zero.
demonstrate_docs_only() {
  local head=$1 binary=$2 p entry mode
  shift 2
  [ "$binary" = 0 ] || return 1
  for p in "$@"; do
    is_documentation_path "$p" || return 1
    entry=$(tree_entry_at "$head" "$p")
    [ -n "$entry" ] || continue
    mode=${entry%% *}
    [ "$mode" = 100644 ] || return 1
  done
  return 0
}

# "This change is exactly <sha> undone", proved from the trees rather than from
# a commit message, needs BOTH halves for every changed path: the base held
# <sha>'s tree entry, and the head holds <sha>^'s. Entry, not content: the mode
# is compared too, so a revert that leaves a file's exec bit flipped is not one.
# Checking only the second
# half is not enough - it passes for any commit whose parent happened to hold
# the same content, so a revert could be recorded against a commit it has
# nothing to do with. Requiring both also makes "<sha> never touched this path"
# fail on its own, since that would force base and head to agree on a path the
# diff says changed.
#
# The paths checked are the UNION of the range's and <sha>'s own, because the
# range's alone proved too little: a delivery undoing one of the two files <sha>
# modified never examined the other, so half of <sha> left applied demonstrated
# as "exactly <sha> undone" and reached the cheap lane. A path <sha> touched and
# the range left alone fails the second half, which is that partial revert.
#
# The enumeration must never fail into a weaker check. diff-tree --root reads a
# root commit's paths as the additions they are, where a diff against <sha>^ only
# errored - and that error, discarded, left the union empty and the check back to
# the range's paths alone, silently. It is read through a file so the command's
# exit status survives, and an enumeration that fails or yields nothing REFUSES
# the demonstration: a merge commit or an empty one has no first-parent paths to
# compare, and a claim nobody can read is not a claim that was demonstrated.
demonstrate_clean_revert() {
  local base=$1 head=$2 sha=$3 p own own_count=0
  local paths=("${@:4}")
  own=$(mktemp "${TMPDIR:-/tmp}/fm-lane-revert.XXXXXX") || return 1
  TMPDIRS+=("$own")
  repo_git diff-tree -r --root --no-commit-id --name-only -z --no-renames "$sha" >"$own" \
    || return 1
  while IFS= read -r -d '' p; do
    [ -z "$p" ] || { paths+=("$p"); own_count=$((own_count + 1)); }
  done <"$own"
  [ "$own_count" -gt 0 ] || return 1
  for p in ${paths[@]+"${paths[@]}"}; do
    [ "$(tree_entry_at "$base" "$p")" = "$(tree_entry_at "$sha" "$p")" ] || return 1
    [ "$(tree_entry_at "$head" "$p")" = "$(tree_entry_at "$sha^" "$p")" ] || return 1
  done
  return 0
}

# tree_entry_at <rev> <path> -> the tree entry's mode, type and object, or the
# empty string when the path is absent at that revision. Two absent sides
# compare equal, which is what a revert of an added file needs.
#
# THE MODE IS PART OF THE COMPARISON. Resolving the path to a blob id alone
# compared content and nothing else, so a revert that restored the content and
# left <sha>'s 100644-to-100755 flip applied still demonstrated as exactly <sha>
# undone: the script stayed executable, shipped with no pipeline review, and the
# record named it a clean revert. A symlink-for-regular-file swap over identical
# content passed the same way. Comparing the ENTRY rather than the object closes
# both without a special case for either.
#
# --literal-pathspecs because ls-tree takes a PATHSPEC, not a path, and the
# surrounding proof assumes a literal lookup. A file named ":colon.rb" had its
# leading colon eaten as a short-form magic signature, so the entry resolved to
# nothing at base, head, <sha> AND <sha>^ - and both halves then compared empty
# to empty and demonstrated a revert that undid nothing, which is the exact
# failure -z was adopted to remove, in a narrower spelling.
tree_entry_at() {
  repo_git --literal-pathspecs ls-tree --full-tree "$1" -- "$2" 2>/dev/null \
    | awk '{ print $1, $2, $3; exit }'
}

# --- decide -----------------------------------------------------------------

cmd_decide() {
  local evidence catalog hits critical lane reason signals note class_record
  local base head names numstat added udiff raw meta p q d seen
  local files dirs lines new_files branch_points binary unreadable repo_measured
  local mode_changes mode_disqualifies src_mode dst_mode
  local printed_signals class_evaluated base_measured head_measured
  local seen_dirs=()
  local signal_reasons=()

  [ -n "$TASK" ] || die "decide requires a task id"
  [ -n "$PROJECT" ] || die "decide requires --project <name>"
  [ -n "$REPO" ] || die "decide requires --repo <dir>, the project whose .fm-critical-surfaces completes the catalog"
  [ -d "$REPO" ] || die "--repo is not a directory: $REPO"
  [ -z "$CLASS" ] || validate_class_claim
  class_record=$(class_record_value) || exit 1

  if [ -n "$RANGE" ]; then
    [ "${#PATHS[@]}" -eq 0 ] || die "--paths is declared evidence and cannot be combined with --range"
    repo_git rev-parse --git-dir >/dev/null 2>&1 \
      || die "--repo is not a git repository: $REPO"
    case "$RANGE" in
      *...*) die "--range must be the two-dot <base>..<head> form; '$RANGE' asks for merge-base semantics this policy does not implement" ;;
      *..*) ;;
      *) die "--range must be <base>..<head> (got '$RANGE')" ;;
    esac
    base=${RANGE%%..*}
    head=${RANGE##*..}
    [ -n "$base" ] && [ -n "$head" ] || die "--range must name both sides: <base>..<head>"
    evidence=demonstrated
  else
    [ "${#PATHS[@]}" -gt 0 ] || die "decide needs evidence: --range for a real diff, or --paths for a declared list"
    evidence=declared
    base=
    head=
  fi

  if [ "$evidence" = demonstrated ]; then
    names=$(mktemp "${TMPDIR:-/tmp}/fm-lane-names.XXXXXX")
    TMPDIRS+=("$names")
    repo_git diff --name-only -z --no-renames "$base" "$head" >"$names" \
      || die "cannot read the diff $RANGE in $REPO"
    while IFS= read -r -d '' p; do
      [ -z "$p" ] || PATHS+=("$p")
    done <"$names"
    [ "${#PATHS[@]}" -gt 0 ] || die "$RANGE changes nothing in $REPO; there is no delivery to route"
  fi

  catalog=$(mktemp "${TMPDIR:-/tmp}/fm-lane-catalog.XXXXXX")
  TMPDIRS+=("$catalog")
  fm_lane_catalog "$REPO" >"$catalog" || exit 1
  hits=$(fm_lane_critical_hits "$catalog" "${PATHS[@]}") || exit 1
  critical=$(printf '%s\n' "$hits" | paste -sd, -)
  critical=${critical:--}

  files=${#PATHS[@]}
  # Counted off the array rather than through a newline-delimited stream, the
  # same way files reads ${#PATHS[@]}. Printing one path per line re-split a
  # path holding a newline that PATHS had just been read NUL-delimited to keep
  # whole, so a single file under one directory reported dirs=2.
  dirs=0
  seen_dirs=()
  for p in ${PATHS[@]+"${PATHS[@]}"}; do
    d=${p%/*}
    [ "$d" != "$p" ] || d=.
    seen=0
    for q in ${seen_dirs[@]+"${seen_dirs[@]}"}; do
      [ "$q" != "$d" ] || { seen=1; break; }
    done
    [ "$seen" -eq 1 ] || { seen_dirs+=("$d"); dirs=$((dirs + 1)); }
  done
  lines=-
  new_files=-
  branch_points=-
  binary=-
  mode_changes=-
  unreadable=0
  # EVERY read here reports whether it succeeded, and a read that fails leaves
  # its signal at "-". Stated exactly, because this comment has over-claimed
  # once already: a decision that REACHES THE SIGNAL TIER then routes expensive
  # with reason signals:unreadable-diff. A claimed class answers above that
  # tier, so an unreadable signal never reaches it - with one exception, the
  # MODE count, which disqualifies the class tier as well, since a count nobody
  # could establish is not a count of zero. A pipeline discards
  # git's exit status and `|| true` cannot tell "git failed and produced
  # nothing" from "nothing matched", so a broken diff driver on one path used to
  # resolve the whole delivery's complexity to 0 - the cheapest value there is -
  # and the record then claimed a measurement nobody took.
  if [ "$evidence" = demonstrated ]; then
    added=$(mktemp "${TMPDIR:-/tmp}/fm-lane-added.XXXXXX")
    TMPDIRS+=("$added")
    if repo_git diff --diff-filter=A --name-only -z --no-renames "$base" "$head" >"$added" 2>/dev/null; then
      new_files=0
      while IFS= read -r -d '' p; do
        [ -z "$p" ] || new_files=$((new_files + 1))
      done <"$added"
    else
      unreadable=1
    fi
    # git reports a binary path as "-" for both counts because there are no
    # lines to count. Tier 3 decides on size, novelty, diffusion and complexity,
    # and not one of them can be computed for a blob, so a binary path is
    # UNMEASURABLE rather than small - the awk below resolves it to 0, which is
    # the number the record would otherwise claim it measured.
    if numstat=$(repo_git diff --numstat --no-renames "$base" "$head" 2>/dev/null); then
      lines=$(printf '%s\n' "$numstat" | awk '{ a=$1; d=$2; if (a=="-") a=0; if (d=="-") d=0; s+=a+d } END { printf "%d", s+0 }')
      binary=$(printf '%s\n' "$numstat" | awk '$1=="-" && $2=="-" { n++ } END { printf "%d", n+0 }')
    else
      unreadable=1
    fi
    udiff=$(mktemp "${TMPDIR:-/tmp}/fm-lane-udiff.XXXXXX")
    TMPDIRS+=("$udiff")
    if repo_git diff --unified=0 --no-renames "$base" "$head" >"$udiff" 2>/dev/null; then
      branch_points=$(grep '^+' "$udiff" | grep -v '^+++' \
        | grep -cE '(^|[^[:alnum:]_])(if|elif|else|for|while|case|switch|catch|except|unless)([^[:alnum:]_]|$)|&&|\|\|' || true)
    else
      unreadable=1
    fi
    # A MODE CHANGE LEAVES TIER 3 NOTHING TO MEASURE. `chmod +x` makes a file
    # EXECUTABLE and writes not one line of diff: numstat reports 0 0, the
    # unified diff carries no added line, and size, novelty, complexity and
    # binary all come out at their cheapest value honestly, so the change took
    # the cheap lane with every signal reporting zero.
    #
    # This is the sixth member of the family tracked as
    # fm-guardas-que-degradan-a-una-comprobacion-mas-debil, and the purest
    # specimen of it: the guard does not measure wrongly, there is NOTHING to
    # measure, and it treats that emptiness as harmless. ABSENCE OF SIGNAL IS
    # NOT SIGNAL OF ABSENCE. A mode change never reaches the cheap lane.
    #
    # NEVER MEANS BY NO ROUTE, which is why mode_disqualifies below is read by
    # the CLASS tier and not only here. Written as a tier-3 signal alone, the
    # rule above was false the moment a class was claimed: a demonstrated
    # docs-only answers first and never looks at the count, so `chmod +x
    # README.md` shipped labelled documentation with mode=1 in the same row.
    # A path's NAME is all docs-only proves, and a name says nothing about the
    # entry's mode, so the class cannot stand in for this check.
    #
    # The raw diff carries the modes the numstat line cannot, one
    # ":<src> <dst> <srcsha> <dstsha> <status>" record per path. A side that
    # does not exist is 000000, so an addition and a deletion are not mode
    # CHANGES and are not counted; what is counted is an entry both revisions
    # hold whose mode moved, which is the exec-bit flip and the
    # regular-file-to-symlink swap alike.
    raw=$(mktemp "${TMPDIR:-/tmp}/fm-lane-raw.XXXXXX")
    TMPDIRS+=("$raw")
    if repo_git diff --raw -z --no-renames "$base" "$head" >"$raw" 2>/dev/null; then
      mode_changes=0
      while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
        [ -n "$p" ] || continue
        src_mode=${meta%% *}
        src_mode=${src_mode#:}
        dst_mode=${meta#* }
        dst_mode=${dst_mode%% *}
        [ "$src_mode" != "$dst_mode" ] || continue
        [ "$src_mode" != 000000 ] && [ "$dst_mode" != 000000 ] || continue
        mode_changes=$((mode_changes + 1))
      done <"$raw"
    else
      unreadable=1
    fi
  fi
  # UNKNOWN AND ZERO ARE NOT THE SAME ANSWER. "-" means the raw read failed and
  # the count was never established, and reading that as "no mode change" is the
  # same defect this tier exists to close, two lines from where the file says so.
  # It disqualifies like any other count that is not zero.
  #
  # Declared evidence is a different case, not an unestablished one: there is no
  # range to measure, and that grade already refuses the cheap lane on its own,
  # so the disqualification is a property of a MEASURED range only. Applying it
  # to declared evidence would rewrite a declared class claim's row from
  # class-not-demonstrated to evidence-not-demonstrated, which says less.
  mode_disqualifies=0
  if [ "$evidence" = demonstrated ] && [ "$mode_changes" != 0 ]; then
    mode_disqualifies=1
  fi
  # The tree that was actually read, resolved physically so two spellings of one
  # tree record identically. --repo and --project are independent inputs, so a
  # --repo pointing at the wrong clone produced a decision byte-indistinguishable
  # from a correct one: critical-surfaces: - for a path that IS a surface in the
  # project named. A disclaimer would only say the measurement might have been
  # wrong; recording the tree says WHICH one it was, and turns a permanent doubt
  # into a checkable fact. A record that cannot tell a good decision from a bad
  # one does not measure, it decorates.
  #
  # It is the only free-text value in a field the format declares to be k=v, and
  # a comma is legal in a directory name, so the separator is escaped inside the
  # value: a comma becomes \, and a backslash \\. Without that, a project under
  # /x/acme,inc/repo split into a bare token with no = and the recorded tree
  # stopped being recoverable, which is the one thing recording it was for.
  repo_measured=$(cd "$REPO" && pwd -P) || die "--repo cannot be resolved: $REPO"
  repo_measured=${repo_measured//\\/\\\\}
  repo_measured=${repo_measured//,/\\,}
  signals="files=$files,dirs=$dirs,lines=$lines,new-files=$new_files,branch-points=$branch_points,binary=$binary,mode=$mode_changes,repo=$repo_measured"
  # The same argument as repo=, one level over: --range is the other independent
  # input, so a decision measured against the WRONG range was byte-identical to
  # a correct one. That costs something real on the one path the record lifts a
  # control - a later demonstrated decision clears a critical-surface binding
  # without any check that its range has anything to do with the delivery - so a
  # reviewer could not tell an honest correction from a stale or mistaken one.
  # Resolved to full commit ids, so two spellings of one commit record
  # identically and a branch name that later moves cannot rewrite what was read.
  # A DECLARED decision has no range and records no entry at all: absent and
  # unknown must stay different answers.
  if [ "$evidence" = demonstrated ]; then
    base_measured=$(repo_git rev-parse --verify --quiet "$base^{commit}") \
      || die "cannot resolve the range's base in $REPO: $base"
    head_measured=$(repo_git rev-parse --verify --quiet "$head^{commit}") \
      || die "cannot resolve the range's head in $REPO: $head"
    signals="$signals,range=$base_measured..$head_measured"
  fi

  class_evaluated=
  if [ -n "$OVERRIDE" ]; then
    lane=direct-PR
    reason=captain-override
    note="captain: $OVERRIDE"
    [ -z "$NOTE" ] || note="$note | firstmate: $NOTE"
  elif [ "$critical" != - ]; then
    lane=no-mistakes
    reason="critical-surface"
    note=$NOTE
  elif [ -n "$CLASS" ] && [ "$mode_disqualifies" -eq 0 ]; then
    note=$NOTE
    class_evaluated=$class_record
    if [ "$evidence" != demonstrated ]; then
      lane=no-mistakes
      reason=class-not-demonstrated
    elif demonstrate_class "$base" "$head" "$binary"; then
      lane=direct-PR
      reason=standard-class
    else
      lane=no-mistakes
      reason=class-not-demonstrated
    fi
  elif [ "$evidence" != demonstrated ]; then
    lane=no-mistakes
    reason="evidence-not-demonstrated"
    note=$NOTE
  else
    note=$NOTE
    if [ "$unreadable" -eq 1 ]; then
      signal_reasons+=(unreadable-diff)
    else
      [ "$binary" -eq 0 ] || signal_reasons+=(binary)
      [ "$mode_changes" -eq 0 ] || signal_reasons+=(mode)
      [ "$new_files" -eq 0 ] || signal_reasons+=(novelty)
      [ "$dirs" -lt "$LANE_MAX_DIRS" ] || signal_reasons+=(diffusion)
      [ "$branch_points" -lt "$LANE_MAX_BRANCH_POINTS" ] || signal_reasons+=(complexity)
      [ "$lines" -lt "$LANE_MAX_LINES" ] || signal_reasons+=(size)
    fi
    if [ "${#signal_reasons[@]}" -eq 0 ]; then
      lane=direct-PR
      reason=low-signal
    else
      lane=no-mistakes
      reason="signals:$(IFS=+; printf '%s' "${signal_reasons[*]}")"
    fi
  fi

  fm_lane_append decide "$TASK" "$PROJECT" "$lane" "$evidence" "$reason" \
    "${class_evaluated:--}" "$critical" "$signals" "${note:--}" || exit 1

  printf 'lane=%s evidence=%s reason=%s\n' "$lane" "$evidence" "$reason"
  printf 'task: %s\nproject: %s\n' "$TASK" "$PROJECT"
  printf 'critical-surfaces: %s\n' "$critical"
  printf 'class: %s\n' "${class_evaluated:--}"
  printed_signals=${signals//\\\\/$'\002'}
  printed_signals=${printed_signals//\\,/$'\001'}
  printed_signals=${printed_signals//,/ }
  printed_signals=${printed_signals//$'\001'/,}
  printf 'signals: %s\n' "${printed_signals//$'\002'/\\}"
  printf 'record: %s\n' "$(fm_lane_log_path)"
  if [ "$lane" = no-mistakes ] && [ "$reason" = "critical-surface" ]; then
    printf 'note: a critical surface routes to the expensive lane whatever the other signals say.\n'
  fi
}

# Whether the claim is even a well-formed one, checked on EVERY evidence grade
# before any lane is chosen. It is separate from the demonstration below because
# the demonstration only runs on demonstrated evidence: a class nobody can
# demonstrate is still the expensive lane, but a class that does not exist, or
# one missing the flag its demonstration needs, is a refusal - otherwise it is
# accepted and written into the record as if it were a real claim, and the
# record is what makes this policy reviewable.
validate_class_claim() {
  case "$CLASS" in
    docs-only)
      [ -z "$REVERT_OF" ] || die "--class docs-only takes no --revert-of"
      ;;
    clean-revert)
      [ -n "$REVERT_OF" ] || die "--class clean-revert requires --revert-of <sha>"
      ;;
    *)
      die "--class must be one of docs-only, clean-revert (got '$CLASS')"
      ;;
  esac
}

# The class column carries what DEMONSTRATED the class, not only its name: two
# clean reverts of different commits were otherwise byte-identical rows, and the
# demonstrating input is exactly what a reviewer re-checks when a defect turns up
# months later. IDENTIFIERS ONLY, never free text, or the column becomes prose
# again.
class_record_value() {
  local resolved
  case "$CLASS" in
    '') printf '%s' - ;;
    clean-revert)
      resolved=$(repo_git rev-parse --verify --quiet "$REVERT_OF^{commit}" 2>/dev/null) \
        || die "--revert-of does not resolve to a commit in $REPO: $REVERT_OF"
      printf 'clean-revert:%s' "$resolved"
      ;;
    *) printf '%s' "$CLASS" ;;
  esac
}

demonstrate_class() {
  local base=$1 head=$2 binary=$3
  case "$CLASS" in
    docs-only)    demonstrate_docs_only "$head" "$binary" "${PATHS[@]}" ;;
    clean-revert) demonstrate_clean_revert "$base" "$head" "$REVERT_OF" "${PATHS[@]}" ;;
    *)            return 1 ;;
  esac
}

# --- escape -----------------------------------------------------------------

cmd_escape() {
  [ -n "$TASK" ] || die "escape requires a task id"
  [ -n "$NOTE" ] || die "escape requires --note <what the defect was>"
  fm_lane_append escape "$TASK" "${PROJECT:--}" - - - - - - "$NOTE" || exit 1
  printf 'recorded escape for %s in %s\n' "$TASK" "$(fm_lane_log_path)"
}

# --- dispatch ---------------------------------------------------------------

[ "$#" -gt 0 ] || { usage; exit 1; }
SUB=$1
shift
case "$SUB" in
  -h|--help|help) usage; exit 0 ;;
  decide|escape) ;;
  *) die "unknown subcommand: $SUB (try --help)" ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) need_value "$@"; PROJECT=$2; shift 2 ;;
    --project=*) PROJECT=${1#--project=}; shift ;;
    --repo) need_value "$@"; REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#--repo=}; shift ;;
    --range) need_value "$@"; RANGE=$2; shift 2 ;;
    --range=*) RANGE=${1#--range=}; shift ;;
    --class) need_value "$@"; CLASS=$2; shift 2 ;;
    --class=*) CLASS=${1#--class=}; shift ;;
    --revert-of) need_value "$@"; REVERT_OF=$2; shift 2 ;;
    --revert-of=*) REVERT_OF=${1#--revert-of=}; shift ;;
    --captain-override) need_value "$@"; OVERRIDE=$2; shift 2 ;;
    --captain-override=*) OVERRIDE=${1#--captain-override=}; shift ;;
    --note) need_value "$@"; NOTE=$2; shift 2 ;;
    --note=*) NOTE=${1#--note=}; shift ;;
    --paths)
      shift
      [ "$#" -gt 0 ] || die "--paths requires at least one path"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --*) break ;;
        esac
        PATHS+=("$1")
        shift
      done
      ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option: $1" ;;
    *)
      [ -z "$TASK" ] || die "unexpected argument: $1"
      TASK=$1
      shift
      ;;
  esac
done

case "$SUB" in
  decide) cmd_decide ;;
  escape) cmd_escape ;;
esac
