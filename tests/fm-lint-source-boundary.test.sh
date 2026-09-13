#!/usr/bin/env bash
# The coverage invariant behind the null-source lint directive.
#
# Bounding source analysis at an imported module is only safe because that
# module is itself a canonical root of the same lint run, so it is analysed in
# full at its own root. Nothing in ShellCheck enforces that: the directive also
# suppresses SC1091, so an import that resolves to a file outside the canonical
# set, or to no file at all, is analysed nowhere and the lane still exits 0
# with no diagnostic.
#
# This test is that enforcement. It discovers the bounded imports by scanning
# for the directive rather than from a list, so a root bounded in future is
# covered the day it is written, and it asks bin/fm-lint.sh itself which files
# are canonical rather than restating the globs.
#
# EDITING THIS FILE: restating here any rule bin/fm-lint.sh already owns - which
# directories are canonical, what counts as a lint root - makes this test fail
# on a legitimate change to that rule. It has happened twice. Derive it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

# Assembled rather than written whole so this file does not match its own scan,
# which would otherwise report its mentions of the directive as unbounded ones.
DIRECTIVE='# shellcheck source='/dev/null

# Repo-anchored directory variables used by bounded imports, as the location
# they denote: the containing script's own directory, or the repo root. A
# target led by anything else cannot be resolved by reading the file.
fm_resolve_dir_var() {  # <var> <containing-file>
  case "$1" in
    SCRIPT_DIR|FM_BACKEND_LIB_DIR|_FM_TASK_INBOX_LIB_DIR|FM_LEASE_LIB_DIR)
      printf '%s' "$(dirname "$2")"
      ;;
    ROOT|HERDR_TEST_SAFETY_DIR) printf '.' ;;
    *) return 1 ;;
  esac
}

test_bounded_imports_stay_inside_the_canonical_set() {
  local roots_list total=0 checked=0 other=0
  # The canonical set, from the consumer that defines it. CI=true selects the
  # full set rather than the branch's changed subset, which is what the
  # boundary invariant is about.
  roots_list=$(CI=true fm_run_timed 60 "$ROOT/bin/fm-lint.sh" --list-files) \
    || fail "bin/fm-lint.sh --list-files did not report the canonical set"
  [ -n "$roots_list" ] || fail "bin/fm-lint.sh --list-files reported an empty canonical set"

  local file line next target var rest dir resolved
  while IFS= read -r file; do
    while IFS= read -r line; do
      total=$((total + 1))
      next=$(sed -n "$((line + 1))p" "$file")

      # A directive that does not bound an import is a hole in a new place,
      # not something to pass over.
      case "$next" in
        *'. "'*) : ;;
        *) fail "$file:$line: $DIRECTIVE is not followed by a source statement: ${next:-<end of file>}" ;;
      esac

      target=${next#*'. "'}
      target=${target%%'"'*}

      case "$target" in
        '$'*'/'*)
          var=${target#'$'}
          var=${var%%/*}
          rest=${target#*/}
          ;;
        *) var=; rest= ;;
      esac

      if [ -n "$var" ] && dir=$(fm_resolve_dir_var "$var" "$file"); then
        resolved=${dir#./}
        [ -z "$resolved" ] || [ "$resolved" = "." ] && resolved=$rest || resolved="$resolved/$rest"
        # Only a shell module can be a lint root, so only a shell module can be
        # left unanalysed. Sourcing a data file bounds nothing and is not a
        # coverage hole, however its directory was spelled.
        case "$resolved" in
          *.sh)
            [ -f "$ROOT/$resolved" ] \
              || fail "$file:$((line + 1)): bounded import resolves to a missing file: $target -> $resolved"
            printf '%s\n' "$roots_list" | grep -qxF "$resolved" \
              || fail "$file:$((line + 1)): bounded import is analysed nowhere - $resolved is not a canonical lint root: $target"
            checked=$((checked + 1))
            ;;
          *) other=$((other + 1)) ;;
        esac
      else
        # Not repo-anchored. A data path is legitimate, but something that
        # names a shell module through an unknown directory variable is the
        # same silent hole this test exists to close.
        case "$target" in
          */*.sh)
            fail "$file:$((line + 1)): bounded import names a shell module through an unresolvable directory: $target" ;;
        esac
        other=$((other + 1))
      fi
    done < <(grep -Fn "$DIRECTIVE" "$file" | cut -d: -f1)
  done < <(grep -Frl "$DIRECTIVE" "$ROOT/bin" "$ROOT/tests" | sed "s|^$ROOT/||" | LC_ALL=C sort)

  [ "$total" -gt 0 ] || fail "found no $DIRECTIVE directives to check; the scan is not finding them"
  [ "$((checked + other))" -eq "$total" ] \
    || fail "classified $((checked + other)) of $total directives; some were skipped unseen"

  pass "every resolvable bounded shell module is a canonical lint root ($checked of $total; $other non-module paths)"
}

test_bounded_imports_stay_inside_the_canonical_set

printf '# fm-test-complete %s\n' "$(basename "${BASH_SOURCE[0]}")"
