#!/usr/bin/env bash
# fm-tablero.sh - build the captain's decision board from the open captain holds.
#
# Thirteen captain decisions once sat correctly registered in the backlog and
# still none of them moved, because a registry is not a surface. A hand-built
# review page cleared twelve in minutes, and had to be hand-built twice in the
# same hour. This script is that page's scaffold, so the mechanical half stops
# being craft.
#
# Usage:
#   fm-tablero.sh draft [--out <path>] [--force]
#   fm-tablero.sh check <draft>
#   fm-tablero.sh render <draft> [--out <path>]
#
# THE SPLIT THIS SCRIPT EXISTS TO ENFORCE.
# Three things made that page work: the order, a recommendation with its reason
# on every decision, and a warning when two decisions push on the same promise.
# Only the first is mechanical. `draft` does the mechanical half completely - it
# finds every open captain hold in this FM_HOME, ranks them by what not deciding
# costs, carries their evidence over verbatim, and lays out the form and the
# wake-up hookup - and it writes a `TODO(firstmate):` hole everywhere judgment
# belongs. `check` and `render` refuse while any hole is unfilled.
#
# That refusal is the point. A generator that writes its own recommendations
# produces filler advice, and filler advice is worse than none because it trains
# the captain to skip the recommendation line. So this script never writes a
# recommendation, never writes an option, and never writes the interaction
# warning. It cannot: it has no way to know any of them.
#
# ORDER, and why it is not by date or by project.
# The rank is what not deciding costs, most expensive first:
#   1. how many backlog items are blocked by this decision (work already stopped)
#   2. whether the work that raised it is still live in this home (work parked)
#   3. how long it has been waiting
#   4. the hold identity, so equal cost still sorts the same way every run
# Date is the last real tiebreaker, never the primary key, and project never
# enters it. `render` emits decisions in the DRAFT's order, so firstmate may
# reorder the file when judgment disagrees with the rank.
#
# WHAT COMES BACK, and today's limit.
# Each form queues the canonical Lavish choice payload - `tag: 'choice'` with
# `data: { question: <decision key>, answer: <choice> }` - which is exactly what
# bin/fm-procevent-lavish.sh's `answers` command reads. Arm the page with that
# adapter and bind it with `bin/fm-decision-hold.sh bind`, and an answer closes
# its hold through the one keyed-answer intake with no hand translation:
#   bin/fm-tablero.sh render <draft> --out <page.html>
#   bin/fm-decision-hold.sh bind "$(bin/fm-procevent-lavish.sh source-id <page.html>)" <origin-id>
#   bin/fm-procevent-lavish.sh arm <page.html>
#   lavish-axi <page.html>
# A binding names ONE origin, and a board that spans several investigations
# carries decision keys from several origins. Keys outside the bound origin come
# back as `skipped:` from that intake and still need a close command by hand;
# `render` prints which origins a page carries so that is visible before serving
# it, and refuses a page where one decision key appears under two origins,
# because a bound origin could otherwise close the wrong hold.
#
# WHAT IT READS.
# `tasks-axi list --state held` in the active FM_HOME, filtered to the holds
# whose `hold_kind` is captain, then each one's own `tasks-axi show --full`
# record. `hold_kind` is the filter and `kind` is not: a captain-gated thread is
# often an ordinary task carrying a captain hold, and filtering on `kind`
# silently drops it. This script reads report prose, chat, and terminal output
# never; .agents/skills/decision-hold-lifecycle/SKILL.md owns what a decision is
# and bin/fm-decision-hold.sh owns every close path.
#
# The blocked-work count is a RANKING hint read from one `tasks-axi list
# --blocked` call. bin/fm-decision-hold.sh owns the authoritative answer to what
# a hold still blocks, confirmed per candidate, because there it gates a close.
# Here it only orders cards, so a cheap token match is the right cost.
#
# DRAFT GRAMMAR.
# Structure lines start with `##` or `###`. A line starting with a single `#` is
# a comment, so written prose must not begin a line with `#`; inside a written
# block that is a refusal rather than a silent drop, because quietly deleting a
# line of the recommendation is the degradation this whole board exists to stop.
# Everything else is a `field: value` line inside a block, or prose.
#
#   ## pagina          titulo:, bajada:
#   ## aviso           prose, or the single word `ninguna`
#   ## decision <hold-id>
#                      clave:, origen:, grupo: (activa|espera), titulo:,
#                      etiqueta: (repeatable), and these sub-blocks:
#     ### evidencia    verbatim hold reason, rendered as the evidence block
#     ### porque       why this one costs the captain now
#     ### reco         the recommendation; exactly one per `activa` decision
#     ### opcion       another real option; `activa` needs at least two total
#
# In `### reco` and `### opcion`, an optional first `valor:` line is the exact
# answer string sent back, and the remaining prose is what the captain reads.
# Without `valor:`, the prose is the answer. Prose supports `**bold**`, and a
# blank line starts a new paragraph. An `espera` decision renders as a no-form
# card and needs no options.
#
# Environment:
#   FM_TABLERO_NOW   YYYY-MM-DD treated as today, for deterministic runs
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tablero: %s\n' "$*" >&2
  exit 1
}

