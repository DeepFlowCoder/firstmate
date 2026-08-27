#!/usr/bin/env bash
# Behavior tests for the captain's decision board generator.
#
# The board exists because thirteen correctly registered captain decisions still
# went undecided for a week: the registry was never the bottleneck, the surface
# was. These tests pin the two halves of that fix separately, because only one of
# them is mechanical.
#
# What must be automatic: which decisions are open, in what order, with what
# evidence, wired to a form whose answer can close the hold.
# What must NOT be automatic: the recommendation, the options, and the warning
# that two decisions push on the same promise. A generator that invents those
# produces filler advice, so the refusal that stops a page from being served with
# them unwritten is itself a tested guarantee.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TABLERO="$ROOT/bin/fm-tablero.sh"
TMP_ROOT=$(fm_test_tmproot fm-tablero)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

axi() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

# A durable captain decision hold, in the shape bin/fm-decision-hold.sh writes.
seed_decision() {  # <home> <origin> <key> <title> <reason> [<repo>]
  local home=$1 origin=$2 key=$3 title=$4 reason=$5 repo=${6:-demo}
  local id="$origin-decision-$key"
  axi "$home" add "$id" --title "$title" --repo "$repo" --kind captain >/dev/null \
    || fail "fixture: could not create the decision task $id"
  axi "$home" update "$id" --body "Origin: $origin
Decision key: $key
State: awaiting captain decision." >/dev/null \
    || fail "fixture: could not record the origin and key on $id"
  # tasks-axi refuses a hold reason containing parentheses, so a fixture reason
  # carrying them fails here rather than silently producing an empty board.
  axi "$home" hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "fixture: could not hold $id with reason: $reason"
  printf '%s\n' "$id"
}

run_tablero() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TABLERO_NOW="${FM_TABLERO_NOW:-2026-09-10}" \
    "$TABLERO" "$@"
}

run_lavish() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_decisions() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# Replace the generated judgment holes of the Nth `## decision` block, and the
# page and warning holes, with written judgment. Nothing else in the draft moves,
# so what these tests exercise is the real generated scaffold.
fill_page_judgment() {  # <draft> <titulo> <bajada> <aviso>
  python3 - "$@" <<'PY'
import sys
draft, titulo, bajada, aviso = sys.argv[1:5]
s = open(draft).read()
out = []
for line in s.splitlines(True):
    if line.startswith('titulo: TODO(firstmate):'):
        out.append('titulo: %s\n' % titulo)
    elif line.startswith('bajada: TODO(firstmate):'):
        out.append('bajada: %s\n' % bajada)
    else:
        out.append(line)
s = ''.join(out)
start = s.index('## aviso\n') + len('## aviso\n')
try:
    end = s.index('\n## decision ', start) + 1
except ValueError:
    end = len(s)
s = s[:start] + aviso + '\n' + s[end:]
open(draft, 'w').write(s)
PY
}

# No hole left that the refusal would actually count. Comment lines are skipped
# for the same reason the refusal skips them: the generated header explains the
# marker and can never be filled. Cases that mean to reach a rule BEYOND the hole
# refusal assert this first, so that rule cannot go quietly untested behind it.
assert_no_countable_hole() {  # <draft> <message>
  if grep -v '^#' "$1" | grep -qF 'TODO(firstmate):'; then
    fail "$2"
  fi
}

# Move one decision's recorded `(since <date>)` in the backlog, whatever date
# tasks-axi stamped on it. Anchoring on the literal date the fixture happened to
# be created on would make the backdating a silent no-op on every other day,
# which is exactly how an ordering test stops being able to fail.
backdate_since() {  # <home> <task-id> <YYYY-MM-DD>
  python3 - "$1/data/backlog.md" "$2" "$3" <<'PY'
import re, sys
path, task_id, when = sys.argv[1:4]
lines = open(path).read().splitlines(True)
hits = 0
for i, line in enumerate(lines):
    if (' %s - ' % task_id) not in line:
        continue
    line, n = re.subn(r'\(since \d{4}-\d{2}-\d{2}\)', '(since %s)' % when, line)
    lines[i] = line
    hits += n
if hits != 1:
    sys.exit("fixture: backdating %s replaced %d dates, expected 1" % (task_id, hits))
open(path, 'w').write(''.join(lines))
PY
}

