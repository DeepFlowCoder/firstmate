#!/usr/bin/env bash
# Convoke a panel of LLM judges on a decision or on a change, and collect their
# verdicts as one decision instead of a pile of reports.
#
# Each judge is a scout crewmate (read-only, no code changes) that receives the
# SAME subject and context; only the harness differs, so the comparison is fair.
# Verdicts land in data/<panel>-<judge>/report.md.
#
# Usage:
#   fm-panel.sh convocar <panel-id> --judges <h1,h2,...> <subject> [options]
#   fm-panel.sh recoger <panel-id> [--timeout <seconds>]
#
# <subject> is exactly one of:
#   --question "<text>"    judge a prose decision
#   --diff <branch>        judge a change: <branch> against the project's default branch
#   --pr <url-or-number>   judge a change: that PR's head against the same base
#
# options:
#   --context "<text>"         shared background, handed to every judge
#   --criteria "<text>"        acceptance criteria the change is judged against
#   --criteria-from <task-id>  take them from data/<task-id>/brief.md's "# Task" section
#   --repo <name>              project clone under projects/ (default: finanzas-control)
#   --effort <low|medium|high|xhigh>
#   --max-diff-bytes <n>       refuse a diff bigger than this (default: 200000)
#   --timeout <seconds>        recoger only: how long to wait for every verdict
#
# Where acceptance criteria come from, in order: --criteria, then --criteria-from
# <task-id>, then inferred from an fm/<task> branch name (that convention only;
# no other branch name is read as a task id). If you NAME a source that cannot be
# read, convocar refuses before spending a single judgement, saying which flag,
# id and path failed. If you name none and none can be inferred, the panel is
# convoked anyway with no criteria, and says so twice: to every judge in its
# prompt, and to you in recoger's output, so verdicts reached without criteria
# are never mistaken for verdicts measured against them.
#
# convocar scaffolds one scout brief per judge, fills it with the shared
# subject, and spawns each on its harness. It refuses to overwrite an existing
# judge task. recoger waits until every judge appended a done: line, then prints
# where the judges AGREE, where they SPLIT, and each dissenter's objection.
# It exits non-zero when the panel is incomplete, so a timeout never reads as a
# finished collection.
#
# A panel costs one full judgement per judge. It is for expensive,
# hard-to-reverse decisions, not for routine changes: a delivery's own
# validation already reviews, tests and documents with one reviewer, and the
# panel buys provider DISAGREEMENT on top of that, not more review. Nothing
# invokes this script automatically, and nothing should.
#
# ---
# Design notes, not printed by --help.
#
# One code path. --question, --diff and --pr differ only in how the "subject"
# block of the shared judge prompt is built; scaffolding, filling, spawning,
# waiting and classifying are identical afterwards. The fair-comparison property
# (same bytes to every judge, only the harness differs) is the whole point of the
# tool, so it is guaranteed in exactly one place rather than re-guaranteed in a
# second branch that can drift.
#
# The diff is materialized ONCE into data/<panel>/subject.diff and every judge is
# pointed at that file. Judges do not each run their own git command: two judges
# reading a branch that moved mid-panel would silently be judging different
# changes. Passing a path rather than inlining the diff also keeps the launch
# prompt small and lets each judge page through a large change with its own file
# tools.
#
# Size is refused, never truncated. A silently shortened diff produces confident
# verdicts about code the judge never saw, which is worse than no panel at all.
# The 200000-byte default is about 50k tokens per judge; a change past that
# should be narrowed, or the ceiling raised deliberately with the N-times cost in
# view.
#
# --pr resolves through the CLONE's own origin (refs/pull/<n>/head), not through
# a forge API, and --diff needs no remote at all. Judging a change therefore never
# assumes a remote exists: local-only projects use --diff, which is the primary
# path, and --pr refuses with that pointer rather than failing obscurely. The
# fetch writes only an additive private ref under refs/fm-panel/, never a branch,
# HEAD, index or working tree, and the ref is removed on every way out of the
# resolution - the captured diff and every refusal after the fetch alike - so a
# failed convocation never costs the operator a ref to clean up by hand.
#
# --criteria-from is an ASSERTION that the change has a task; an fm/<task> branch
# name is only an INFERENCE. So a --criteria-from that reads no criteria refuses
# before any judge is dispatched, rather than telling N paid judges the change
# has no task behind it, while an inferred id that resolves to nothing falls
# through to the announced no-criteria path like any other ad-hoc change.
#
# Inference applies ONLY to a branch named fm/<task>, because that convention is
# what makes the branch name a task id at all. For any other branch nothing is
# inferred: reading data/<branch>/brief.md for an arbitrary name would hand every
# paid judge an unrelated task's criteria on nothing more than a name collision.
#
# That draws the line between the two states, which never share a path or a
# message. A source we were ASKED to use but cannot read is refused, because
# proceeding would spend the whole panel on a question nobody asked. Having
# legitimately NOTHING to use is not an error: the ad-hoc change is the case
# --diff exists for, so it is judged and the absence is disclosed twice - in the
# judge prompt, and again in recoger, since an unstated absence is how a reader
# assumes criteria existed.
#
# Judges must open their report with a VEREDICTO: line so verdicts can be
# counted, and EXACTLY ONE line of the report may carry that marker. Two such
# lines are two readings that cannot be told apart, so both are refused rather
# than resolved by position: taking the first would let a judge that quotes the
# format contract before its own verdict be counted as approving. For the same
# reason the brief describes the marker instead of printing an example of it, so
# no instruction the judge is handed can be mistaken for the judge's answer.
# A report that cannot be counted is never guessed into agreement - a fabricated
# consensus is the one output this tool must not produce - and it is reported
# under the bucket that says WHICH way it failed: no marker line, more than one,
# or one whose value is not a verdict. Collapsing those into a single "unreadable"
# would send the operator hunting for a missing line that is in fact duplicated
# or misspelled.
#
# THE RULE BEHIND ALL OF THAT: this tool never reports agreement it cannot prove.
# It refuses on criteria it was asked to use but cannot read, marks a verdict it
# cannot parse as unclassified instead of counting it, discloses missing criteria
# to both the judges and the reader, and refuses a duplicate judge - because a
# panel that overstates its own consensus is worth less than no panel at all.
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
DEFAULT_MAX_DIFF_BYTES="200000"

