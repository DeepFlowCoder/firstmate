#!/usr/bin/env bash
# fm-lint-workflows.sh - owner of firstmate's GitHub workflow lint.
#
# Runs pinned actionlint on every .github/workflows/*.{yml,yaml} so a malformed
# workflow, including a self-broken ci.yml, fails in the local and no-mistakes
# lint lane before merge. A broken ci.yml cannot report its own breakage, so
# this check must not live only as a step inside that workflow. bin/fm-lint.sh
# invokes this owner on its default (no explicit-path) path, which CI and
# commands.lint both use.
#
# It also refuses an undeclared `continue-on-error`, because that key is how a
# job or step keeps running, keeps reporting, and stops gating - a workflow that
# has quietly stopped protecting anything looks from outside exactly like one
# that passed. A pipeline repairing itself during a 2026-09 billing outage wrote
# `continue-on-error: true` onto a CI job and nothing in the repo objected.
#
# PRESENCE IS THE FINDING, never the value, and that is the whole point rather
# than a shortcut. A check for the value `true` is bypassed by every other way
# of writing true: the quoted string, YAML 1.1's `yes` and `on`, and
# `${{ ... }}`, which no static reader can evaluate at all. So this asks only
# whether the key is there. `continue-on-error: false` is refused too: it is a
# no-op today and a one-word edit away from not being one, and an allow-list
# entry is the cheap way to say it is meant.
#
# Legitimate uses are named one by one in NON_GATING_ALLOWED below, as
# `<workflow file>:<job id>[:<step id, name, or #index>]`. An entry that names
# nothing in the workflows being linted is refused as well, so the list cannot
# outlive its reason. Adding a use means editing that list in the same change,
# which is the friction this guard exists to create.
#
# Requires ruby, for its stdlib YAML parser: the question is structural, and a
# text scan would answer it about any line of prose or shell that happens to
# spell the key.
#
# Usage:
#   fm-lint-workflows.sh                 lint workflows under this repo
#   fm-lint-workflows.sh --root <dir>    lint workflows under <dir>
#   fm-lint-workflows.sh <path>...       lint explicit workflow files
#   fm-lint-workflows.sh --required-version
#   fm-lint-workflows.sh --help
set -eu

REQUIRED_ACTIONLINT=1.7.12

# Every place in firstmate's workflows that is allowed to stop gating, and why.
#
# The three steps below are the no-mistakes gate's own control flow: each one is
# a verdict the next step reads through `steps.<id>.outcome`, and the job's last
# step is what turns those outcomes into the single pass or fail. Take
# continue-on-error off any of them and the gate stops at the first pass's
# failure instead of trying the ancestor bind.
NON_GATING_ALLOWED=(
  'no-mistakes-required.yml:check:head_bind'
  'no-mistakes-required.yml:check:delta'
  'no-mistakes-required.yml:check:ancestor_bind'
)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint-workflows.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_ACTIONLINT"
  exit 0
fi

fm_lint_workflows_usage() {
  sed -n '2,40{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'fm-lint-workflows.sh: --root requires a directory.\n' >&2
        exit 2
      }
      EXPLICIT_ROOT=$2
      shift 2
      ;;
    --root=*)
      EXPLICIT_ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      fm_lint_workflows_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-lint-workflows.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'fm-lint-workflows.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

collect_workflow_files() {
  local dir=$1
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f \
    | LC_ALL=C sort
}

FILES=()
if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    case "$path" in
      *.yml|*.yaml) ;;
      *)
        printf 'fm-lint-workflows.sh: not a workflow YAML file: %s\n' "$path" >&2
        exit 2
        ;;
    esac
    [ -f "$path" ] || {
      printf 'fm-lint-workflows.sh: workflow file not found: %s\n' "$path" >&2
      exit 2
    }
    FILES+=("$path")
  done
else
  workflow_dir="$ROOT/.github/workflows"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    FILES+=("$path")
  done < <(collect_workflow_files "$workflow_dir")
  if [ "${#FILES[@]}" -eq 0 ]; then
    printf 'fm-lint-workflows.sh: no GitHub workflow files found under %s\n' \
      "$workflow_dir" >&2
    exit 1
  fi
