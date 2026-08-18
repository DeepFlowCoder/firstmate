#!/usr/bin/env bash
# Convoke a panel of LLM judges on a decision, or collect their verdicts.
#
# Each judge is a scout crewmate (read-only, no code changes) that receives the
# SAME question and context; only the harness differs, so the comparison is fair.
# Verdicts land in data/<panel>-<judge>/report.md.
#
# Usage:
#   fm-panel.sh convocar <panel-id> --question "<text>" --judges <h1,h2,...> [--context "<text>"] [--repo <name>] [--effort <low|medium|high|xhigh>]
#   fm-panel.sh recoger <panel-id> [--timeout <seconds>]
#
# convocar scaffolds one scout brief per judge, fills the {TASK} placeholder
# with the shared question/context, and spawns each on its harness. It refuses
# to overwrite an existing judge task. recoger waits until every judge appended
# a done: line to its status file (or the timeout elapses), then prints each
# verdict's one-line conclusion and report path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="$FM_HOME/data"
STATE="$FM_HOME/state"
PROJECTS="$FM_HOME/projects"

DEFAULT_REPO="finanzas-control"
DEFAULT_EFFORT="high"
DEFAULT_TIMEOUT="1800"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "error: $*" >&2; exit 1; }

# fill_brief <brief-path> <question> <context>
# Replaces the {TASK} line of a scaffolded brief with the shared judge prompt.
fill_brief() {
  local brief=$1 question=$2 context=$3 body
  body=$(mktemp)
  {
    printf '%s\n' 'Eres un juez en un panel de decisiones. Emite un veredicto razonado sobre la decisión planteada. No busques en internet; razona desde el criterio y sus consecuencias. Sé concreto.'
    printf '\n## La decisión\n%s\n' "$question"
    printf '\n## Contexto\n%s\n' "$context"
    printf '\n## Tu tarea\n'
    printf '%s\n' '1. Da tu veredicto: apruebas, rechazas, o apruebas con condiciones.'
    printf '%s\n' '2. Qué huecos, casos límite o ambigüedades ves.'
    printf '%s\n' '3. Qué precisarías o cambiarías.'
    printf '%s\n' 'El reporte ES tu veredicto: escríbelo completo en el archivo del Definition of done.'
  } > "$body"
  awk -v body="$body" '
    /\{TASK\}/ { while ((getline line < body) > 0) print line; close(body); next }
    { print }
  ' "$brief" > "$brief.new"
  mv "$brief.new" "$brief"
  rm -f "$body"
}

# split_judges <h1,h2,...> -> prints one harness per line
split_judges() {
  printf '%s\n' "$1" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
}

convocar() {
  local panel=$1 question=$2 context=$3 repo=$4 effort=$5 judges=$6
  local project_dir task_id brief judge
  project_dir="$PROJECTS/$repo"
  [ -d "$project_dir" ] || die "project clone not found: $project_dir"
  for judge in $(split_judges "$judges"); do
    task_id="$panel-$judge"
    brief="$DATA/$task_id/brief.md"
    [ ! -e "$brief" ] || die "judge task already exists: $task_id (refusing to overwrite)"
    "$SCRIPT_DIR/fm-brief.sh" "$task_id" "$repo" --scout >/dev/null
    fill_brief "$brief" "$question" "$context"
    "$SCRIPT_DIR/fm-spawn.sh" "$task_id" "$project_dir" --scout --harness "$judge" --effort "$effort"
  done
  echo "panel '$panel' convocado: $(split_judges "$judges" | paste -sd, -)"
}

recoger() {
  local panel=$1 timeout=$2 judge task_id verdict pending deadline
  local -a judge_list
  mapfile -t judge_list < <(for f in "$STATE"/"$panel"-*.status; do
    [ -e "$f" ] || continue
    basename "$f" .status | sed "s/^$panel-//"
  done)
  [ "${#judge_list[@]}" -gt 0 ] || die "no judges found for panel '$panel'"
  deadline=$(( $(date +%s) + timeout ))
  pending=1
  while [ "$pending" -ne 0 ] && [ "$(date +%s)" -lt "$deadline" ]; do
    pending=0
    for judge in "${judge_list[@]}"; do
      task_id="$panel-$judge"
      grep -q '^done:' "$STATE/$task_id.status" 2>/dev/null || pending=1
    done
    [ "$pending" -ne 0 ] && sleep 5
  done
  for judge in "${judge_list[@]}"; do
    task_id="$panel-$judge"
    verdict=$(grep '^done:' "$STATE/$task_id.status" 2>/dev/null | tail -1 || true)
    echo "=== $judge ==="
    if [ -n "$verdict" ]; then
      echo "$verdict"
      echo "  report: $DATA/$task_id/report.md"
    else
      echo "(sin veredicto aún; timeout)"
    fi
  done
}

subcommand=${1:-}
case "$subcommand" in
  -h|--help) usage; exit 0 ;;
  convocar)
    shift
    panel=${1:?usage: fm-panel.sh convocar <panel-id> --question ... --judges ...}
    shift
    question=""
    judges=""
    context=""
    repo="$DEFAULT_REPO"
    effort="$DEFAULT_EFFORT"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --question) question=${2:?--question requires a value}; shift 2 ;;
        --judges) judges=${2:?--judges requires a value}; shift 2 ;;
        --context) context=${2:?--context requires a value}; shift 2 ;;
        --repo) repo=${2:?--repo requires a value}; shift 2 ;;
        --effort) effort=${2:?--effort requires a value}; shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    [ -n "$question" ] || die "--question is required"
    [ -n "$judges" ] || die "--judges is required"
    convocar "$panel" "$question" "${context:-sin contexto adicional}" "$repo" "$effort" "$judges"
    ;;
  recoger)
    shift
    panel=${1:?usage: fm-panel.sh recoger <panel-id> [--timeout <secs>]}
    shift
    timeout="$DEFAULT_TIMEOUT"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --timeout) timeout=${2:?--timeout requires a value}; shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    recoger "$panel" "$timeout"
    ;;
  *) usage; exit 1 ;;
esac