# Verdict buckets, in the order recoger prints them. The four trailing buckets are
# not verdicts: they are the distinct ways a judge can fail to deliver one, kept
# apart so the operator is told which failure to go fix.
VERDICTS=(aprobar condicional rechazar sin-marca voto-doble voto-ilegible sin-veredicto)

usage() {
  awk 'NR > 1 && /^# ---$/ { exit } NR > 1 && /^#/ { sub(/^# ?/, ""); print }' "$0"
}

die() { echo "error: $*" >&2; exit 1; }

# lower <text>: ASCII-lowercased, under LC_ALL=C so the folding is byte-identical
# everywhere rather than locale-dependent.
# shellcheck disable=SC2018,SC2019  # ASCII-only folding is the intent
lower() { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z'; }

# --- subject resolution -----------------------------------------------------

# default_branch <dir>: the project's default branch, remote-tracking first so a
# pooled clone stranded on a feature branch still resolves the real default.
default_branch() {
  local dir=$1 ref name branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    # A bare name only resolves through refs/heads/, so a stranded clone that has
    # the remote-tracking ref and no local branch would get a name that does not
    # resolve - the very case this branch exists to cover. Hand back the
    # remote-tracking ref itself there.
    name=${ref#origin/}
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$name"; then
      printf '%s\n' "$name"
    else
      printf '%s\n' "$ref"
    fi
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# pr_number <url-or-number>: the PR number, or non-zero when the target is not a
# PR reference at all.
pr_number() {
  local target=$1 n
  case "$target" in
    *"/pull/"*) n=${target##*/pull/}; n=${n%%[!0-9]*} ;;
    [0-9]*) n=${target%%[!0-9]*} ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# github_slug <url>: owner/repo from a GitHub URL, empty when it is not one.
github_slug() {
  local url=$1 rest
  case "$url" in
    *github.com[/:]*) rest=${url#*github.com} ; rest=${rest#[/:]} ;;
    *) return 0 ;;
  esac
  rest=${rest%%/pull/*}
  rest=${rest%/}
  rest=${rest%.git}
  case "$rest" in
    */*) printf '%s\n' "$rest" ;;
  esac
}

# brief_task_section <brief>: the "# Task" section of a scaffolded brief, which
# is where a firstmate task records what the change must achieve. Non-zero when
# the file has no such section or it is empty.
brief_task_section() {
  local brief=$1 body
  [ -f "$brief" ] || return 1
  body=$(awk '
    /^# Task[[:space:]]*$/ { inside = 1; next }
    inside && /^# / { exit }
    inside { print }
  ' "$brief")
  body=$(printf '%s\n' "$body" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
  [ -n "$body" ] || return 1
  printf '%s\n' "$body"
}

# --- judge prompt -----------------------------------------------------------

# report_format_contract: the machine-countable part of every judge prompt.
# recoger can only report a split it can read, so this text is the contract that
# makes N independent reports comparable.
#
# The markers are DESCRIBED, never shown as example lines. recoger counts the
# marker lines of a report, so an example printed here would come back quoted
# inside a judge's answer and be counted as a second vote. No line this function
# emits may match the patterns verdict_of and objections_of read.
report_format_contract() {
  printf '%s\n' '## Formato obligatorio del reporte'
  printf '%s\n' 'La PRIMERA línea de tu reporte debe ser la palabra VEREDICTO, dos puntos, y UNA SOLA de estas tres opciones:'
  printf '%s\n' '    aprobar'
  printf '%s\n' '    condicional'
  printf '%s\n' '    rechazar'
  printf '%s\n' 'Esa línea aparece EXACTAMENTE UNA VEZ en todo el reporte. No repitas este formato ni cites ejemplos de él: dos líneas de veredicto no se pueden distinguir, así que tu voto quedaría sin contar.'
  printf '%s\n' 'Si tu veredicto NO es aprobar, añade después una línea por cada objeción concreta. Cada una empieza por la palabra OBJECION, dos puntos, y una sola frase con el problema concreto, no una categoría.'
  printf '%s\n' 'Esa objeción es lo único que se muestra junto a tu voto, así que escríbela sola en pie.'
  printf '%s\n' 'Sin ese formato tu voto no se puede contar y el panel te reporta como sin clasificar.'
  printf '%s\n' 'Debajo del formato, escribe el razonamiento completo: el reporte ES tu veredicto.'
}

# build_prompt <out-file> <subject-block-file> <context>
# Assembles the shared judge prompt. Every judge gets these exact bytes.
build_prompt() {
  local out=$1 subject=$2 context=$3
  {
    printf '%s\n' 'Eres un juez en un panel de decisiones. Emite un veredicto razonado y concreto. No busques en internet; razona desde el criterio, el código y sus consecuencias.'
    printf '%s\n' 'Los demás jueces reciben exactamente este mismo texto. Tu valor está en lo que tú ves y otro podría no ver, así que no te ablandes hacia el consenso.'
    printf '\n'
    cat "$subject"
    printf '\n## Contexto\n%s\n' "$context"
    printf '\n## Tu tarea\n'
    printf '%s\n' '1. Da tu veredicto: apruebas, rechazas, o apruebas con condiciones.'
    printf '%s\n' '2. Qué huecos, casos límite o ambigüedades ves.'
    printf '%s\n' '3. Qué precisarías o cambiarías.'
    printf '\n'
    report_format_contract
  } > "$out"
}

# fill_brief <brief-path> <prompt-file>: replace the scaffold's {TASK} line.
fill_brief() {
  local brief=$1 prompt=$2
  awk -v body="$prompt" '
    /\{TASK\}/ { while ((getline line < body) > 0) print line; close(body); next }
    { print }
  ' "$brief" > "$brief.new"
  mv "$brief.new" "$brief"
}

# split_judges <h1,h2,...> -> prints one harness per line
split_judges() {
  printf '%s\n' "$1" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
}

# drop_panel_refs <project-dir>: delete every private ref this run added under
# refs/fm-panel/. Registered as an EXIT trap by resolve_change_subject, which
# runs in a command substitution, so it fires on every way out of that subshell
# - including a die() before the diff is captured - and the operator's clone is
# always left with the ref space it had.
drop_panel_refs() {
  local dir=$1 ref
  for ref in "${FM_PANEL_REFS[@]:-}"; do
    [ -n "$ref" ] || continue
    git -C "$dir" update-ref -d "$ref" >/dev/null 2>&1 || true
  done
}

# --- convocar ---------------------------------------------------------------

# resolve_change_subject <panel-dir> <project-dir> <repo> <kind> <target> <max-bytes>
# Materializes data/<panel>/subject.diff and echoes "<base>|<head-label>|<shortstat>|<task-hint>".
# Refuses rather than truncating, and refuses an empty change.
resolve_change_subject() {
  local panel_dir=$1 project_dir=$2 repo=$3 kind=$4 target=$5 max_bytes=$6
  local base head_ref head_label task_hint n slug origin size shortstat
  local origin_slug

  FM_PANEL_REFS=()
  # The path travels in a variable, never interpolated into the trap body: a
  # clone path containing a quote would otherwise make the body unparseable, so
  # the handler would silently never run and the ref would survive.
  FM_PANEL_PROJECT_DIR=$project_dir
  trap 'drop_panel_refs "$FM_PANEL_PROJECT_DIR"' EXIT

  git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1 ||
    die "project clone is not a git repository: $project_dir"
  base=$(default_branch "$project_dir") ||
    die "cannot determine the default branch of '$repo'; expected origin/HEAD, main, or master"

  if [ "$kind" = pr ]; then
    n=$(pr_number "$target") ||
      die "--pr expects a PR URL or number (got: $target)"
    origin=$(git -C "$project_dir" remote get-url origin 2>/dev/null) ||
      die "project '$repo' has no 'origin' remote, so a PR cannot describe its changes; judge the local branch instead with --diff <branch>"
    # Cross-check owner/repo only when BOTH sides are GitHub, so a PR URL can
    # never quietly resolve against a different repository's clone. Both sides
    # are normalized to owner/repo and compared for EQUALITY: a substring test
    # would let a PR of firstmate resolve against a clone of firstmate-docs. A
    # non-GitHub origin has no slug to compare, and the fetch below is the check
    # there. GitHub owner/repo names are case-insensitive, and github.com serves
    # the same PR under either casing, so the comparison folds case too - it is
    # the same repository or it is not, and capitalization does not decide that.
    slug=$(github_slug "$target")
    case "$origin" in
      *github.com*)
        origin_slug=$(github_slug "$origin")
        if [ -n "$slug" ] && [ "$(lower "$slug")" != "$(lower "$origin_slug")" ]; then
          die "PR $target names $slug but '$repo' points at $origin; refusing to judge a different repository's change"
        fi
        ;;
    esac
    git -C "$project_dir" fetch --quiet origin \
      "+refs/pull/$n/head:refs/fm-panel/pull/$n/head" 2>/dev/null ||
      die "cannot fetch PR #$n from '$repo' origin; check the PR number and network access"
    FM_PANEL_REFS+=("refs/fm-panel/pull/$n/head")
    if git -C "$project_dir" fetch --quiet origin \
      "+refs/heads/$base:refs/fm-panel/base/$base" 2>/dev/null; then
      FM_PANEL_REFS+=("refs/fm-panel/base/$base")
      base="refs/fm-panel/base/$base"
    fi
    head_ref="refs/fm-panel/pull/$n/head"
    head_label="PR #$n"
    # refs/pull/<n>/head carries no branch name, so a PR has no task to infer
    # from. --criteria-from names it explicitly when the change has one.
    task_hint=""
  else
    git -C "$project_dir" rev-parse --verify --quiet "$target^{commit}" >/dev/null ||
      die "branch '$target' does not exist in '$repo'"
    head_ref=$target
    head_label="rama $target"
    # Only the fm/<task> convention makes a branch name a task id. Any other
    # name is left with no hint at all rather than looked up as if it were one.
    case "$target" in
      fm/*) task_hint=${target#fm/} ;;
      *) task_hint="" ;;
    esac
  fi

  git -C "$project_dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
    die "base '$base' does not resolve in '$repo'"

  mkdir -p "$panel_dir"
  if ! git -C "$project_dir" diff "$base...$head_ref" -- > "$panel_dir/subject.diff"; then
    rm -f "$panel_dir/subject.diff"
    die "cannot diff ${base#refs/fm-panel/base/}...$head_label in '$repo'"
  fi
  shortstat=$(git -C "$project_dir" diff --shortstat "$base...$head_ref" -- | sed 's/^[[:space:]]*//')

  # The clone is left with its ref space exactly as found; the EXIT trap set at
  # the top does that on this path and on every refusal above. The fetched
  # objects stay, which is what any fetch leaves behind and is harmless.
  size=$(wc -c < "$panel_dir/subject.diff" | tr -d '[:space:]')
  if [ "$size" -eq 0 ]; then
    rm -f "$panel_dir/subject.diff"
    die "$head_label has no changes against ${base#refs/fm-panel/base/}; there is nothing for a panel to judge"
  fi
  if [ "$size" -gt "$max_bytes" ]; then
    rm -f "$panel_dir/subject.diff"
    die "the change is too big for a panel: $size bytes against a $max_bytes-byte ceiling ($shortstat).
  Every judge pays this in full, so it is refused rather than shortened - a judge that
  silently sees half a change still returns a confident verdict.
  Narrow the subject to the part that needs N opinions, or raise the ceiling
  deliberately with --max-diff-bytes <n>."
  fi

  printf '%s|%s|%s|%s\n' "${base#refs/fm-panel/base/}" "$head_label" "$shortstat" "$task_hint"
}

convocar() {
  local panel=$1 kind=$2 target=$3 context=$4 criteria=$5 criteria_from=$6
  local repo=$7 effort=$8 judges=$9 max_bytes=${10}
  local project_dir panel_dir task_id brief judge subject prompt seen
  local base head_label shortstat task_hint criteria_src resolved

  project_dir="$PROJECTS/$repo"
  [ -d "$project_dir" ] || die "project clone not found: $project_dir"
  panel_dir="$DATA/$panel"

  # A panel's subject is fixed at convocation. Re-convoking the same id with a
  # different roster would re-materialize the subject from a branch that may
  # have moved, so the late judge would be answering about different bytes than
  # the others - the exact comparison this tool exists to make honest.
  [ ! -e "$panel_dir/judges" ] ||
    die "panel '$panel' was already convoked (roster: $panel_dir/judges); its subject is fixed, so a judge added now would be judging different bytes. Convoke a new panel id instead."
  # --judges names a SET of distinct harnesses. Two entries of one harness are
  # not two opinions: they would share a task id, so one report would be read
  # twice and printed as a consensus of two - the fabricated agreement this tool
  # exists to prevent, at double the price.
  seen=""
  for judge in $(split_judges "$judges"); do
    case " $seen " in
      *" $judge "*)
        die "--judges nombra '$judge' más de una vez, y un panel compara el MISMO cambio en harnesses DISTINTOS.
  Dos entradas del mismo harness no dan un segundo punto de vista: dan un solo veredicto
  cobrado dos veces y contado como si dos jueces coincidieran.
  Nombra cada harness una sola vez."
        ;;
    esac
    seen="$seen $judge"
    [ ! -e "$DATA/$panel-$judge/brief.md" ] ||
      die "judge task already exists: $panel-$judge (refusing to overwrite)"
  done

  subject=$(mktemp)
  prompt=$(mktemp)
  # convocar runs once per invocation, so an EXIT trap reaps the scratch prompt
  # on every path out, including a die() from the subject resolution below. The
  # paths travel in a variable for the same reason the ref cleanup does: an
  # interpolated body would be unparseable for a path carrying a quote.
  FM_PANEL_SCRATCH=("$subject" "$prompt")
  trap 'rm -f "${FM_PANEL_SCRATCH[@]}"' EXIT

  criteria_src=""
  if [ "$kind" = question ]; then
    mkdir -p "$panel_dir"
    {
      printf '## La decisión\n%s\n' "$target"
    } > "$subject"
    printf 'panel %s: pregunta en prosa\n\npregunta:\n%s\n' "$panel" "$target" > "$panel_dir/subject.md"
  else
    resolved=$(resolve_change_subject "$panel_dir" "$project_dir" "$repo" "$kind" "$target" "$max_bytes")
    IFS='|' read -r base head_label shortstat task_hint <<< "$resolved"

    # Naming a task ASSERTS the change has one, so an id that reads no criteria
    # refuses here, before a single judge is dispatched: we cannot deliver the
    # criteria that were asked for. Having none to deliver is a different state
    # and never refuses - an id merely INFERRED from an fm/<task> branch, or no
    # source at all, falls through to the no-criteria path, which is announced
    # rather than hidden.
    if [ -n "$criteria" ]; then
      criteria_src="--criteria"
    elif [ -n "$criteria_from" ]; then
      criteria=$(brief_task_section "$DATA/$criteria_from/brief.md") || {
        rm -f "$panel_dir/subject.diff"
        rmdir "$panel_dir" 2>/dev/null || true
        die "--criteria-from '$criteria_from' no entrega criterios: $DATA/$criteria_from/brief.md no existe o no tiene una sección '# Task' con contenido.
  Dijiste que este cambio tiene una tarea detrás, así que el panel se niega antes de
  gastar un veredicto por juez en criterios que no son los que pediste.
  Corrige el id, pasa los criterios con --criteria, o quita --criteria-from si el
  cambio de verdad no tiene tarea."
      }
      criteria_src="$DATA/$criteria_from/brief.md"
    elif [ -n "$task_hint" ]; then
      if criteria=$(brief_task_section "$DATA/$task_hint/brief.md"); then
        criteria_src="$DATA/$task_hint/brief.md"
      else
        criteria=""
      fi
    else
      criteria=""
    fi

    {
      printf '## El cambio\n'
      printf 'Proyecto: %s\n' "$repo"
      printf 'Sujeto: %s\n' "$head_label"
      printf 'Base de comparación: %s\n' "$base"
      printf 'Resumen: %s\n' "${shortstat:-sin resumen}"
      printf 'Diff completo (léelo entero antes de opinar): %s\n' "$panel_dir/subject.diff"
      printf '\n## Criterios de aceptación\n'
      if [ -n "$criteria" ]; then
        printf '%s\n' "$criteria"
      else
        printf '%s\n' 'NO HAY CRITERIOS REGISTRADOS para este cambio: no tiene una tarea detrás.'
        printf '%s\n' 'Júzgalo contra su propia intención declarada (mensajes de commit, descripción del PR, el código mismo) y contra lo que el proyecto ya promete.'
        printf '%s\n' 'Que falten criterios es en sí mismo un hallazgo: dilo en tu reporte si te impide juzgar algo.'
      fi
    } > "$subject"

    {
      printf 'panel %s: %s de %s\n' "$panel" "$head_label" "$repo"
      printf '\nbase: %s\n' "$base"
      printf 'resumen: %s\n' "${shortstat:-sin resumen}"
      printf 'diff: %s\n' "$panel_dir/subject.diff"
      printf 'criterios: %s\n' "${criteria_src:-NINGUNO (cambio sin tarea registrada)}"
    } > "$panel_dir/subject.md"
  fi

  build_prompt "$prompt" "$subject" "$context"

  split_judges "$judges" > "$panel_dir/judges"
  echo "panel '$panel': $(split_judges "$judges" | paste -sd, -)"
  echo "  sujeto: $(sed -n '1p' "$panel_dir/subject.md")"
  if [ "$kind" != question ]; then
    echo "  diff: $(wc -c < "$panel_dir/subject.diff" | tr -d '[:space:]') bytes  ($shortstat)"
    if [ -z "$criteria" ]; then
      echo "  AVISO: sin criterios de aceptación registrados; los jueces juzgan contra la intención declarada del cambio."
    else
      echo "  criterios: $criteria_src"
    fi
  fi
  echo "  coste: $(split_judges "$judges" | wc -l | tr -d '[:space:]') veredictos de pago, uno por juez."

  for judge in $(split_judges "$judges"); do
    task_id="$panel-$judge"
    brief="$DATA/$task_id/brief.md"
    "$SCRIPT_DIR/fm-brief.sh" "$task_id" "$repo" --scout >/dev/null
    fill_brief "$brief" "$prompt"
    "$SCRIPT_DIR/fm-spawn.sh" "$task_id" "$project_dir" --scout --harness "$judge" --effort "$effort"
  done
  echo "panel '$panel' convocado."
}

# --- recoger ----------------------------------------------------------------

# verdict_of <report>: one of VERDICTS. Never guesses, and names the failure it
# actually found rather than one collapsed "unreadable": no report at all, no
# marker line, more than one marker line, or a marker line that is not a verdict
# are four different things to go fix.
verdict_of() {
  local report=$1 pattern line token count
  pattern='^[[:space:]]*[-*#[:space:]]*VEREDICTO[[:space:]]*:'
  if [ ! -f "$report" ]; then
    printf '%s\n' sin-veredicto
    return 0
  fi
  # Exactly one marker line is countable. None means the judge never voted; two
  # or more are readings that cannot be told apart, and resolving them by
  # position would pick a winner the report never declared.
  count=$(grep -icE "$pattern" "$report" 2>/dev/null || true)
  if [ "${count:-0}" -eq 0 ]; then
    printf '%s\n' sin-marca
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    printf '%s\n' voto-doble
    return 0
  fi
  line=$(grep -m1 -iE "$pattern" "$report")
  # ASCII-only on purpose, under LC_ALL=C so the classification is byte-identical
  # everywhere: the three contract tokens are ASCII, and folding any other byte
  # (an accent, a markdown bullet, a stray emoji) to a separator is exactly what
  # keeps "VEREDICTO: **aprobar**." and "veredicto:  aprobar" reading the same
  # while anything genuinely off-contract still falls through to voto-ilegible.
  # shellcheck disable=SC2018,SC2019  # accent-folding is the intent, not an oversight
  token=$(printf '%s' "${line#*:}" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z' ' ' | awk '{print $1}')
  case "$token" in
    aprobar | condicional | rechazar) printf '%s\n' "$token" ;;
    *) printf '%s\n' voto-ilegible ;;
  esac
}

# objections_of <report>: the judge's concrete objection lines, one per line.
objections_of() {
  local report=$1
  [ -f "$report" ] || return 0
  grep -iE '^[[:space:]]*[-*#[:space:]]*OBJECI[^:]*:' "$report" 2>/dev/null |
    sed -e 's/^[^:]*://' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    sed '/^$/d' || true
}

# panel_roster <panel>: the judges convocar recorded, falling back to the status
# files of a panel convoked before the roster existed.
panel_roster() {
  local panel=$1 f
  if [ -s "$DATA/$panel/judges" ]; then
    sed '/^[[:space:]]*$/d' "$DATA/$panel/judges"
    return 0
  fi
  for f in "$STATE/$panel"-*.status; do
    [ -e "$f" ] || continue
    basename "$f" .status | sed "s/^$panel-//"
  done
}

# band <label>: a fixed-width labelled separator, so the eye finds the sections
# of a verdict without reading them.
band() {
  local line="--- $1 "
  while [ "${#line}" -lt 60 ]; do line="$line-"; done
  printf '  %s\n' "$line"
}

recoger() {
  local panel=$1 timeout=$2
  local judge task_id pending deadline verdict distinct headline missing
  local seen_reports report
  local -a judge_list=() verdicts=()

  # One report is one judgement, whatever the roster says. Two entries resolving
  # to the same report.md would have that single verdict counted twice and
  # printed as agreement between two judges, so the roster is taken as a set of
  # distinct reports. convocar already refuses a repeated harness; this is the
  # same guarantee at the counting end, where a collision from any other source
  # would arrive.
  seen_reports=""
  while IFS= read -r judge; do
    [ -n "$judge" ] || continue
    report="$DATA/$panel-$judge/report.md"
    case "$seen_reports" in
      *"|$report|"*) continue ;;
    esac
    seen_reports="$seen_reports|$report|"
    judge_list+=("$judge")
  done < <(panel_roster "$panel")
  [ "${#judge_list[@]}" -gt 0 ] || die "no judges found for panel '$panel'"

  deadline=$(( $(date +%s) + timeout ))
  pending=1
  while [ "$pending" -ne 0 ] && [ "$(date +%s)" -lt "$deadline" ]; do
    pending=0
    for judge in "${judge_list[@]}"; do
      grep -q '^done:' "$STATE/$panel-$judge.status" 2>/dev/null || pending=1
    done
    [ "$pending" -ne 0 ] && sleep 5
  done

  for judge in "${judge_list[@]}"; do
    verdicts+=("$(verdict_of "$DATA/$panel-$judge/report.md")")
  done

  # "They disagree" and "we cannot tell" are different answers, and collapsing
  # them would either invent a split out of a judge that never answered or hide
  # a real one behind a formatting failure. So the headline is read from the
  # COUNTABLE verdicts alone, and whatever could not be counted is stated
  # separately - and makes the collection exit non-zero either way.
  local -a countable=()
  missing=0
  for verdict in "${verdicts[@]}"; do
    case "$verdict" in
      sin-veredicto | sin-marca | voto-doble | voto-ilegible) missing=$((missing + 1)) ;;
      *) countable+=("$verdict") ;;
    esac
  done
  if [ "${#countable[@]}" -eq 0 ]; then
    distinct=0
    headline="SIN VEREDICTOS LEGIBLES"
  else
    distinct=$(printf '%s\n' "${countable[@]}" | sort -u | wc -l | tr -d '[:space:]')
    if [ "$distinct" -gt 1 ]; then
      headline="VEREDICTO DIVIDIDO"
    elif [ "$missing" -gt 0 ]; then
      # Agreement among a subset is not unanimity, and must not read as it.
      headline="ACUERDO PARCIAL: ${countable[0]}"
    else
      headline="UNÁNIME: ${countable[0]}"
    fi
  fi
  if [ "$missing" -gt 0 ]; then
    headline="$headline  ·  INCOMPLETO: $missing sin contar"
  fi

  echo
  printf '  %s\n' '============================================================'
  printf '   PANEL %s  ·  %s jueces  ·  %s\n' "$panel" "${#judge_list[@]}" "$headline"
  printf '  %s\n' '============================================================'
  if [ -f "$DATA/$panel/subject.md" ]; then
    printf '   sujeto: %s\n' "$(sed -n "1s/^panel $panel: //p" "$DATA/$panel/subject.md")"
    # convocar recorded which criteria these judges were given. An absence that
    # is not stated is read as criteria that existed, so the reader is told here
    # too, next to the headline, and not only in the prompt the judges saw.
    case "$(sed -n 's/^criterios: //p' "$DATA/$panel/subject.md")" in
      NINGUNO*)
        printf '   %s\n' 'SIN CRITERIOS: este cambio no tenía criterios de aceptación registrados.'
        printf '   %s\n' 'Cada juez opinó contra la intención declarada del cambio, no contra un criterio acordado:'
        printf '   %s\n' 'no leas estos veredictos como "cumple lo pactado".'
        ;;
    esac
  fi
  echo

  # One row per verdict that got a vote, weighted by a bar so the shape of the
  # panel reads before the words do. The bar column is padded by COUNT rather
  # than by printf width: the block is three bytes, and a byte-counted width
  # would leave the names column ragged.
  local bucket i names count bar pad
  for bucket in "${VERDICTS[@]}"; do
    names=""
    count=0
    bar=""
    for i in "${!judge_list[@]}"; do
      if [ "${verdicts[$i]}" = "$bucket" ]; then
        names="${names:+$names, }${judge_list[$i]}"
        count=$((count + 1))
        bar="${bar}█"
      fi
    done
    if [ "$count" -gt 0 ]; then
      pad=""
      while [ "${#pad}" -lt $((6 - count)) ]; do pad="$pad "; done
      printf '   %-14s %s%s %s\n' "$bucket" "$bar" "$pad" "$names"
    fi
  done
  echo

  if [ "$distinct" -gt 1 ]; then
    band 'LA GRIETA: donde los jueces NO coinciden'
    printf '   %s\n' 'Esto es lo único que un solo juez no te podía dar. Léelo antes que nada.'
  elif [ "$distinct" -eq 1 ] && [ "$missing" -eq 0 ]; then
    band 'SIN GRIETA'
    printf '   %s\n' 'Los jueces coinciden. Un panel unánime no enseña nada nuevo: el valor'
    printf '   %s\n' 'estaba en el desacuerdo, y no lo hubo. Trátalo como una sola opinión.'
  elif [ "$distinct" -eq 1 ]; then
    band 'GRIETA NO DESCARTADA'
    printf '   %s\n' 'Los votos que llegaron coinciden, pero faltan votos: el desacuerdo que'
    printf '   %s\n' 'justificaba pagar el panel todavía podría estar en lo que no llegó.'
  else
    band 'NADA QUE CONTAR'
    printf '   %s\n' 'Ningún juez dejó un veredicto legible; no hay acuerdo ni desacuerdo que leer.'
  fi
  if [ "$missing" -gt 0 ]; then
    printf '   %s\n' "Faltan $missing de ${#judge_list[@]} votos, así que esta lectura es provisional."
  fi
  echo

  local objections note
  for i in "${!judge_list[@]}"; do
    judge=${judge_list[$i]}
    verdict=${verdicts[$i]}
    objections=$(objections_of "$DATA/$panel-$judge/report.md")
    case "$verdict" in
      aprobar) [ -n "$objections" ] || continue ;;
      sin-veredicto)
        printf '   %s · %s\n' "$judge" "$verdict"
        printf '     %s\n' 'no entregó reporte dentro del plazo'
        continue
        ;;
      sin-marca | voto-doble | voto-ilegible)
        # Each of these says what to go fix; only the last is the judge writing
        # something unreadable. Naming the wrong one sends the operator hunting
        # for a missing line that is really duplicated, or the reverse.
        case "$verdict" in
          sin-marca) note='entregó reporte pero sin ninguna línea VEREDICTO:, así que no llegó a votar' ;;
          voto-doble) note='entregó más de una línea VEREDICTO:, así que votó varias veces y ninguna lectura se puede elegir' ;;
          *) note='su única línea VEREDICTO: no dice aprobar, condicional ni rechazar, así que no se puede leer' ;;
        esac
        printf '   %s · %s\n' "$judge" "$verdict"
        printf '     %s; su voto no se cuenta\n' "$note"
        # An objection is not a vote. A judge that botched only its verdict line
        # still saw something, and hiding what it said would throw away the
        # signal the panel was paid for. It stays out of the count above.
        if [ -n "$objections" ]; then
          printf '     %s\n' 'objeciones que sí dejó (no cuentan como voto):'
          printf '%s\n' "$objections" | sed 's/^/     · /'
        fi
        printf '     reporte: %s\n' "$DATA/$panel-$judge/report.md"
        continue
        ;;
    esac
    printf '   %s · %s\n' "$judge" "$verdict"
    if [ -n "$objections" ]; then
      printf '%s\n' "$objections" | sed 's/^/     · /'
    else
      printf '     %s\n' '(sin objeción concreta declarada)'
    fi
  done
  echo

  band 'reportes completos'
  for judge in "${judge_list[@]}"; do
    task_id="$panel-$judge"
    printf '   %-12s %s\n' "$judge" "$DATA/$task_id/report.md"
  done
  echo

  [ "$missing" -eq 0 ] || return 1
  return 0
}

