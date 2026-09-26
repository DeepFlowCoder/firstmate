#!/usr/bin/env bash
# shellcheck disable=SC2016 # Every backtick here is literal Markdown from the table under test.
# Behavior tests for the bin/ toolbelt inventory guard.
#
# The check exists because docs/scripts.md was a list nothing held to bin/, and
# by the time the guard was written the list had already lost a row without
# anyone noticing. So these tests are aimed at the one property that makes such a
# guard worth committing: that it can be SEEN TO REFUSE. Every case drives the
# real bin/fm-scripts-inventory-check.sh over a fixture repository through its
# own interface, and none of them reads the check's source.
#
# The last case is a degradation matrix over the check's input channels, held to
# the invariant owned by tests/fm-lane-degradation.test.sh's header: making a
# read fail must never turn an input that FAILS the check into one that passes.
# Its negative control is therefore a repository that really has drifted, and
# each channel is made unevaluable in turn with that drift still in place.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-scripts-inventory-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-scripts-inventory)

# A case removes read and search permission from fixture directories, and the
# registered cleanup cannot remove what it cannot enter.
inventory_cleanup() { chmod -R u+rwX "$TMP_ROOT" 2>/dev/null || true; }
fm_test_exit_trap inventory_cleanup

RUN_OUT=
RUN_CODE=0

run_check() {
  RUN_CODE=0
  RUN_OUT=$("$@" 2>&1) || RUN_CODE=$?
}

expect_refusal() {  # <label> <expected-substring> <command...>
  local label=$1 expected=$2
  shift 2
  run_check "$@"
  [ "$RUN_CODE" -ne 0 ] ||
    fail "$label: the check reported success"$'\n'"--- output ---"$'\n'"$RUN_OUT"
  assert_contains "$RUN_OUT" "$expected" "$label: the refusal did not name '$expected'"
}

expect_pass() {  # <label> <command...>
  local label=$1
  shift
  run_check "$@"
  [ "$RUN_CODE" -eq 0 ] ||
    fail "$label: the check refused"$'\n'"--- output ---"$'\n'"$RUN_OUT"
}

# --- fixtures ---------------------------------------------------------------
#
# A fixture is a git repository holding only what the check reads: a bin/ tree
# and a docs/scripts.md describing it. The matching doc is GENERATED from the
# file list, so an "exact bijection" fixture is one by construction rather than
# by the author having counted correctly.

FIXTURE_REPO=

# write_matching_doc <repo> <script>...
write_matching_doc() {
  local repo=$1 name
  shift
  mkdir -p "$repo/docs"
  {
    printf '# The bin/ toolbelt\n\n'
    printf 'Prose above the table, which the check walks past.\n\n'
    printf '| Script | Purpose |\n'
    printf '| ------ | ------- |\n'
    for name in "$@"; do
      printf '| `%s` | purpose of %s |\n' "$name" "$name"
    done
    printf '\nProse below the table, which closes it.\n'
  } > "$repo/docs/scripts.md"
}

# write_doc_rows <repo> <verbatim row line>...
# For the cases that must present a row the generator would never produce.
write_doc_rows() {
  local repo=$1 row
  shift
  mkdir -p "$repo/docs"
  {
    printf '# The bin/ toolbelt\n\n'
    printf '| Script | Purpose |\n'
    printf '| ------ | ------- |\n'
    for row in "$@"; do
      printf '%s\n' "$row"
    done
    printf '\nProse below the table.\n'
  } > "$repo/docs/scripts.md"
}

# make_fixture <name> <script>... -> sets FIXTURE_REPO
make_fixture() {
  local name=$1 repo script
  shift
  repo="$TMP_ROOT/$name"
  mkdir -p "$repo/bin"
  git init -q "$repo"
  for script in "$@"; do
    mkdir -p "$(dirname "$repo/bin/$script")"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/$script"
    chmod +x "$repo/bin/$script"
  done
  write_matching_doc "$repo" "$@"
  git -C "$repo" add -A
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm fixture
  FIXTURE_REPO=$repo
}

# --- 1. the repository's own list -------------------------------------------

