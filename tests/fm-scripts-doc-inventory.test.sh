#!/usr/bin/env bash
# Structural regression tests for the bin/ toolbelt inventory in docs/scripts.md.
#
# docs/scripts.md is an owned inventory contract, not incidental prose: its own
# header declares the table is the toolbelt roster and that "each row is one
# purpose clause only". The contract this file pins is completeness and shape -
# every script file the fleet ships under bin/ (and bin/backends/) is named by
# exactly one row, no row names a script that does not exist, and every row is a
# well-formed two-cell Markdown row so the table still renders. A script added
# to bin/ without a row makes the roster silently wrong, which is the regression
# this catches.
#
# The table is parsed into a normalized name -> purpose model and asserted
# against the real filesystem inventory; no assertion here depends on the prose
# of any particular purpose clause.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOC="$ROOT/docs/scripts.md"
TMP_ROOT=$(fm_test_tmproot fm-scripts-doc)

# Real inventory: script files directly under bin/ and bin/backends/, named the
# way the table names them (backends/ entries keep their one-level prefix).
inventory() {
  local root=$1
  {
    find "$root/bin" -maxdepth 1 -type f -print
    [ -d "$root/bin/backends" ] && find "$root/bin/backends" -maxdepth 1 -type f -print
  } 2>/dev/null | sed "s|^$root/bin/||" | LC_ALL=C sort -u
}

# Parse the Markdown table into "<script>\t<purpose>" records. Only rows whose
# first cell is a single `name` or [`name`](link) code span are inventory rows,
# which skips the header and the alignment separator without pattern-matching
# prose.
parse_rows() {
  awk -F'|' '
    /^\|/ {
      name = $2; purpose = $3
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      gsub(/^[ \t]+|[ \t]+$/, "", purpose)
      if (match(name, /^\[`[^`]+`\]\(.*\)$/)) { sub(/^\[`/, "", name); sub(/`\].*$/, "", name) }
      else if (match(name, /^`[^`]+`$/)) { gsub(/`/, "", name) }
      else next
      print name "\t" purpose
    }
  ' "$1"
}

test_every_bin_script_has_exactly_one_row() {
  local documented dupes missing extra
  parse_rows "$DOC" | cut -f1 >"$TMP_ROOT/documented.raw"
  inventory "$ROOT" >"$TMP_ROOT/actual"

  dupes=$(LC_ALL=C sort "$TMP_ROOT/documented.raw" | uniq -d)
  [ -z "$dupes" ] || fail "docs/scripts.md lists a script more than once: $(printf '%s ' $dupes)"

  LC_ALL=C sort -u "$TMP_ROOT/documented.raw" >"$TMP_ROOT/documented"
  documented=$(wc -l <"$TMP_ROOT/documented" | tr -d ' ')

  missing=$(comm -23 "$TMP_ROOT/actual" "$TMP_ROOT/documented")
  [ -z "$missing" ] || fail "bin/ scripts with no row in docs/scripts.md: $(printf '%s ' $missing)"

  extra=$(comm -13 "$TMP_ROOT/actual" "$TMP_ROOT/documented")
  [ -z "$extra" ] || fail "docs/scripts.md rows naming no such file under bin/: $(printf '%s ' $extra)"

  pass "docs/scripts.md documents every one of the $documented scripts under bin/, and only those"
}

test_every_row_is_a_renderable_two_cell_row() {
  local bad empty
  # A rendered row is exactly two cells: leading pipe, separator, trailing pipe.
  bad=$(awk -F'|' 'NR>1 && /^\|/ && NF != 4 { printf "line %d (%d cells); ", NR, NF-2 }' "$DOC")
  [ -z "$bad" ] || fail "docs/scripts.md has rows that would not render as two columns: $bad"

  empty=$(parse_rows "$DOC" | awk -F'\t' '$2 == "" { printf "%s ", $1 }')
  [ -z "$empty" ] || fail "docs/scripts.md rows with an empty purpose cell: $empty"

  pass "every docs/scripts.md table row renders as two columns with a non-empty purpose clause"
}

test_missing_row_is_detected() {
  # The guard must actually fail when a script loses its row, otherwise the two
  # checks above could pass vacuously.
  local fixture out rc
  fixture="$TMP_ROOT/fixture"
  mkdir -p "$fixture/bin/backends"
  : >"$fixture/bin/fm-documented.sh"
  : >"$fixture/bin/backends/undocumented.sh"
  inventory "$fixture" >"$TMP_ROOT/fixture.actual"
  assert_contains "$(cat "$TMP_ROOT/fixture.actual")" "backends/undocumented.sh" \
    "inventory did not enumerate a backends/ script"

  cat >"$fixture/scripts.md" <<'MD'
| Script | Purpose |
| ------ | ------- |
| `fm-documented.sh` | Do the one documented thing |
MD
  parse_rows "$fixture/scripts.md" | cut -f1 | LC_ALL=C sort -u >"$TMP_ROOT/fixture.documented"
  out=$(comm -23 "$TMP_ROOT/fixture.actual" "$TMP_ROOT/fixture.documented")
  rc=$?
  [ "$rc" -eq 0 ] || fail "fixture comparison failed to run"
  [ "$out" = "backends/undocumented.sh" ] \
    || fail "gap detection did not report the single undocumented script (got: $out)"

  pass "an undocumented script under bin/ is reported as a gap rather than passing silently"
}

test_every_bin_script_has_exactly_one_row
test_every_row_is_a_renderable_two_cell_row
test_missing_row_is_detected