HOLE='TODO(firstmate):'
# Unit separator: the row delimiter for the ranking pass. See the printf below.
US=$(printf '\037')

TABLERO_TMP=
cleanup() { [ -z "$TABLERO_TMP" ] || rm -rf "$TABLERO_TMP"; }
trap cleanup EXIT

scratch() {
  [ -n "$TABLERO_TMP" ] || TABLERO_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-tablero.XXXXXX")
  printf '%s\n' "$TABLERO_TMP"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required to read the open decisions"
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required (see bin/fm-tasks-axi-lib.sh)"
}

today() {
  local now=${FM_TABLERO_NOW:-}
  if [ -n "$now" ]; then
    case "$now" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) printf '%s\n' "$now"; return 0 ;;
      *) fail "FM_TABLERO_NOW must be YYYY-MM-DD: $now" ;;
    esac
  fi
  date +%Y-%m-%d
}

# Whole days between two YYYY-MM-DD dates, floored at 0. perl rather than date
# arithmetic because BSD and GNU date disagree on every relative-date flag.
days_between() {  # <from> <to>
  perl -MTime::Local=timegm -e '
    my @d;
    for my $a (@ARGV) {
      my ($y, $m, $day) = $a =~ /\A(\d{4})-(\d{2})-(\d{2})\z/ or exit 1;
      push @d, timegm(0, 0, 12, $day, $m - 1, $y);
    }
    my $n = int(($d[1] - $d[0]) / 86400);
    print $n < 0 ? 0 : $n, "\n";
  ' "$1" "$2" 2>/dev/null || printf '0\n'
}

# One `key: value` field out of a `tasks-axi show --full` record. That record is a
# stable two-space-indented block, so the field name is matched anchored.
show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

# tasks-axi quotes any value that could contain a comma or newline and escapes
# the contents JSON-style. Unquote and unescape so evidence prose survives whole.
unquote() {  # <value>
  printf '%s' "$1" | perl -e '
    my $v = do { local $/; <STDIN> };
    if ($v =~ /\A"(.*)"\z/s) {
      $v = $1;
      $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "" : $1/ge;
    }
    print $v;
  '
}

# Held task identities. The listing frames rows as an indented block under a
# `tasks[N]{...}:` header whose first field is always an unquoted id.
held_ids() {
  tasks_axi list --state held 2>/dev/null | awk '
    /^tasks\[[0-9]+\]\{/ { in_rows = 1; next }
    in_rows && $0 !~ /^[[:space:]]/ { exit }
    in_rows {
      sub(/^[[:space:]]+/, "")
      id = $0
      sub(/,.*$/, "", id)
      if (id ~ /^[A-Za-z0-9._-]+$/) print id
    }
  '
}

# Ranking hint only: how many backlog items name <hold-id> in blocked_by, matched
# on comma or quote boundaries so a longer identity sharing a prefix does not
# count. bin/fm-decision-hold.sh owns the authoritative per-candidate answer.
count_blocked_by() {  # <listing> <hold-id>
  printf '%s\n' "$1" | awk -v id="$2" '
    index($0, id) == 0 { next }
    {
      line = $0
      gsub(/"/, ",", line)
      line = "," line ","
      if (index(line, "," id ",") > 0) n++
    }
    END { print n + 0 }
  '
}

# Whether the work that raised this decision is still live in this home. A parked
# investigation is real stopped work and outranks mere staleness.
origin_live() {  # <origin-id>
  local origin=$1 verb
  [ -n "$origin" ] || { printf '0\n'; return 0; }
  [ -f "$STATE/$origin.meta" ] || { printf '0\n'; return 0; }
  verb=$(status_line_verb "$(last_status_line "$STATE/$origin.status")")
  case "$verb" in
    done|failed) printf '0\n' ;;
    *) printf '1\n' ;;
  esac
}