test_the_repository_list_is_a_bijection() {
  local scripts rows
  expect_pass "this repository" "$CHECK"
  assert_contains "$RUN_OUT" "ok scripts=" "the check did not report the file count it established"
  assert_contains "$RUN_OUT" "rows=" "the check did not report the row count it established"
  scripts=$(printf '%s\n' "$RUN_OUT" | sed -n 's/.*scripts=\([0-9]\{1,\}\).*/\1/p')
  rows=$(printf '%s\n' "$RUN_OUT" | sed -n 's/.*rows=\([0-9]\{1,\}\).*/\1/p')
  [ -n "$scripts" ] && [ -n "$rows" ] || fail "the ok line carried no readable counts: $RUN_OUT"
  [ "$scripts" -gt 1 ] ||
    fail "the check established only $scripts files under bin/, which this repository cannot have"
  [ "$scripts" = "$rows" ] ||
    fail "the check reported $scripts files against $rows rows and still passed"
  pass "docs/scripts.md holds exactly one row per file under bin/ ($scripts of each)"
}

# --- 2. a matching fixture passes -------------------------------------------

test_an_exact_fixture_passes() {
  make_fixture exact fm-one.sh fm-two.sh backends/tmux.sh
  expect_pass "a matching fixture" "$CHECK" --root "$FIXTURE_REPO"
  assert_contains "$RUN_OUT" "ok scripts=3 rows=3" "the fixture's counts were not reported"
  pass "a fixture with one row per file, including a bin/backends/ entry, passes"
}

# --- 3. THE REFUSAL THE GUARD EXISTS FOR ------------------------------------

test_a_deleted_row_turns_the_check_red() {
  local doc
  make_fixture deleted-row fm-one.sh fm-two.sh backends/tmux.sh
  doc="$FIXTURE_REPO/docs/scripts.md"

  # Delete one row, exactly as a future contributor's change would leave it.
  grep -v 'fm-two.sh' "$doc" > "$doc.cut"
  mv "$doc.cut" "$doc"
  expect_refusal "a deleted row" "bin/fm-two.sh has no row" "$CHECK" --root "$FIXTURE_REPO"
  assert_contains "$RUN_OUT" "and bin/ disagree" "the refusal did not say the two sides disagree"

  # Restored, it is green again: the guard tracks the list, not the file.
  write_matching_doc "$FIXTURE_REPO" fm-one.sh fm-two.sh backends/tmux.sh
  expect_pass "the restored row" "$CHECK" --root "$FIXTURE_REPO"
  pass "deleting a row turns the check red and restoring it turns it green again"
}

test_a_new_script_without_a_row_turns_the_check_red() {
  make_fixture new-script fm-one.sh fm-two.sh

  # Untracked on purpose: a script written but not yet staged is already inside
  # the check, so its author meets the refusal before committing, not after.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_REPO/bin/fm-three.sh"
  expect_refusal "an unlisted new script" "bin/fm-three.sh has no row" \
    "$CHECK" --root "$FIXTURE_REPO"

  git -C "$FIXTURE_REPO" add bin/fm-three.sh
  expect_refusal "an unlisted staged script" "bin/fm-three.sh has no row" \
    "$CHECK" --root "$FIXTURE_REPO"

  write_matching_doc "$FIXTURE_REPO" fm-one.sh fm-two.sh fm-three.sh
  expect_pass "the added row" "$CHECK" --root "$FIXTURE_REPO"
  pass "adding a script without its row turns the check red, whether staged or not"
}

test_a_row_naming_no_file_turns_the_check_red() {
  make_fixture stale-row fm-one.sh fm-two.sh
  write_matching_doc "$FIXTURE_REPO" fm-one.sh fm-two.sh fm-retired.sh
  expect_refusal "a row for a deleted script" \
    'the row for `fm-retired.sh` names no file under bin/' "$CHECK" --root "$FIXTURE_REPO"
  pass "a row left behind by a deleted script turns the check red"
}

test_a_script_whose_name_git_quotes_still_needs_a_row() {
  local accented='fm-señal.sh' quoted='fm-"quoted".sh'
  make_fixture quoted-names fm-one.sh

  # git's line-delimited listing quotes both of these names, so a check reading
  # that listing by line would never see them at all.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_REPO/bin/$accented"
  expect_refusal "an unlisted script with a non-ASCII name" "bin/$accented has no row" \
    "$CHECK" --root "$FIXTURE_REPO"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_REPO/bin/$quoted"
  git -C "$FIXTURE_REPO" add -A
  expect_refusal "an unlisted script with a quote in its name" "bin/$quoted has no row" \
    "$CHECK" --root "$FIXTURE_REPO"

  write_matching_doc "$FIXTURE_REPO" fm-one.sh "$accented" "$quoted"
  expect_pass "rows for the names git quotes" "$CHECK" --root "$FIXTURE_REPO"
  assert_contains "$RUN_OUT" "ok scripts=3 rows=3" "the fixture's counts were not reported"
  pass "a file whose name git quotes is inside the inventory, not silently dropped"
}