# --- argument handling ------------------------------------------------------

# set_subject <kind> <target>: record the one subject flag, refusing a second.
# Two subjects would mean two different panels sharing one roster.
set_subject() {
  [ -z "$kind" ] || die "--question, --diff and --pr are alternatives; pick one subject (already have --$kind)"
  kind=$1
  target=$2
}

subcommand=${1:-}
case "$subcommand" in
  -h | --help)
    usage
    exit 0
    ;;
  convocar)
    shift
    panel=${1:?usage: fm-panel.sh convocar <panel-id> --judges ... (--question|--diff|--pr) ...}
    shift
    kind=""
    target=""
    judges=""
    context=""
    criteria=""
    criteria_from=""
    repo="$DEFAULT_REPO"
    effort="$DEFAULT_EFFORT"
    max_bytes="$DEFAULT_MAX_DIFF_BYTES"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --question) set_subject question "${2:?--question requires a value}"; shift 2 ;;
        --diff) set_subject diff "${2:?--diff requires a value}"; shift 2 ;;
        --pr) set_subject pr "${2:?--pr requires a value}"; shift 2 ;;
        --judges) judges=${2:?--judges requires a value}; shift 2 ;;
        --context) context=${2:?--context requires a value}; shift 2 ;;
        --criteria) criteria=${2:?--criteria requires a value}; shift 2 ;;
        --criteria-from) criteria_from=${2:?--criteria-from requires a value}; shift 2 ;;
        --repo) repo=${2:?--repo requires a value}; shift 2 ;;
        --effort) effort=${2:?--effort requires a value}; shift 2 ;;
        --max-diff-bytes) max_bytes=${2:?--max-diff-bytes requires a value}; shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    [ -n "$kind" ] || die "a subject is required: --question <text>, --diff <branch>, or --pr <url>"
    [ -n "$judges" ] || die "--judges is required"
    [ -z "$criteria_from" ] || [ "$kind" != question ] ||
      die "--criteria-from applies to a change (--diff/--pr), not to --question"
    [ -z "$criteria" ] || [ "$kind" != question ] ||
      die "--criteria applies to a change (--diff/--pr), not to --question"
    case "$max_bytes" in
      '' | *[!0-9]*) die "--max-diff-bytes requires a whole number of bytes (got: $max_bytes)" ;;
    esac
    [ "$max_bytes" -gt 0 ] || die "--max-diff-bytes must be greater than 0"
    convocar "$panel" "$kind" "$target" "${context:-sin contexto adicional}" \
      "$criteria" "$criteria_from" "$repo" "$effort" "$judges" "$max_bytes"
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
    case "$timeout" in
      '' | *[!0-9]*) die "--timeout requires a whole number of seconds (got: $timeout)" ;;
    esac
    recoger "$panel" "$timeout"
    ;;
  *)
    usage
    exit 1
    ;;
esac