# Fill one decision's judgment blocks. `--options` takes `valor|prose` pairs; the
# FIRST becomes the single `### reco`, the rest become `### opcion` blocks. Pass
# zero options to leave the decision with a recommendation and nothing else.
fill_decision_judgment() {  # <draft> <hold-id> <porque> [<valor|prose>...]
  python3 - "$@" <<'PY'
import sys
draft, hold_id, porque = sys.argv[1:4]
options = sys.argv[4:]
s = open(draft).read()
head = '## decision %s\n' % hold_id
start = s.index(head)
try:
    end = s.index('\n## decision ', start) + 1
except ValueError:
    end = len(s)
block = s[start:end]
keep = block[:block.index('### porque\n')]
new = keep + '### porque\n' + porque + '\n'
for i, opt in enumerate(options):
    valor, prose = opt.split('|', 1)
    new += '### %s\nvalor: %s\n%s\n' % ('reco' if i == 0 else 'opcion', valor, prose)
open(draft, 'w').write(s[:start] + new + s[end:])
PY
}

# --- the mechanical half ----------------------------------------------------

# The filter is hold_kind, never kind. On the real night most decisions were
# captain-kind decision holds, but one was an ordinary task carrying a captain
# hold, and a `--kind captain` filter drops exactly that one silently.
test_draft_finds_every_captain_hold_whatever_its_kind() {
  local home draft out
  home=$(make_home kinds)
  seed_decision "$home" inv-uno corte "Bajar el corte o cambiar la agregacion" \
    "Medido: 0/60 en tres clases." >/dev/null
  axi "$home" add fm-rio-arriba --title "Como entregar los defectos rio arriba" \
    --repo firstmate >/dev/null
  axi "$home" hold fm-rio-arriba --reason "Publica codigo bajo su identidad." \
    --kind captain >/dev/null
  # A non-captain hold is somebody else's wait, not the captain's decision.
  axi "$home" add ext-espera --title "Esperando al proveedor" --repo demo >/dev/null
  axi "$home" hold ext-espera --reason "El proveedor responde el lunes." \
    --kind external >/dev/null

  out=$(run_tablero "$home" draft) || fail "draft failed on a home with open decisions"
  draft="$home/.lavish/tablero.draft.md"
  assert_present "$draft" "draft wrote no file"
  assert_grep "## decision inv-uno-decision-corte" "$draft" \
    "the captain-kind decision hold was not carried onto the board"
  assert_grep "## decision fm-rio-arriba" "$draft" \
    "a captain hold on an ordinary task was dropped, which is the kind-vs-hold_kind bug"
  assert_no_grep "## decision ext-espera" "$draft" \
    "an external hold was presented to the captain as their decision"
  assert_contains "$out" "decisiones: 2" "draft miscounted the open decisions"
  # The evidence the captain needs to decide travels with the decision, verbatim.
  assert_grep "Medido: 0/60 en tres clases." "$draft" \
    "the hold's recorded evidence did not reach the board"
  # And the machine identity that lets an answer close it travels too.
  assert_grep "clave: corte" "$draft" "the decision key was not carried onto the board"
  assert_grep "origen: inv-uno" "$draft" "the decision origin was not carried onto the board"
  pass "the board finds every captain hold, filtered by hold_kind rather than kind"
}

# The ordering claim, stated as the objective states it: by what not deciding
# costs, NOT by date. The cheap decision here is deliberately the OLDER one, so a
# date sort and a cost sort disagree and only one of them can pass.
test_draft_orders_by_stopped_work_not_by_date() {
  local home draft old_pos new_pos
  local FM_TABLERO_NOW=2026-09-10
  home=$(make_home orden)
  seed_decision "$home" inv-viejo barato "La decision vieja que no para nada" \
    "Vieja y sin trabajo detenido detras." >/dev/null
  seed_decision "$home" inv-nuevo caro "La decision nueva que para trabajo" \
    "Nueva, y una tarea lista espera por ella." >/dev/null
  # Both dates are set here, not just one: the fixtures are stamped with whatever
  # today happens to be, so pinning only the old one would leave the two ages
  # equal and the date key with nothing to disagree about.
  backdate_since "$home" inv-viejo-decision-barato 2026-09-03 || fail "fixture: backdating failed"
  backdate_since "$home" inv-nuevo-decision-caro 2026-09-09 || fail "fixture: backdating failed"
  axi "$home" add ship-listo --title "El trabajo que espera" --repo demo >/dev/null
  axi "$home" block ship-listo --by inv-nuevo-decision-caro >/dev/null

  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  # The disagreement itself, asserted before the order is: the cheap decision is
  # genuinely the older one here, so a date sort and a cost sort cannot both pass.
  # Without this the whole test goes quietly vacuous the moment the ages tie.
  assert_grep "etiqueta: 7 dias esperando" "$draft" \
    "the cheap decision is not seven days old, so date order and cost order do not disagree"
  assert_grep "etiqueta: 1 dia esperando" "$draft" \
    "the costly decision is not the newer one, so date order and cost order do not disagree"
  new_pos=$(grep -n '^## decision inv-nuevo-decision-caro$' "$draft" | cut -d: -f1)
  old_pos=$(grep -n '^## decision inv-viejo-decision-barato$' "$draft" | cut -d: -f1)
  [ -n "$new_pos" ] && [ -n "$old_pos" ] || fail "both decisions must appear on the board"
  [ "$new_pos" -lt "$old_pos" ] || fail \
    "the board ordered by date: the decision with a task stopped behind it must come first"
  assert_grep "etiqueta: para 1 tarea(s)" "$draft" \
    "the stopped-work count that justifies the order was not shown to the captain"
  pass "the board orders by what not deciding costs, not by how old the decision is"
}