# --- draft ------------------------------------------------------------------

cmd_draft() {
  local out='' force=0 now listing tmp rowfile id show hold_kind
  local title reason body origin key created age blocked live until repo
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -gt 1 ] || fail "--out requires a path"; out=$2; shift 2 ;;
      --force) force=1; shift ;;
      *) fail "unknown draft argument: $1" ;;
    esac
  done
  require_tasks_axi
  [ -n "$out" ] || out="$FM_HOME/.lavish/tablero.draft.md"
  if [ -e "$out" ] && [ "$force" -ne 1 ]; then
    fail "draft already exists and may hold written judgment: $out (pass --force to replace it)"
  fi
  now=$(today)
  listing=$(tasks_axi list --blocked --fields blocked_by 2>/dev/null || true)
  tmp=$(scratch)
  rowfile="$tmp/rows"
  : > "$rowfile"

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(tasks_axi show "$id" --full 2>/dev/null) || continue
    hold_kind=$(show_field "$show" hold_kind)
    [ "$hold_kind" = captain ] || continue
    title=$(unquote "$(show_field "$show" title)")
    reason=$(unquote "$(show_field "$show" hold_reason)")
    body=$(unquote "$(show_field "$show" body)")
    repo=$(unquote "$(show_field "$show" repo)")
    created=$(show_field "$show" created)
    until=$(unquote "$(show_field "$show" hold_until)")
    origin=$(printf '%s\n' "$body" | sed -n 's/^Origin: //p' | head -1)
    key=$(printf '%s\n' "$body" | sed -n 's/^Decision key: //p' | head -1)
    case "$origin" in *[!A-Za-z0-9._-]*) origin='' ;; esac
    case "$key" in ''|*[!A-Za-z0-9._-]*) key='' ;; esac
    # A plain captain-gated task carries no decision key; its own identity is the
    # only stable question slug available, and it will not auto-close.
    [ -n "$key" ] || key=$id
    case "$created" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) age=$(days_between "$created" "$now") ;;
      *) age=0; created='' ;;
    esac
    blocked=$(count_blocked_by "$listing" "$id")
    live=$(origin_live "$origin")
    # Zero-padded cost fields first so a reverse lexical sort is a numeric one.
    # US (\037) delimits, never TAB: TAB is an IFS whitespace character, so `read`
    # would collapse a run of them and silently shift every field after an empty
    # origin by one. US is not whitespace and cannot occur in a backlog record.
    printf '%09d%s%s%s%09d%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "$blocked" "$US" "$live" "$US" "$age" "$US" "$id" "$US" "$key" "$US" "$origin" "$US" \
      "$repo" "$US" "$age" "$US" "$blocked" "$US" "$until" "$US" "$title" \
      >> "$rowfile"
    printf '%s' "$reason" > "$tmp/evidence.$id"
  done <<EOF
