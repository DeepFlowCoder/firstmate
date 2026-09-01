#!/usr/bin/env bash
# Decide whether an older no-mistakes pipeline attestation may stand in for the
# current PR head, because every commit added since that attestation is one of
# the pipeline's own CI-fix commits.
#
# WHY THIS EXISTS. The shared `require-no-mistakes` action is a pure function of
# the PR body plus the PR head SHA: it binds the attestation to the exact head
# and has no view of commit ancestry. The pipeline's `ci` phase pushes its own
# "no-mistakes: apply CI fixes" commits WITHOUT re-running the `pr` step that
# writes the attestation, so each such push orphans the attestation just written
# and the required check refuses head after head until a human re-pushes. This
# script supplies the one fact the shared action cannot see - what the delta
# between the attested commit and the current head actually contains - so the
# caller can re-run the shared action bound to a vetted ancestor instead.
#
# WHAT IT CERTIFIES. Exactly one thing: the attested commit is a strict ancestor
# of the current head, and every commit in between is a single-parent commit
# whose subject is the pipeline's literal CI-fix subject. It reads no other part
# of the attestation and judges no compliance question; the shared action stays
# the single owner of the signature, attestation, and required-step semantics.
# On acceptance the vetted ancestor SHA is printed on stdout for the caller to
# feed back to that action.
#
# WHAT IT DOES NOT CERTIFY. The pipeline's review, test, and document steps ran
# against the attested tree, not against the CI-fix commits layered on top, so
# the accepted head carries pipeline-authored corrections those steps never saw.
# That is the deliberate, bounded relaxation. It is also not forgery-proof: a
# commit subject is author-chosen, exactly as the PR-body attestation is
# author-editable. This is a contributor guardrail, inheriting that accepted
# limitation from the shared action rather than adding a new class of it.
#
# A rebase is refused on purpose. Recreating the branch gives every commit a new
# identity, so no attested commit remains an ancestor, the comparison reports
# diverged rather than ahead, and the check stays red - which is the correct
# verdict for a wholesale rewrite no gate ever saw.
#
# docs/verification/no-mistakes-gate.md records the dated live evidence behind
# the two claims a faked `gh` cannot prove: that the forge still answers the
# comparison with the fields parsed below, and that both real incidents resolve
# the way this header says they do.
#
# Usage: fm-nm-attestation-delta.sh --repo <owner/name> --head <sha>
#                                   [--body-file <path>]
# The PR body comes from --body-file, or from NM_PR_BODY when no file is given.
# Exit 0: accepted; the vetted ancestor SHA is on stdout.
# Exit 1: refused; the caller must leave the gate red.
# Exit 2: invalid usage or a missing dependency.
set -eu

# The exact subject the pipeline gives its post-attestation CI-fix commits.
# Matched in full, never as a prefix: a wording change upstream must fall back
# to today's behaviour (red until a re-push) rather than widen what is accepted.
NM_CI_FIX_SUBJECT='no-mistakes: apply CI fixes'

ATTESTATION_PREFIX='<!-- no-mistakes-pipeline-attestation:v1 '
ATTESTATION_CLOSING=' -->'

# The header block above is the documentation; print it rather than keeping a
# second copy that can drift away from it.
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

die() {
  echo "error: $*" >&2
  exit 2
}

refuse() {
  echo "refused: $*" >&2
  exit 1
}

is_sha() {
  case "${1:-}" in
    "" | *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

REPO=
HEAD_SHA=
BODY_FILE=
while [ "$#" -gt 0 ]; do
  case $1 in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a value"; REPO=$2; shift 2 ;;
    --head) [ "$#" -ge 2 ] || die "--head requires a value"; HEAD_SHA=$2; shift 2 ;;
    --body-file) [ "$#" -ge 2 ] || die "--body-file requires a value"; BODY_FILE=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ] || die "--repo <owner/name> is required"