# The second ranking key, and the only one that reads outside the backlog: work
# parked on a decision outranks work that is merely waiting. Both decisions here
# tie on stopped work and on age, and the live one is deliberately the one the
# identity tiebreak would place LAST, so nothing but liveness can produce the
# expected order.
test_draft_ranks_parked_work_above_mere_waiting() {
  local home draft live_pos dead_pos
  local FM_TABLERO_NOW=2026-09-10
  home=$(make_home parada)
  seed_decision "$home" aaa-cerrada k "La de la investigacion terminada" \
    "Su investigacion ya cerro." >/dev/null
  seed_decision "$home" zzz-parada k2 "La de la investigacion parada" \
    "Su investigacion sigue detenida esperando esto." >/dev/null
  backdate_since "$home" aaa-cerrada-decision-k 2026-09-04 || fail "fixture: backdating failed"
  backdate_since "$home" zzz-parada-decision-k2 2026-09-04 || fail "fixture: backdating failed"
  fm_write_meta "$home/state/aaa-cerrada.meta" kind=scout repo=demo
  printf 'working: investigando\ndone: entregado el informe\n' > "$home/state/aaa-cerrada.status"
  fm_write_meta "$home/state/zzz-parada.meta" kind=scout repo=demo
  printf 'working: parada esperando la decision\n' > "$home/state/zzz-parada.status"

  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  # The ties the ranking must fall through before liveness can decide anything.
  assert_no_grep "etiqueta: para " "$draft" \
    "a decision has stopped work behind it, so the first ranking key is not tied"
  [ "$(grep -c '^etiqueta: 6 dias esperando$' "$draft")" -eq 2 ] || fail \
    "the two decisions are not the same age, so the ranking never reaches liveness"
  live_pos=$(grep -n '^## decision zzz-parada-decision-k2$' "$draft" | cut -d: -f1)
  dead_pos=$(grep -n '^## decision aaa-cerrada-decision-k$' "$draft" | cut -d: -f1)
  [ -n "$live_pos" ] && [ -n "$dead_pos" ] || fail "both decisions must appear on the board"
  [ "$live_pos" -lt "$dead_pos" ] || fail \
    "the board fell through to the identity tiebreak: a decision with work parked behind it must come first"
  pass "the board ranks a decision with work parked behind it above one merely waiting"
}

# The stopped-work count is a cheap token match over one listing, and the whole
# ordering rests on it. A plain substring search would credit a decision with
# every task blocked by a LONGER identity that merely starts the same way, which
# reorders the board with no signal that anything went wrong.
test_the_stopped_work_count_does_not_count_a_longer_identity() {
  local home draft
  home=$(make_home prefijo)
  seed_decision "$home" inv-uno corte "La del corte" "Evidencia del corte." >/dev/null
  seed_decision "$home" inv-uno corte-largo "La del corte largo" "Evidencia del largo." >/dev/null
  # Only the longer identity blocks anything.
  axi "$home" add ship-a --title "Trabajo A" --repo demo >/dev/null
  axi "$home" block ship-a --by inv-uno-decision-corte-largo >/dev/null
  axi "$home" add ship-b --title "Trabajo B" --repo demo >/dev/null
  axi "$home" block ship-b --by inv-uno-decision-corte-largo >/dev/null

  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  assert_grep "etiqueta: para 2 tarea(s)" "$draft" \
    "the decision that really has work stopped behind it was not credited with it"
  [ "$(grep -c '^etiqueta: para ' "$draft")" -eq 1 ] || fail \
    "a decision was credited with work stopped behind a longer identity sharing its prefix"
  pass "the stopped-work count credits only the decision whose identity actually blocks the work"
}