$(held_ids)
EOF

  mkdir -p "$(dirname "$out")"
  {
    printf '# Tablero de decisiones - borrador generado por bin/fm-tablero.sh el %s.\n' "$now"
    printf '#\n'
    printf '# Lo mecanico ya esta puesto: las decisiones abiertas, su orden por lo que\n'
    printf '# cuesta no decidirlas, su evidencia verbatim, y el formulario de cada una.\n'
    printf '# Falta el juicio, y solo lo pones tu:\n'
    printf '#   - la recomendacion de cada decision, con su razon\n'
    printf '#   - las opciones reales entre las que elige el capitan\n'
    printf '#   - el aviso de arriba cuando dos o mas decisiones se tocan\n'
    printf '# check y render se niegan mientras quede un %s\n' "$HOLE"
    printf '#\n'
    printf '# Las tarjetas se pintan en el orden de este archivo. El orden que traen es\n'
    printf '# el mecanico; reordena los bloques "## decision" si tu juicio dice otra cosa.\n'
    printf '# Una linea que empieza con # es comentario en todo el archivo.\n'
    printf '\n'
    printf '## pagina\n'
    printf 'titulo: %s Un titulo que diga de que trata la ronda.\n' "$HOLE"
    printf 'bajada: %s Una linea que diga por que esta pagina existe hoy.\n' "$HOLE"
    printf '\n'
    printf '## aviso\n'
    printf '%s Si dos o mas decisiones de abajo se tocan, escribe aqui como se\n' "$HOLE"
    printf 'apilan y que hay que leer antes de contestarlas. Si ninguna se toca, deja\n'
    printf 'este bloque con la sola palabra ninguna, sin comillas, y el aviso no se pinta.\n'
    if [ ! -s "$rowfile" ]; then
      printf '\n'
      printf '# No hay ninguna decision del capitan abierta en este hogar. Nada que servir.\n'
    fi
    LC_ALL=C sort -t"$US" -k1,1r -k2,2r -k3,3r -k4,4 "$rowfile" |
      while IFS="$US" read -r _ _ _ id key origin repo age blocked until title; do
        [ -n "$id" ] || continue
        printf '\n## decision %s\n' "$id"
        printf 'clave: %s\n' "$key"
        printf 'origen: %s\n' "$origin"
        printf 'grupo: activa\n'
        printf 'titulo: %s\n' "$title"
        [ -z "$repo" ] || [ "$repo" = '-' ] || printf 'etiqueta: %s\n' "$repo"
        case "$age" in
          0) printf 'etiqueta: nueva, de hoy\n' ;;
          1) printf 'etiqueta: 1 dia esperando\n' ;;
          *) printf 'etiqueta: %s dias esperando\n' "$age" ;;
        esac
        [ "$blocked" -eq 0 ] || printf 'etiqueta: para %s tarea(s)\n' "$blocked"
        [ -z "$until" ] || [ "$until" = '-' ] || printf 'etiqueta: se suelta sola el %s\n' "$until"
        printf '### evidencia\n'
        if [ -s "$tmp/evidence.$id" ]; then
          cat "$tmp/evidence.$id"
          printf '\n'
        else
          printf '%s Sin razon registrada en el pendiente; pega aqui la evidencia.\n' "$HOLE"
        fi
        printf '### porque\n'
        printf '%s Por que esta decision le cuesta al capitan hoy, en una o dos frases.\n' "$HOLE"
        printf '### reco\n'
        printf 'valor: %s La respuesta exacta que se manda si elige esta.\n' "$HOLE"
        printf '%s La opcion que recomiendas y, en la misma frase, la razon.\n' "$HOLE"
        printf '### opcion\n'
        printf 'valor: %s La respuesta exacta que se manda si elige esta.\n' "$HOLE"
        printf '%s La otra opcion real, dicha sin adornarla.\n' "$HOLE"
      done
  } > "$out"

  printf 'draft: %s\n' "$out"
  printf 'decisiones: %s\n' "$(grep -c '^## decision ' "$out" || true)"
  printf 'huecos: %s\n' "$(hole_hits "$out" | wc -l | tr -d ' ')"
}

# --- page assets ------------------------------------------------------------