[ -n "$HEAD_SHA" ] || die "--head <sha> is required"
case $REPO in
  */*/* | /* | */ | *' '*) die "--repo must be a plain owner/name slug" ;;
  */*) ;;
  *) die "--repo must be a plain owner/name slug" ;;
esac
is_sha "$HEAD_SHA" || die "--head must be a full 40-character commit SHA"

command -v gh >/dev/null 2>&1 || die "gh is required to compare the attested commit with the PR head"
command -v jq >/dev/null 2>&1 || die "jq is required to read the commit comparison"

if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || die "--body-file does not name a readable file: $BODY_FILE"
  BODY=$(cat "$BODY_FILE")
else
  BODY=${NM_PR_BODY-}
fi

# Minimal extraction: only head_sha, only from the first v1 attestation comment.
# A wrong read here cannot widen anything, because the caller re-runs the shared
# action bound to whatever this prints and that action re-checks the same field.
REST=${BODY#*"$ATTESTATION_PREFIX"}
[ "$REST" != "$BODY" ] || refuse "the PR body carries no v1 pipeline attestation to reconcile"
PAYLOAD=${REST%%"$ATTESTATION_CLOSING"*}
[ "$PAYLOAD" != "$REST" ] || refuse "the v1 pipeline attestation comment in the PR body is unterminated"

ATTESTED=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" and (.head_sha | type) == "string" then .head_sha else "" end' 2>/dev/null) || ATTESTED=
is_sha "$ATTESTED" || refuse "the pipeline attestation carries no usable head_sha"

# An exact match is the shared action's own business and it already judged it.
[ "$ATTESTED" != "$HEAD_SHA" ] || refuse "the attestation already binds to the current PR head; there is no delta to reconcile"

if ! COMPARE=$(gh api "repos/$REPO/compare/$ATTESTED...$HEAD_SHA" 2>/dev/null); then
  refuse "the forge did not answer a commit comparison for $ATTESTED...$HEAD_SHA"
fi

# Line-oriented so the policy below stays plain shell: one status line, one
# total line, one returned-count line, then one record per delta commit.
if ! SUMMARY=$(printf '%s' "$COMPARE" | jq -r '
  "status\t" + (.status // ""),
  "total\t" + ((.total_commits // -1) | tostring),
  "returned\t" + ((.commits // []) | length | tostring),
  ((.commits // [])[]
    | "commit\t" + ((.parents // []) | length | tostring)
      + "\t" + ((.commit.message // "") | split("\n")[0]))
' 2>/dev/null); then
  refuse "the commit comparison for $ATTESTED...$HEAD_SHA was not readable"
fi

STATUS=
TOTAL=
RETURNED=
SEEN=0
REJECT=
while IFS=$'\t' read -r kind first rest; do
  case $kind in
    status) STATUS=$first ;;
    total) TOTAL=$first ;;
    returned) RETURNED=$first ;;
    commit)
      SEEN=$((SEEN + 1))
      subject=${rest%$'\r'}
      if [ -z "$REJECT" ] && [ "$first" != 1 ]; then
        REJECT="the delta contains a commit with $first parents; only single-parent commits are reconcilable"
      fi
      if [ -z "$REJECT" ] && [ "$subject" != "$NM_CI_FIX_SUBJECT" ]; then
        REJECT="the delta contains a commit the pipeline did not author: \"$subject\""
      fi
      ;;
  esac
done <<SUMMARY_EOF
$SUMMARY
SUMMARY_EOF

# "ahead" is the only comparison in which the attested commit is still a strict
# ancestor of the head. "diverged" is the rebase case, "identical" and "behind"
# cannot describe a head that moved forward past its attestation.
[ "$STATUS" = ahead ] || refuse "the attested commit $ATTESTED is not an ancestor of the PR head (comparison reported ${STATUS:-nothing})"

case ${TOTAL:-} in
  "" | *[!0-9]*) refuse "the commit comparison reported no usable commit count" ;;
esac
case ${RETURNED:-} in
  "" | *[!0-9]*) refuse "the commit comparison reported no usable commit list" ;;
esac
[ "$TOTAL" -ge 1 ] || refuse "the commit comparison reported an empty delta"
# The compare endpoint caps its commit list, so a delta longer than the page is
# only partly visible. Refuse rather than vet a prefix of it.
[ "$TOTAL" -eq "$RETURNED" ] || refuse "the commit comparison listed $RETURNED of $TOTAL commits; the delta is too long to vet"
[ "$SEEN" -eq "$RETURNED" ] || refuse "the commit comparison did not yield every listed commit"
[ -z "$REJECT" ] || refuse "$REJECT"

printf '%s\n' "$ATTESTED"