test_a_bin_name_no_row_can_spell_is_refused() {
  local newline_name
  make_fixture newline-name fm-one.sh
  newline_name='fm-two'$'\n''line.sh'

  # A row cannot spell this name and the comparison cannot carry it, so it is
  # refused rather than split into two files that rows might appear to cover.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_REPO/bin/$newline_name"
  expect_refusal "a bin/ name holding a newline" "contains a newline" \
    "$CHECK" --root "$FIXTURE_REPO"

  rm -f "$FIXTURE_REPO/bin/$newline_name"
  expect_pass "the fixture without it" "$CHECK" --root "$FIXTURE_REPO"
  pass "a bin/ name no row can spell is refused rather than split across the comparison"
}

# --- 4. the row contract ----------------------------------------------------

test_both_row_forms_are_read_and_a_misdirected_link_is_refused() {
  make_fixture row-forms fm-one.sh fm-two.sh

  write_doc_rows "$FIXTURE_REPO" \
    '| [`fm-one.sh`](../bin/fm-one.sh) | purpose of fm-one.sh |' \
    '| `fm-two.sh` | purpose of fm-two.sh |'
  expect_pass "the linked row form" "$CHECK" --root "$FIXTURE_REPO"

  # A row that names one script and links another sends a reader to the wrong
  # header, which is drift inside a row rather than between the two sides.
  write_doc_rows "$FIXTURE_REPO" \
    '| [`fm-one.sh`](../bin/fm-two.sh) | purpose of fm-one.sh |' \
    '| `fm-two.sh` | purpose of fm-two.sh |'
  expect_refusal "a row linking a different script" \
    "links to ../bin/fm-two.sh instead of the ../bin/fm-one.sh it names" \
    "$CHECK" --root "$FIXTURE_REPO"
  pass "both row forms are read, and a link to another script is refused"
}

test_an_unparseable_row_is_refused_not_skipped() {
  make_fixture bad-rows fm-one.sh fm-two.sh
  local good='| `fm-one.sh` | purpose of fm-one.sh |'

  # Each of these is a row the check cannot read. Skipping one would report the
  # file it was meant to cover as missing - a true alarm for the wrong reason -
  # or, had that file been deleted in the same change, as nothing at all.
  write_doc_rows "$FIXTURE_REPO" "$good" '| fm-two.sh | purpose of fm-two.sh |'
  expect_refusal "a first cell with no backticks" "first cell is neither" \
    "$CHECK" --root "$FIXTURE_REPO"

  write_doc_rows "$FIXTURE_REPO" "$good" '| `fm-two.sh` `and-another.sh` | purpose |'
  expect_refusal "a first cell naming two things" "names more than one thing" \
    "$CHECK" --root "$FIXTURE_REPO"

  write_doc_rows "$FIXTURE_REPO" "$good" '| `fm-two.sh` |    |'
  expect_refusal "a row with an empty purpose" "has an empty purpose cell" \
    "$CHECK" --root "$FIXTURE_REPO"

  write_doc_rows "$FIXTURE_REPO" "$good" '| `fm-two.sh`'
  expect_refusal "a row with no purpose cell at all" "has no purpose cell" \
    "$CHECK" --root "$FIXTURE_REPO"

  write_doc_rows "$FIXTURE_REPO" "$good" '| `../outside.sh` | purpose |'
  expect_refusal "a row naming a path outside bin/" "names a path outside bin/" \
    "$CHECK" --root "$FIXTURE_REPO"

  write_doc_rows "$FIXTURE_REPO" "$good" \
    '| `fm-two.sh` | purpose of fm-two.sh |' \
    '| `fm-two.sh` | a second row for the same script |'
  expect_refusal "a duplicated row" "lists the same script more than once" \
    "$CHECK" --root "$FIXTURE_REPO"
  pass "a row the check cannot read, or reads twice, is refused rather than skipped"
}