# The captain's own hand-built board proved this on a phone: one column capped at
# 44rem, native controls, a dark-mode pair, and no horizontal overflow anywhere.
tablero_css() {
  cat <<'CSS'
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{
    --tinta:#1c1b19; --tinta-2:#4a463f; --tinta-3:#7d776c;
    --papel:#faf8f4; --papel-2:#f2eee6; --linea:#e0d9cc;
    --acento:#9a3412; --acento-suave:#fdf1ec;
    --verde:#1f6f43; --verde-suave:#eaf4ee;
    --sans:ui-sans-serif,-apple-system,"SF Pro Text",Inter,system-ui,sans-serif;
    --mono:ui-monospace,"SF Mono",Menlo,monospace;
    --serif:ui-serif,"New York",Georgia,serif;
  }
  @media (prefers-color-scheme: dark){
    :root{
      --tinta:#f0ece5; --tinta-2:#c3bcb0; --tinta-3:#8e8779;
      --papel:#171614; --papel-2:#201e1b; --linea:#37342f;
      --acento:#f0855a; --acento-suave:#2a1a12;
      --verde:#6fcf97; --verde-suave:#13251b;
    }
  }
  *{box-sizing:border-box; min-width:0;}
  body{margin:0; background:var(--papel); color:var(--tinta);
    font-family:var(--sans); font-size:16px; line-height:1.55; -webkit-text-size-adjust:100%;}
  .envoltura{max-width:44rem; margin:0 auto; padding:1.25rem 1.1rem 5rem;}
  header.cab{padding:.5rem 0 1.5rem; border-bottom:2px solid var(--tinta); margin-bottom:1.5rem;}
  .marca{font-family:var(--mono); font-size:.7rem; letter-spacing:.14em;
    text-transform:uppercase; color:var(--tinta-3);}
  h1{font-family:var(--serif); font-size:2rem; line-height:1.15; margin:.5rem 0 .6rem;
    letter-spacing:-.02em; overflow-wrap:anywhere;}
  .bajada{color:var(--tinta-2); margin:0; font-size:1rem;}
  .aviso{border:2px solid var(--acento); background:var(--acento-suave);
    border-radius:.75rem; padding:1rem 1.1rem; margin:1.5rem 0 2rem;}
  .aviso .tit{font-family:var(--mono); font-size:.68rem; letter-spacing:.12em;
    text-transform:uppercase; color:var(--acento); margin-bottom:.5rem;}
  .aviso p{margin:0 0 .6rem; font-size:.95rem; color:var(--tinta-2);}
  .aviso p:last-child{margin-bottom:0;}
  .aviso strong{color:var(--tinta);}
  .tarjeta{background:var(--papel-2); border:1px solid var(--linea);
    border-radius:.75rem; padding:1.1rem; margin-bottom:1.1rem;}
  .tarjeta.espera{border-style:dashed; opacity:.92;}
  .cinta{display:flex; flex-wrap:wrap; gap:.4rem; align-items:center; margin-bottom:.6rem;}
  .etiq{font-family:var(--mono); font-size:.64rem; letter-spacing:.08em; text-transform:uppercase;
    padding:.16rem .45rem; border-radius:.3rem; border:1px solid var(--linea);
    color:var(--tinta-3); overflow-wrap:anywhere;}
  h3{font-family:var(--serif); font-size:1.22rem; line-height:1.25; margin:0 0 .55rem;
    letter-spacing:-.01em; overflow-wrap:anywhere;}
  .porque{margin:0 0 .9rem; color:var(--tinta-2); font-size:.94rem;}
  .porque strong{color:var(--tinta);}
  .dato{font-family:var(--mono); font-size:.82rem; background:var(--papel);
    border-left:3px solid var(--acento); padding:.55rem .7rem;
    border-radius:0 .35rem .35rem 0; margin:0 0 .9rem; color:var(--tinta-2);
    overflow-wrap:anywhere;}
  form{margin:0;}
  .ops{display:flex; flex-direction:column; gap:.5rem; margin-bottom:.85rem;}
  label.op{display:flex; gap:.65rem; align-items:flex-start; cursor:pointer;
    background:var(--papel); border:1.5px solid var(--linea); border-radius:.55rem;
    padding:.75rem .8rem; font-size:.93rem; line-height:1.45;
    transition:border-color .12s, background .12s;}
  label.op:has(input:checked){border-color:var(--acento); background:var(--acento-suave);}
  label.op input{margin:.28rem 0 0; accent-color:var(--acento);
    width:1.05rem; height:1.05rem; flex:none;}
  label.op span{overflow-wrap:anywhere;}
  .rec{display:inline-block; font-family:var(--mono); font-size:.6rem; letter-spacing:.07em;
    text-transform:uppercase; color:var(--verde); background:var(--verde-suave);
    border:1px solid var(--verde); border-radius:.25rem; padding:.05rem .35rem;
    margin-left:.35rem; white-space:nowrap;}
  .pie{display:flex; flex-wrap:wrap; gap:.6rem; align-items:center;}
  button.enviar{font-family:var(--sans); font-size:.9rem; font-weight:600; cursor:pointer;
    background:var(--tinta); color:var(--papel); border:none; border-radius:.5rem;
    padding:.6rem 1.1rem; min-height:2.6rem;}
  button.enviar:active{opacity:.75;}
  .estado{font-family:var(--mono); font-size:.76rem; color:var(--verde); font-weight:600;}
  .estado:empty{display:none;}
  .cierre{margin-top:2.5rem; padding:1.1rem; border:1px dashed var(--linea);
    border-radius:.75rem; background:var(--papel-2); font-size:.9rem; color:var(--tinta-2);}
  .cierre b{color:var(--tinta);}
  @media (max-width:420px){ h1{font-size:1.65rem;} .envoltura{padding:1rem .85rem 4rem;} }
</style>
CSS
}

# The queued payload is the canonical Lavish choice shape, which is exactly what
# bin/fm-procevent-lavish.sh reads: tag `choice`, and `question`/`answer` in data.
# Both strings are read from data attributes rather than interpolated into this
# source, so no captain prose is ever parsed as JavaScript.
tablero_js() {
  cat <<'JS'
<script>
  function encolar(form){
    var elegido = new FormData(form).get('op');
    if (!elegido) return;
    var clave = form.getAttribute('data-clave');
    var titulo = form.getAttribute('data-titulo');
    window.lavish.queuePrompt(
      'DECISION DEL CAPITAN [' + clave + '] ' + titulo + ' -> ' + elegido,
      { tag: 'choice', text: titulo + ': ' + elegido, element: form,
        queueKey: clave, data: { question: clave, answer: elegido } }
    );
    var e = form.querySelector('[data-estado]');
    if (e) e.textContent = '✓ encolada';
  }
</script>
JS
}