fi

if ! command -v actionlint >/dev/null 2>&1; then
  printf 'fm-lint-workflows.sh: actionlint not found; install actionlint %s with bin/fm-install-actionlint.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi
ACTIONLINT_BIN=$(command -v actionlint)
resolved=$("$ACTIONLINT_BIN" -version | awk 'NR==1 {print; exit}')
printf 'fm-lint-workflows.sh: actionlint %s (pinned %s)\n' "$resolved" "$REQUIRED_ACTIONLINT" >&2
if [ "$resolved" != "$REQUIRED_ACTIONLINT" ]; then
  printf 'fm-lint-workflows.sh: actionlint %s required for CI parity, found %s. Install %s with bin/fm-install-actionlint.sh <destination-directory>.\n' \
    "$REQUIRED_ACTIONLINT" "$resolved" "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi

# fm-lint.sh owns ShellCheck of the canonical shell set. Disable actionlint's
# extra shell and Python subprocess linters so this gate is the named workflow
# linter, not a second shell lint of `run:` blocks.
set +e
"$ACTIONLINT_BIN" -no-color -shellcheck= -pyflakes= -- "${FILES[@]}"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

if ! command -v ruby >/dev/null 2>&1; then
  printf 'fm-lint-workflows.sh: ruby not found, so the undeclared continue-on-error check cannot read these workflows as YAML. Install ruby (its stdlib YAML parser is all this needs) and re-run.\n' >&2
  exit 1
fi

# Single quotes are required: the body is a Ruby program whose ${{ ... }}
# patterns and interpolations must reach Ruby unexpanded by the shell. The
# allow-list reaches it through the environment, never through this source.
NON_GATING_ALLOWED_LIST=$(printf '%s\n' "${NON_GATING_ALLOWED[@]}")
export NON_GATING_ALLOWED_LIST
# shellcheck disable=SC2016
ruby -ryaml -e '
allowed = (ENV["NON_GATING_ALLOWED_LIST"] || "").split("\n").map(&:strip).reject(&:empty?)
seen = []
findings = []

def step_label(step, index)
  id = step["id"].to_s.strip
  return id unless id.empty?
  name = step["name"].to_s.strip
  return name unless name.empty?
  "##{index}"
end

linted = ARGV.map { |path| File.basename(path) }
ARGV.each do |path|
  file = File.basename(path)
  begin
    doc = YAML.load_file(path)
  rescue StandardError => e
    warn "fm-lint-workflows.sh: #{path}: cannot read as YAML for the continue-on-error check: #{e.message}"
    exit 2
  end
  jobs = doc.is_a?(Hash) ? doc["jobs"] : nil
  next unless jobs.is_a?(Hash)
  jobs.each do |job_id, job|
    next unless job.is_a?(Hash)
    if job.key?("continue-on-error")
      seen << "#{file}:#{job_id}"
    end
    steps = job["steps"]
    next unless steps.is_a?(Array)
    steps.each_with_index do |step, index|
      next unless step.is_a?(Hash)
      next unless step.key?("continue-on-error")
      seen << "#{file}:#{job_id}:#{step_label(step, index)}"
    end
  end
end

(seen - allowed).each do |location|
  findings << "#{location} sets continue-on-error, so it reports without gating. " \
              "If that is intended, add it to NON_GATING_ALLOWED in bin/fm-lint-workflows.sh with the reason."
end
allowed.each do |entry|
  next unless linted.include?(entry.split(":").first)
  next if seen.include?(entry)
  findings << "#{entry} is allowed to stop gating in NON_GATING_ALLOWED but no longer sets continue-on-error. " \
              "Drop it from bin/fm-lint-workflows.sh."
end

exit 0 if findings.empty?
findings.each { |f| warn "fm-lint-workflows.sh: #{f}" }
exit 1
' -- "${FILES[@]}"

printf 'fm-lint-workflows.sh: %s workflow files valid\n' "${#FILES[@]}"
exit 0