test_draft_refuses_to_overwrite_written_judgment() {
  local home draft rc out
  home=$(make_home clobber)
  seed_decision "$home" inv-uno corte "Una decision" "Su evidencia." >/dev/null
  run_tablero "$home" draft >/dev/null || fail "first draft failed"
  draft="$home/.lavish/tablero.draft.md"
  printf 'la recomendacion escrita a mano\n' >> "$draft"

  out=$(run_tablero "$home" draft 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a second draft silently replaced a draft that may hold written judgment"
  assert_contains "$out" "pass --force" "the refusal did not name its escape"
  assert_grep "la recomendacion escrita a mano" "$draft" "the written judgment was destroyed"
  run_tablero "$home" draft --force >/dev/null || fail "--force did not replace the draft"
  assert_no_grep "la recomendacion escrita a mano" "$draft" "--force did not replace the draft"
  pass "a regenerated draft cannot silently destroy judgment already written into it"
}

# --- the judgment half, which must stay manual ------------------------------

test_unfilled_judgment_refuses_and_serves_no_page() {
  local home draft rc out page
  home=$(make_home huecos)
  seed_decision "$home" inv-uno corte "Una decision" "Su evidencia." >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  page="$home/.lavish/tablero.html"

  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "check accepted a draft whose judgment was never written"
  assert_contains "$out" "unfilled TODO(firstmate):" "the refusal did not name the unwritten judgment"

  out=$(run_tablero "$home" render "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "render served a page whose recommendations were never written"
  assert_absent "$page" "render left a page behind after refusing"
  pass "a page with unwritten judgment is refused and never written to disk"
}

# The three holes are not equally easy to forget. The interaction warning has no
# per-decision home, so it is the one a hurried pass skips - and on the real
# night saying it out loud is what changed an answer.
test_each_judgment_hole_is_separately_required() {
  local home draft rc out
  home=$(make_home cada-hueco)
  seed_decision "$home" inv-uno corte "Una decision" "Su evidencia." >/dev/null

  # Everything written EXCEPT the interaction warning, which is DELETED rather
  # than left as its hole. Deleting the placeholder is what a hurried pass with
  # nothing to say actually does, and it leaves the hole refusal nothing to catch,
  # so the grammar's own rule is the only guard between that pass and a board that
  # never answers whether two decisions push on the same promise.
  run_tablero "$home" draft --force >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  fill_page_judgment "$draft" "Una decision suya" "Lleva una semana parada." ""
  fill_decision_judgment "$draft" inv-uno-decision-corte "Cuesta una tarea parada." \
    "Cambiar la agregacion|Cambiar la agregacion, que no toca ninguna cifra prometida." \
    "Bajar el corte|Bajar el corte. Barato hoy, indefendible manana."
  assert_no_countable_hole "$draft" \
    "this case must leave no hole at all, or the hole refusal masks the missing warning"
  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "check accepted a board with no answer on whether the decisions interact"
  assert_contains "$out" "interaction warning" "the refusal did not name the missing warning"

  # Everything written EXCEPT the recommendation: two plain options, no reco.
  run_tablero "$home" draft --force >/dev/null || fail "draft failed"
  fill_page_judgment "$draft" "Una decision suya" "Lleva una semana parada." ninguna
  python3 - "$draft" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index('### porque\n')
s = s[:i] + '''### porque
Cuesta una tarea parada.
### opcion
valor: Cambiar la agregacion
Cambiar la agregacion.
### opcion
valor: Bajar el corte
Bajar el corte.
'''
open(p, 'w').write(s)
PY
  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "check accepted a decision with options but no recommendation"
  assert_contains "$out" "exactly one" "the refusal did not name the missing recommendation"

  # A recommendation with nothing to choose between is not a decision surface.
  run_tablero "$home" draft --force >/dev/null || fail "draft failed"
  fill_page_judgment "$draft" "Una decision suya" "Lleva una semana parada." ninguna
  fill_decision_judgment "$draft" inv-uno-decision-corte "Cuesta una tarea parada." \
    "Cambiar la agregacion|La unica salida que no toca una cifra prometida."
  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "check accepted a decision offering the captain no real choice"
  assert_contains "$out" "at least two options" "the refusal did not name the missing choice"
  pass "the recommendation, a real choice, and the interaction warning are each required"
}

test_declaring_no_interaction_is_an_answer_not_a_hole() {
  local home draft page
  home=$(make_home ninguna)
  seed_decision "$home" inv-uno corte "Una decision" "Su evidencia." >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  fill_page_judgment "$draft" "Una decision suya" "Lleva una semana parada." ninguna
  fill_decision_judgment "$draft" inv-uno-decision-corte "Cuesta una tarea parada." \
    "Cambiar la agregacion|La unica salida que no toca una cifra prometida." \
    "Bajar el corte|Barato hoy, indefendible manana."
  run_tablero "$home" check "$draft" >/dev/null \
    || fail "declaring that nothing interacts was not accepted as an answer"
  # No --out here: the default page path is derived from the draft's own name, and
  # a wrong derivation would leave the captain with no page where it was promised.
  page="$home/.lavish/tablero.html"
  run_tablero "$home" render "$draft" >/dev/null || fail "render failed"
  assert_present "$page" "render did not write the page at its default derived path"
  assert_no_grep 'class="aviso"' "$page" \
    "declaring no interaction still painted an empty warning box at the top"
  pass "declaring that no decisions interact is a written answer, and paints no warning"
}

# --- the page, and the answer coming back -----------------------------------

# One filled board, then several independent claims about the page it produces.
build_full_board() {  # <home> -> echoes the page path
  local home=$1 draft page
  seed_decision "$home" inv-uno corte "Bajar el corte o cambiar la agregacion" \
    "Medido: 0/60 en tres clases. Tres salidas excluyentes." >/dev/null
  run_tablero "$home" draft >/dev/null || return 1
  draft="$home/.lavish/tablero.draft.md"
  page="$home/.lavish/tablero.html"
  fill_page_judgment "$draft" "Una decision suya" "Lleva una semana parada." \
    "Esta decision **empuja sobre la misma promesa** que la de cobertura."
  fill_decision_judgment "$draft" inv-uno-decision-corte \
    "Cuesta una tarea parada, y sube a dos esta semana." \
    "Cambiar la agregacion del Dc|**Cambiar la agregacion.** No toca ninguna cifra prometida." \
    "Bajar el nivel del corte 3|Bajar el corte. Barato hoy, indefendible en una auditoria."
  run_tablero "$home" render "$draft" --out "$page" >/dev/null || return 1
  printf '%s\n' "$page"
}

test_page_carries_the_recommendation_and_the_warning() {
  local home page
  home=$(make_home pagina)
  page=$(build_full_board "$home") || fail "could not build a fully written board"
  assert_grep 'class="aviso"' "$page" "the interaction warning did not reach the page"
  assert_grep "empuja sobre la misma promesa" "$page" "the warning text was lost"
  assert_grep '<span class="rec">mi reco</span>' "$page" \
    "the recommendation is not marked, so the captain cannot see which one it is"
  assert_grep "<strong>Cambiar la agregacion.</strong>" "$page" \
    "written emphasis did not render"
  assert_grep "Medido: 0/60 en tres clases." "$page" "the evidence did not reach the page"
  # Phone readability is the difference between dispatching twelve and none.
  assert_grep 'name="viewport"' "$page" "the page has no viewport, so a phone will zoom out"
  assert_grep "max-width:44rem" "$page" "the page is not the single narrow column a phone needs"
  assert_grep "prefers-color-scheme: dark" "$page" "the page has no dark rendering"
  pass "the page carries the recommendation, the warning, the evidence and a phone layout"
}

# Captain-facing prose and recorded evidence are arbitrary text. A hold reason
# that happens to contain markup must render as text the captain reads, never as
# markup the page executes.
test_page_escapes_recorded_evidence() {
  local home draft page
  home=$(make_home escapar)
  seed_decision "$home" inv-uno corte "Una decision" \
    'Medido con <script>alert 1</script> y a > b & c.' >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  page="$home/.lavish/tablero.html"
  fill_page_judgment "$draft" "Una decision suya" "Lleva una semana parada." ninguna
  fill_decision_judgment "$draft" inv-uno-decision-corte "Cuesta una tarea parada." \
    'Cambiar la agregacion|Cambiar la agregacion <b>ya</b>.' \
    "Bajar el corte|Bajar el corte."
  run_tablero "$home" render "$draft" --out "$page" >/dev/null || fail "render failed"
  assert_no_grep "<script>alert 1</script>" "$page" \
    "recorded evidence was rendered as live markup instead of as text"
  assert_grep "&lt;script&gt;alert 1&lt;/script&gt;" "$page" \
    "recorded evidence was not rendered as readable text"
  assert_grep "a &gt; b &amp; c." "$page" "escaping mangled ordinary punctuation"
  assert_no_grep "Cambiar la agregacion <b>ya</b>." "$page" \
    "written prose was rendered as live markup"
  pass "recorded evidence and written prose render as text, never as markup"
}

# The whole point of generating the page instead of hand-writing it: the form's
# payload is the shape the review adapter already reads, so the captain's answer
# closes its own hold with no hand translation. This drives the REAL adapter and
# the REAL keyed-answer intake, keyed by the page's own emitted values.
test_answer_from_the_generated_form_closes_its_hold() {
  local home page clave valor result sid show fed
  home=$(make_home ciclo)
  page=$(build_full_board "$home") || fail "could not build a fully written board"
  # The investigation that raised the decision, as the completion gate expects to
  # find it: a real task in this home whose report survives its teardown.
  fm_write_meta "$home/state/inv-uno.meta" kind=scout repo=demo
  mkdir -p "$home/data/inv-uno"
  printf 'Hallazgos de la investigacion.\n' > "$home/data/inv-uno/report.md"

  # Everything below is read out of the generated page, never restated here: if
  # the page stops emitting the adapter's shape, this test has nothing to feed.
  assert_grep "tag: 'choice'" "$page" \
    "the form does not queue the choice payload the review adapter reads"
  clave=$(sed -n 's/.*data-clave="\([^"]*\)".*/\1/p' "$page" | head -1)
  valor=$(sed -n 's/.*<input type="radio" name="op" value="\([^"]*\)".*/\1/p' "$page" | head -1)
  [ -n "$clave" ] && [ -n "$valor" ] || fail "the page emitted no keyed choice to answer"
  [ "$clave" = corte ] || fail "the form is keyed by '$clave', not by the hold's decision key"

  # The captured result, in the published response shape, carrying exactly the
  # key and the answer value this page emitted.
  sid=tablero-src
  mkdir -p "$home/state/procevent-inbox"
  result="$home/state/procevent-inbox/$sid.1.result"
  {
    printf 'session:\n  file: %s\n  status: feedback\n  session_ended: true\n' "$page"
    printf 'prompts[1]{uid,prompt,selector,tag,text}:\n'
    printf '  "2","%s -> %s\\n\\nContext data:\\n{\\n  \\"question\\": \\"%s\\",\\n  \\"answer\\": \\"%s\\"\\n}","form",choice,"%s: %s"\n' \
      "$clave" "$valor" "$clave" "$valor" "$clave" "$valor"
  } > "$result"

  fed=$(run_lavish "$home" answers "$result") \
    || fail "the review adapter could not read the generated form's answer"
  assert_contains "$fed" "$clave	$valor" \
    "the adapter did not read the page's own key and answer back out"

  # Bind the page to its origin the way the script's header prescribes, then feed
  # the adapter's keyed lines into the one intake that closes holds.
  run_decisions "$home" bind "$sid" inv-uno >/dev/null \
    || fail "could not bind the served page to its decision origin"
  printf '%s\n' "$fed" | run_decisions "$home" answers inv-uno --source "tablero $sid" \
    >/dev/null || fail "the keyed answer from the generated form did not close its hold"

  show=$(axi "$home" show inv-uno-decision-corte --full) || fail "the hold vanished"
  assert_contains "$show" "state: done" "the answered decision is still open"
  assert_contains "$show" "$valor" "the hold did not record the answer the captain actually chose"
  assert_contains "$show" "Resolution mode: answered" \
    "the closure was not recorded as an answer the captain gave"
  assert_contains "$show" "tablero $sid" "the durable decision lost where the answer came from"
  pass "an answer to the generated form closes its own hold with no hand translation"
}

# One card on the real night carried no form at all: a decision the captain had
# already answered with "wait for the correction", kept visible so he could see it
# was not lost. That card must not demand options it has no business asking for.
test_a_waiting_decision_renders_without_a_form() {
  local home draft page
  home=$(make_home espera)
  seed_decision "$home" inv-uno choque "El choque entre los dos cortes" \
    "El capitan ya dijo: esperar al resultado de la correccion." >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  page="$home/.lavish/tablero.html"
  fill_page_judgment "$draft" "Una decision suya" "Esta esperando a proposito." ninguna
  # Judgment moves the card out of the answerable group; nothing mechanical can.
  python3 - "$draft" <<'PYIN'
import sys
p = sys.argv[1]
s = open(p).read().replace('grupo: activa', 'grupo: espera')
open(p, 'w').write(s)
PYIN
  fill_decision_judgment "$draft" inv-uno-decision-choque \
    "Ya lo decidio: esperar. Sigue abierta a proposito, no por olvido."
  run_tablero "$home" check "$draft" >/dev/null \
    || fail "a decision the captain is deliberately waiting on was refused for having no options"
  run_tablero "$home" render "$draft" --out "$page" >/dev/null || fail "render failed"
  assert_grep "El choque entre los dos cortes" "$page" \
    "the waiting decision was dropped from the board instead of kept visible"
  assert_grep 'class="tarjeta espera"' "$page" "the waiting card is not marked as waiting"
  assert_no_grep "<form" "$page" "a decision the captain already answered was given a form to answer"
  assert_grep "no se perdio" "$page" "the waiting card does not say why it is still listed"
  pass "a decision the captain is deliberately waiting on renders without a form"
}

# The grammar treats a leading # as a comment. Inside written prose that would
# quietly delete a line of the recommendation, which is exactly the degradation
# this board exists to prevent, so it must refuse rather than drop it.
test_prose_that_would_be_swallowed_as_a_comment_refuses() {
  local home draft rc out
  home=$(make_home comentario)
  seed_decision "$home" inv-uno corte "Una decision" "Su evidencia." >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  fill_page_judgment "$draft" "Una decision suya" "Lleva una semana parada." ninguna
  fill_decision_judgment "$draft" inv-uno-decision-corte "Cuesta una tarea parada." \
    "Cambiar la agregacion|Cambiar la agregacion." "Bajar el corte|Bajar el corte."
  # A recommendation whose second line opens with a hash, as prose about a
  # numbered item easily does.
  python3 - "$draft" <<'PYIN'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('Cambiar la agregacion.\n', 'Cambiar la agregacion.\n#1 de las tres salidas medidas.\n', 1)
open(p, 'w').write(s)
PYIN
  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a written line was silently dropped from the recommendation"
  assert_contains "$out" "would be dropped as a comment" \
    "the refusal did not explain that written prose was being swallowed"
  pass "written prose that the grammar would swallow as a comment refuses instead"
}

# A board that spans several investigations cannot close every hold on its own: a
# binding names one origin. That limit must be stated where it is decided, not
# discovered later when half the answers turn out to still be open.
test_render_warns_when_a_page_spans_several_origins() {
  local home draft out
  home=$(make_home origenes)
  seed_decision "$home" inv-uno alcance "La del alcance" "Evidencia del alcance." >/dev/null
  seed_decision "$home" inv-dos interfaz "La de la interfaz" "Evidencia de la interfaz." >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  fill_page_judgment "$draft" "Dos decisiones" "Las dos llevan una semana." ninguna
  fill_decision_judgment "$draft" inv-uno-decision-alcance "Cuesta esto." \
    "Subir el alcance|Subir el alcance." "Dejarlo|Dejarlo."
  fill_decision_judgment "$draft" inv-dos-decision-interfaz "Cuesta esto otro." \
    "Ensayar la vuelta|Ensayar la vuelta." "Asumir el riesgo|Asumir el riesgo."

  out=$(run_tablero "$home" render "$draft") \
    || fail "render refused a legitimate board spanning two investigations"
  assert_contains "$out" "origin: inv-uno" "render did not name the origins the page carries"
  assert_contains "$out" "origin: inv-dos" "render did not name the origins the page carries"
  assert_contains "$out" "2 origenes" \
    "render stayed silent about a page whose answers cannot all close themselves"
  assert_contains "$out" "NO se cierran solas" "the warning did not say what will not happen"
  pass "render warns plainly when a board spans more origins than one binding covers"
}

# A captain hold on an ordinary task carries no origin, so no binding can reach
# it and its answer will never close itself. Saying nothing there is worse than
# saying nothing about several origins: the page would be served under the note
# that promises the opposite.
test_render_says_a_decision_with_no_origin_will_not_close_itself() {
  local home draft out
  home=$(make_home sin-origen)
  seed_decision "$home" inv-uno alcance "La del alcance" "Evidencia del alcance." >/dev/null
  axi "$home" add fm-rio-arriba --title "Como entregar los defectos rio arriba" \
    --repo firstmate >/dev/null
  axi "$home" hold fm-rio-arriba --reason "Publica codigo bajo su identidad." \
    --kind captain >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  fill_page_judgment "$draft" "Dos decisiones" "Las dos llevan una semana." ninguna
  fill_decision_judgment "$draft" inv-uno-decision-alcance "Cuesta esto." \
    "Subir el alcance|Subir el alcance." "Dejarlo|Dejarlo."
  fill_decision_judgment "$draft" fm-rio-arriba "Cuesta esto otro." \
    "Publicarlos|Publicarlos." "Guardarlos|Guardarlos."
  # The fixture only means something if one decision really came through with an
  # empty origin and the other with a real one.
  grep -q '^origen: *$' "$draft" || fail \
    "no decision reached the board without an origin, so this case tests nothing"
  assert_grep "origen: inv-uno" "$draft" \
    "no decision reached the board WITH an origin, so the kept promise is untested"

  out=$(run_tablero "$home" render "$draft") || fail "render refused a legitimate board"
  assert_contains "$out" "no traen origen registrado" \
    "render stayed silent about an answer that no binding can ever close"
  assert_contains "$out" "NO se cierran" "the warning did not say what will not happen"
  assert_not_contains "$out" "las respuestas cierran solas" \
    "render still promised that every answer on this page closes itself"

  # And the promise must survive where it is true, or the warning above would have
  # been bought by silencing the note everywhere.
  home=$(make_home con-origen)
  seed_decision "$home" inv-uno alcance "La del alcance" "Evidencia del alcance." >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  fill_page_judgment "$draft" "Una decision" "Lleva una semana." ninguna
  fill_decision_judgment "$draft" inv-uno-decision-alcance "Cuesta esto." \
    "Subir el alcance|Subir el alcance." "Dejarlo|Dejarlo."
  out=$(run_tablero "$home" render "$draft") || fail "render refused a legitimate board"
  assert_contains "$out" "las respuestas cierran solas" \
    "render no longer says that a bound single-origin page closes its own answers"
  pass "render says plainly which answers no binding can close, and still promises the ones it can"
}

# A bound origin closes `<origin>-decision-<clave>`, so the same clave under two
# origins is a page that could close the wrong captain decision.
test_page_refuses_one_key_under_two_origins() {
  local home draft rc out
  home=$(make_home colision)
  seed_decision "$home" inv-uno alcance "La primera" "Evidencia de la primera." >/dev/null
  seed_decision "$home" inv-dos alcance "La segunda" "Evidencia de la segunda." >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  fill_page_judgment "$draft" "Dos decisiones" "Las dos llevan una semana." ninguna
  fill_decision_judgment "$draft" inv-uno-decision-alcance "Cuesta esto." \
    "Subir el alcance|Subir el alcance." "Dejarlo|Dejarlo."
  fill_decision_judgment "$draft" inv-dos-decision-alcance "Cuesta esto otro." \
    "Subir el alcance|Subir el alcance." "Dejarlo|Dejarlo."

  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "the board accepted one decision key under two different origins"
  assert_contains "$out" "two origins" "the refusal did not name the collision"
  out=$(run_tablero "$home" render "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "render served a page that could close the wrong captain decision"
  pass "a page whose key could close the wrong hold is refused"
}

# An empty home is a healthy state, not a failure, and it must not produce a
# servable page that says nothing.
test_no_open_decisions_drafts_nothing_to_serve() {
  local home draft out rc
  home=$(make_home vacio)
  out=$(run_tablero "$home" draft) || fail "draft failed on a home with no open decisions"
  assert_contains "$out" "decisiones: 0" "an empty home reported decisions it does not have"
  draft="$home/.lavish/tablero.draft.md"
  assert_grep "No hay ninguna decision del capitan abierta" "$draft" \
    "the draft did not say plainly that there is nothing to serve"
  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "an empty board with its judgment unwritten was accepted as servable"
  # And once the page judgment IS written, so the hole refusal has nothing left to
  # catch: an empty board must still refuse, or the captain is served a page with
  # a title, a subtitle and no decisions on it.
  fill_page_judgment "$draft" "Una ronda vacia" "No hay nada que decidir hoy." ninguna
  assert_no_countable_hole "$draft" \
    "this case must leave no hole at all, or the hole refusal masks the empty-board refusal"
  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a board carrying no decisions at all was accepted as servable"
  assert_contains "$out" "no board to serve" "the refusal did not say the board is empty"
  pass "a home with no open decisions drafts nothing servable and says so"
}

# A recorded reason is arbitrary prose and may open with a hash. Carried verbatim
# that line stops being evidence and becomes grammar - a comment, or a structure
# line that silently splits the decision in two - and no written judgment can then
# make the draft servable. The generator must hand it back as a named hole with
# the text intact, not emit a draft that is already unusable.
test_evidence_that_would_read_as_grammar_becomes_a_hole() {
  local home draft rc out
  home=$(make_home gramatica)
  seed_decision "$home" inv-uno corte "Una decision" "## decision falsa-inyectada" >/dev/null
  run_tablero "$home" draft >/dev/null || fail "draft failed"
  draft="$home/.lavish/tablero.draft.md"
  # Anchored, so it must be a real grep: assert_no_grep is fixed-string and would
  # read the caret as a literal that can never match.
  if grep -q '^## decision falsa-inyectada' "$draft"; then
    fail "recorded evidence became a structure line and split the board into a phantom decision"
  fi
  assert_grep "## decision falsa-inyectada" "$draft" \
    "the recorded evidence was dropped instead of handed back to be rewritten"
  assert_grep "empieza con #" "$draft" "the draft did not say why the evidence needs rewriting"
  out=$(run_tablero "$home" check "$draft" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a draft whose evidence still needs rewriting was accepted"
  assert_contains "$out" "unfilled TODO(firstmate):" \
    "the refusal blamed something other than the evidence still waiting to be rewritten"
  pass "recorded evidence that would read as grammar comes back as a hole, text intact"
}

test_draft_finds_every_captain_hold_whatever_its_kind
test_draft_orders_by_stopped_work_not_by_date
test_draft_ranks_parked_work_above_mere_waiting
test_the_stopped_work_count_does_not_count_a_longer_identity
test_draft_refuses_to_overwrite_written_judgment
test_evidence_that_would_read_as_grammar_becomes_a_hole
test_unfilled_judgment_refuses_and_serves_no_page
test_each_judgment_hole_is_separately_required
test_declaring_no_interaction_is_an_answer_not_a_hole
test_page_carries_the_recommendation_and_the_warning
test_page_escapes_recorded_evidence
test_answer_from_the_generated_form_closes_its_hold
test_prose_that_would_be_swallowed_as_a_comment_refuses
test_render_warns_when_a_page_spans_several_origins
test_render_says_a_decision_with_no_origin_will_not_close_itself
test_a_waiting_decision_renders_without_a_form
test_page_refuses_one_key_under_two_origins
test_no_open_decisions_drafts_nothing_to_serve