# --- the one draft parser, shared by check and render -----------------------

AWK_PROG=$(cat <<'AWK'
function esc(s) {
  gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
  gsub(/"/, "\\&quot;", s)
  return s
}
# Inline emphasis applied AFTER escaping, so a literal < in prose can never open
# a tag. An unbalanced ** is closed rather than left dangling.
function rich(s,   out, i, n, parts) {
  s = esc(s)
  n = split(s, parts, "\\*\\*")
  out = parts[1]
  for (i = 2; i <= n; i++) out = out (i % 2 == 0 ? "<strong>" : "</strong>") parts[i]
  if (n % 2 == 0) out = out "</strong>"
  return out
}
function err(m) { printf "error: %s\n", m > "/dev/stderr"; errors++ }
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function flush_prose(   t) { t = prose; prose = ""; return trim(t) }

function close_sub(   t) {
  t = flush_prose()
  if (sub_kind == "evidencia") evidencia[dn] = t
  else if (sub_kind == "porque") porque[dn] = t
  else if (sub_kind == "reco" || sub_kind == "opcion") {
    on[dn]++
    otext[dn, on[dn]] = t
    oval[dn, on[dn]] = (pending_val == "" ? t : pending_val)
    oreco[dn, on[dn]] = (sub_kind == "reco" ? 1 : 0)
    if (sub_kind == "reco") nreco[dn]++
  }
  sub_kind = ""; pending_val = ""
}

function close_block() {
  if (sub_kind != "") close_sub()
  else if (block == "aviso") aviso = flush_prose()
  prose = ""
}

# One paragraph per blank-line-separated chunk, with the given CSS class.
function paragraphs(text, cls,   np, ps, p, t) {
  np = split(text, ps, "\n\n")
  for (p = 1; p <= np; p++) {
    t = trim(ps[p])
    if (t == "") continue
    gsub(/\n/, " ", t)
    print "  <p" (cls == "" ? "" : " class=\"" cls "\"") ">" rich(t) "</p>"
  }
}

BEGIN { block = ""; sub_kind = ""; dn = 0; errors = 0; norigins = 0 }

# A comment anywhere, EXCEPT inside a written block, where it would silently
# swallow a line of the captain's own recommendation. Losing prose quietly is the
# exact failure mode this board exists to prevent, so it refuses instead.
/^#[^#]/ || /^#$/ {
  if (sub_kind != "" || block == "aviso")
    err("a line beginning with # inside " (sub_kind == "" ? "`## aviso`" : "`### " sub_kind "`") \
        " would be dropped as a comment; do not begin written prose with #")
  next
}

/^## pagina[[:space:]]*$/ { close_block(); block = "pagina"; next }
/^## aviso[[:space:]]*$/  { close_block(); block = "aviso"; next }
/^## decision[[:space:]]/ {
  close_block(); block = "decision"
  dn++
  id[dn] = trim(substr($0, 13))
  if (id[dn] !~ /^[A-Za-z0-9._-]+$/) err("decision " dn " has no usable identity: " id[dn])
  grupo[dn] = "activa"
  next
}
/^###[[:space:]]/ {
  if (block != "decision") { err("`" trim($0) "` sits outside a `## decision` block"); next }
  close_block()
  sub_kind = trim(substr($0, 5))
  if (sub_kind !~ /^(evidencia|porque|reco|opcion)$/) {
    err("unknown sub-block in " id[dn] ": " sub_kind)
    sub_kind = ""
  }
  next
}

block == "pagina" && /^titulo:/ { titulo = trim(substr($0, 8)); next }
block == "pagina" && /^bajada:/ { bajada = trim(substr($0, 8)); next }

block == "decision" && sub_kind == "" && /^clave:/    { clave[dn]   = trim(substr($0, 7));  next }
block == "decision" && sub_kind == "" && /^origen:/   { origen[dn]  = trim(substr($0, 8));  next }
block == "decision" && sub_kind == "" && /^grupo:/    { grupo[dn]   = trim(substr($0, 7));  next }
block == "decision" && sub_kind == "" && /^titulo:/   { dtitulo[dn] = trim(substr($0, 8));  next }
block == "decision" && sub_kind == "" && /^etiqueta:/ {
  en[dn]++; etiq[dn, en[dn]] = trim(substr($0, 10)); next
}
(sub_kind == "reco" || sub_kind == "opcion") && /^valor:/ && prose == "" {
  pending_val = trim(substr($0, 7)); next
}