test_a_table_that_cannot_be_located_is_refused() {
  local doc
  make_fixture table-shape fm-one.sh
  doc="$FIXTURE_REPO/docs/scripts.md"

  # No table at all. An empty row set is not "no drift"; it is no measurement.
  printf '# The bin/ toolbelt\n\nNo table here.\n' > "$doc"
  expect_refusal "a doc with no table" 'has no "| Script | Purpose |" toolbelt table' \
    "$CHECK" --root "$FIXTURE_REPO"

  # A header with no delimiter row beneath it is not this table's shape, so the
  # lines under it are not read as rows merely for beginning with a pipe.
  printf '# T\n\n| Script | Purpose |\n| `fm-one.sh` | p |\n' > "$doc"
  expect_refusal "a header with no delimiter" "not followed by a delimiter row" \
    "$CHECK" --root "$FIXTURE_REPO"

  # A header with nothing after it at all.
  printf '# T\n\n| Script | Purpose |\n' > "$doc"
  expect_refusal "a header with nothing after it" "with no rows" \
    "$CHECK" --root "$FIXTURE_REPO"

  # A second table is a second inventory, and an inventory nobody checks is how
  # the first one drifted.
  write_matching_doc "$FIXTURE_REPO" fm-one.sh
  printf '\n| Other | Table |\n| ----- | ----- |\n| `fm-nine.sh` | p |\n' >> "$doc"
  expect_refusal "a second table" "a second table follows" "$CHECK" --root "$FIXTURE_REPO"
  pass "a table the check cannot locate, or a second one, is refused"
}

# --- 5. the degradation matrix ----------------------------------------------
#
# Negative control: a repository that really has drifted. Every probe below
# leaves that drift in place and makes one input channel unevaluable, and the
# assertion is that the check still does not pass - and does not decline in
# silence either, because a guard that refuses without saying so reads from
# outside exactly like one that passed.

assert_never_silently_green() {  # <label>
  local label=$1
  [ "$RUN_CODE" -ne 0 ] ||
    fail "$label: a drifted repository passed"$'\n'"--- output ---"$'\n'"$RUN_OUT"
  [ -n "$RUN_OUT" ] ||
    fail "$label: the check refused in silence (exit $RUN_CODE, no output)"
}