{ prose = prose (prose == "" ? "" : "\n") $0 }

END {
  close_block()

  if (titulo == "") err("`## pagina` needs a titulo")
  if (bajada == "") err("`## pagina` needs a bajada")
  if (aviso == "") err("`## aviso` needs the interaction warning, or the single word `ninguna`")
  if (dn == 0) err("the draft carries no `## decision` block, so there is no board to serve")
  for (i = 1; i <= dn; i++) {
    if (clave[i] !~ /^[A-Za-z0-9._-]{1,64}$/)
      err(id[i] ": clave must be a slug of at most 64 characters, got `" clave[i] "`")
    if (dtitulo[i] == "") err(id[i] ": needs a titulo")
    if (porque[i] == "") err(id[i] ": needs a `### porque`")
    if (grupo[i] != "activa" && grupo[i] != "espera")
      err(id[i] ": grupo must be activa or espera, got `" grupo[i] "`")
    if (grupo[i] == "activa") {
      if (nreco[i] + 0 != 1)
        err(id[i] ": needs exactly one `### reco` carrying the recommendation, found " nreco[i] + 0)
      if (on[i] + 0 < 2)
        err(id[i] ": needs at least two options so the captain has a real choice")
      for (j = 1; j <= on[i]; j++) {
        if (otext[i, j] == "") err(id[i] ": option " j " has no text the captain can read")
        if (length(oval[i, j]) > 512) err(id[i] ": option " j " answer exceeds 512 characters")
      }
    }
    # A bound origin closes `<origin>-decision-<clave>`, so the same clave under
    # two origins could close the wrong hold.
    if (clave[i] in seen_origin && seen_origin[clave[i]] != origen[i])
      err("clave `" clave[i] "` appears under two origins (`" seen_origin[clave[i]] "` and `" origen[i] "`)")
    seen_origin[clave[i]] = origen[i]
    if (origen[i] != "" && !(origen[i] in origins)) { origins[origen[i]] = 1; norigins++ }
  }

  if (errors > 0) exit 1

  if (mode == "check") {
    printf "ok: %d decision(s), %d origin(s)\n", dn, norigins
    for (o in origins) printf "origin: %s\n", o
    exit 0
  }

  print "<title>" esc(titulo) "</title>"
  printf "%s", ENVIRON["TABLERO_CSS"]
  print "<div class=\"envoltura\">"
  print "<header class=\"cab\">"
  print "  <div class=\"marca\">Firstmate &middot; decisiones suyas</div>"
  print "  <h1>" rich(titulo) "</h1>"
  print "  <p class=\"bajada\">" rich(bajada) "</p>"
  print "</header>"

  if (aviso != "ninguna") {
    print "<div class=\"aviso\">"
    print "  <div class=\"tit\">Lealo antes de contestar</div>"
    paragraphs(aviso, "")
    print "</div>"
  }

  for (i = 1; i <= dn; i++) {
    print "<div class=\"tarjeta" (grupo[i] == "espera" ? " espera" : "") "\">"
    if (en[i] > 0) {
      printf "  <div class=\"cinta\">"
      for (j = 1; j <= en[i]; j++) printf "<span class=\"etiq\">%s</span>", esc(etiq[i, j])
      print "</div>"
    }
    print "  <h3>" rich(dtitulo[i]) "</h3>"
    paragraphs(porque[i], "porque")
    if (evidencia[i] != "") {
      ev = esc(evidencia[i])
      gsub(/\n/, "<br>", ev)
      print "  <p class=\"dato\">" ev "</p>"
    }
    if (grupo[i] == "espera") {
      print "  <p class=\"porque\">No hay nada que contestar aqui. Esta en la lista para que vea que no se perdio.</p>"
      print "</div>"
      continue
    }
    printf "  <form data-lavish-question=\"%s\" data-clave=\"%s\" data-titulo=\"%s\"", \
      esc(clave[i]), esc(clave[i]), esc(dtitulo[i])
    print " onsubmit=\"event.preventDefault();encolar(this)\">"
    print "    <div class=\"ops\">"
    for (j = 1; j <= on[i]; j++) {
      t = otext[i, j]
      gsub(/\n/, " ", t)
      printf "      <label class=\"op\"><input type=\"radio\" name=\"op\" value=\"%s\"><span>%s%s</span></label>\n", \
        esc(oval[i, j]), rich(t), (oreco[i, j] ? "<span class=\"rec\">mi reco</span>" : "")
    }
    print "    </div>"
    print "    <div class=\"pie\"><button class=\"enviar\" type=\"submit\">Encolar</button><span class=\"estado\" data-estado></span></div>"
    print "  </form>"
    print "</div>"
  }

  print "<div class=\"cierre\">"
  print "  <b>Cuando termine</b>, use el boton de enviar de Lavish para mandarme todo de una vez."
  print "  Lo que no toque se queda esperando. Si quiere responder distinto a lo que le ofrezco,"
  print "  seleccione el texto de la tarjeta y escribame ahi."
  print "</div>"
  print "</div>"
  printf "%s", ENVIRON["TABLERO_JS"]
}
AWK
)

draft_awk() {  # <mode> <draft>
  TABLERO_CSS="$(tablero_css)" TABLERO_JS="$(tablero_js)" \
    awk -v mode="$1" "$AWK_PROG" "$2"
}

# --- check and render -------------------------------------------------------

require_draft() {  # <path>
  [ -n "${1-}" ] || fail "a draft path is required"
  [ -f "$1" ] || fail "draft does not exist: $1"
}

# Every unfilled judgment hole, as `<line>:<text>`. Comment lines are skipped for
# the same reason the grammar skips them: the header explains the marker and can
# never be filled, so counting it would make the draft impossible to pass.
hole_hits() {  # <draft>
  awk -v hole="$HOLE" '
    /^#/ { next }
    index($0, hole) > 0 { printf "%d:%s\n", NR, $0 }
  ' "$1"
}

# The judgment refusal. Enforced on the same bytes the grammar parses, and named
# loudly enough that the fix is obvious: write the judgment.
refuse_holes() {  # <draft>
  local hits n
  hits=$(hole_hits "$1")
  [ -n "$hits" ] || return 0
  n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
  printf 'fm-tablero: %s unfilled %s hole(s) in %s\n' "$n" "$HOLE" "$1" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  printf 'fm-tablero: write the recommendation, the options and the interaction warning first\n' >&2
  exit 1
}

cmd_check() {
  [ "$#" -eq 1 ] || fail "check takes exactly one draft path"
  require_draft "$1"
  refuse_holes "$1"
  draft_awk check "$1"
}

cmd_render() {
  local draft='' out='' base summary origins
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -gt 1 ] || fail "--out requires a path"; out=$2; shift 2 ;;
      -*) fail "unknown render argument: $1" ;;
      *) [ -z "$draft" ] || fail "render takes exactly one draft path"; draft=$1; shift ;;
    esac
  done
  require_draft "$draft"
  refuse_holes "$draft"
  if [ -z "$out" ]; then
    base=$(basename "$draft"); base=${base%.md}; base=${base%.draft}
    out="$FM_HOME/.lavish/$base.html"
  fi
  case "$out" in */*) mkdir -p "$(dirname "$out")" ;; esac
  draft_awk render "$draft" > "$out.tmp" || { rm -f "$out.tmp"; exit 1; }
  mv "$out.tmp" "$out"
  printf 'page: %s\n' "$out"
  # Which origins this page carries, and a pointed warning when that is more than
  # one, because a binding names a single origin and every key outside it comes
  # back unclosed. Silence here would read as "the whole page auto-closes".
  summary=$(draft_awk check "$draft") || exit 1
  printf '%s\n' "$summary" | grep '^origin: ' || true
  origins=$(printf '%s\n' "$summary" | grep -c '^origin: ' || true)
  if [ "$origins" -gt 1 ]; then
    printf 'aviso: esta pagina lleva %s origenes y una vinculacion nombra solo uno.\n' "$origins"
    printf '       las respuestas de los otros origenes NO se cierran solas; cierralas\n'
    printf '       con bin/fm-decision-hold.sh una por una.\n'
  else
    printf 'nota: vinculala a su origen antes de armarla y las respuestas cierran solas.\n'
  fi
}

case "${1-}" in
  draft)  shift; cmd_draft "$@" ;;
  check)  shift; cmd_check "$@" ;;
  render) shift; cmd_render "$@" ;;
  ''|-h|--help|help) usage ;;
  *) fail "unknown command: $1" ;;
esac