test_every_input_channel_made_unevaluable_still_refuses() {
  local repo doc fakebin probed=0
  make_fixture degradation fm-one.sh fm-two.sh
  repo=$FIXTURE_REPO
  doc="$repo/docs/scripts.md"

  # The drift every probe below must be unable to hide.
  grep -v 'fm-two.sh' "$doc" > "$doc.cut" && mv "$doc.cut" "$doc"
  run_check "$CHECK" --root "$repo"
  assert_contains "$RUN_OUT" "bin/fm-two.sh has no row" \
    "the control does not fail the check, so nothing below is measuring its loss"
  expect_code 1 "$RUN_CODE" "the control was not refused"

  # git owns what is in this repository and what is ignored. A query that cannot
  # answer must not be read as an empty bin/. The stub answers rev-parse so the
  # probe reaches the listing itself rather than stopping at the repository gate,
  # which is a different channel reported in different words.
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case $arg in
    rev-parse) exit 0 ;;
    ls-files) exit 3 ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/git"
  RUN_CODE=0
  RUN_OUT=$(PATH="$fakebin:$PATH" "$CHECK" --root "$repo" 2>&1) || RUN_CODE=$?
  assert_never_silently_green "a git that cannot list bin/"
  expect_code 1 "$RUN_CODE" "a git that cannot list bin/ was not refused"
  assert_contains "$RUN_OUT" "could not list" \
    "a failed listing was not named as one"
  assert_not_contains "$RUN_OUT" "not a git repository" \
    "a failed listing was reported as an absent repository, which is a different channel"
  probed=$((probed + 1))

  # A listing that answers with a path the check cannot place under bin/ is a
  # record it cannot parse, and skipping one would put a file outside the check.
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case $arg in
    rev-parse) exit 0 ;;
    ls-files) printf 'elsewhere/fm-nine.sh\0'; exit 0 ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/git"
  RUN_CODE=0
  RUN_OUT=$(PATH="$fakebin:$PATH" "$CHECK" --root "$repo" 2>&1) || RUN_CODE=$?
  assert_never_silently_green "a listing naming a path outside bin/"
  assert_contains "$RUN_OUT" "cannot place under bin/" \
    "a record the check could not place was not named as one"
  probed=$((probed + 1))

  # The same shape one step further in: a query that answers with nothing.
  # Unknown and zero are not the same value, and only one of them means no drift.
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/git"
  RUN_CODE=0
  RUN_OUT=$(PATH="$fakebin:$PATH" "$CHECK" --root "$repo" 2>&1) || RUN_CODE=$?
  assert_never_silently_green "a git that lists nothing under bin/"
  assert_contains "$RUN_OUT" "established no files under bin/" \
    "an inventory that was never established was not named as one"
  probed=$((probed + 1))
  rm -f "$fakebin/git"

  # The doc, absent. That is a real and ordinary answer to give, and it is still
  # not "no drift": there is no list left to be right.
  mv "$doc" "$doc.away"
  run_check "$CHECK" --root "$repo"
  assert_never_silently_green "an absent toolbelt reference"
  assert_contains "$RUN_OUT" "is absent" "an absent doc was not reported as absent"
  mv "$doc.away" "$doc"
  probed=$((probed + 1))

  # A directory in its place is present but not a list, and is not reachable
  # only by a permission bit, so it is probed as root too.
  mv "$doc" "$doc.away"
  mkdir "$doc"
  run_check "$CHECK" --root "$repo"
  assert_never_silently_green "a directory where the toolbelt reference belongs"
  rmdir "$doc"
  mv "$doc.away" "$doc"
  probed=$((probed + 1))

  # As is a symlink that resolves to nothing.
  mv "$doc" "$doc.away"
  ln -s /nonexistent/not-here "$doc"
  run_check "$CHECK" --root "$repo"
  assert_never_silently_green "a dangling symlink where the toolbelt reference belongs"
  rm -f "$doc"
  mv "$doc.away" "$doc"
  probed=$((probed + 1))

  # An empty doc is a file with no table, which is no measurement.
  cp "$doc" "$doc.away"
  : > "$doc"
  run_check "$CHECK" --root "$repo"
  assert_never_silently_green "an empty toolbelt reference"
  mv "$doc.away" "$doc"
  probed=$((probed + 1))

  # root defeats every permission bit, so the forms that depend on one are
  # skipped there rather than passing vacuously.
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$doc"
    run_check "$CHECK" --root "$repo"
    assert_never_silently_green "an unreadable toolbelt reference"
    assert_contains "$RUN_OUT" "present but unreadable" \
      "an unreadable doc was reported as something other than unreadable"
    assert_not_contains "$RUN_OUT" "is absent" \
      "an unreadable doc was reported as absent, which is a different answer"
    chmod 644 "$doc"
    probed=$((probed + 1))

    # One level up, where the invariant leaks: a docs/ that is present and
    # stat-able but not searchable makes every existence test inside it answer
    # no, so the file is not unreadable, it is invisible - and calling it absent
    # there would be a claim the check is in no position to make.
    chmod a-x "$repo/docs"
    run_check "$CHECK" --root "$repo"
    assert_never_silently_green "a docs directory that cannot be searched"
    assert_contains "$RUN_OUT" "could not be determined" \
      "an unsearchable parent was answered instead of reported as unanswerable"
    assert_not_contains "$RUN_OUT" "is absent" \
      "an invisible doc was reported as absent, which is a claim the check cannot make"
    chmod 755 "$repo/docs"
    probed=$((probed + 1))

    chmod a-x "$repo"
    run_check "$CHECK" --root "$repo"
    assert_never_silently_green "a repository root that cannot be searched"
    chmod 755 "$repo"
    probed=$((probed + 1))
  fi

  # A root that is not there at all.
  run_check "$CHECK" --root "$TMP_ROOT/nowhere-at-all"
  assert_never_silently_green "a root that does not exist"
  probed=$((probed + 1))

  # A root that exists but is no repository, so the inventory has no owner to ask.
  mkdir -p "$TMP_ROOT/not-a-repo/docs"
  write_matching_doc "$TMP_ROOT/not-a-repo" fm-one.sh
  run_check "$CHECK" --root "$TMP_ROOT/not-a-repo"
  assert_never_silently_green "a root that is not a git repository"
  assert_contains "$RUN_OUT" "not a git repository" \
    "a root with no repository was not named as one"
  probed=$((probed + 1))

  [ "$probed" -ge 8 ] || fail "only $probed input channels were probed"
  pass "an input channel that cannot be evaluated is refused out loud, never read as no drift ($probed forms)"
}

test_the_repository_list_is_a_bijection
test_an_exact_fixture_passes
test_a_deleted_row_turns_the_check_red
test_a_new_script_without_a_row_turns_the_check_red
test_a_row_naming_no_file_turns_the_check_red
test_a_script_whose_name_git_quotes_still_needs_a_row
test_a_bin_name_no_row_can_spell_is_refused
test_both_row_forms_are_read_and_a_misdirected_link_is_refused
test_an_unparseable_row_is_refused_not_skipped
test_a_table_that_cannot_be_located_is_refused
test_every_input_channel_made_unevaluable_still_refuses

echo "# all fm-scripts-inventory tests passed"
