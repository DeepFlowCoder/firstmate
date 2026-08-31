#!/usr/bin/env bash
# fm-notify-moshi.sh - deliver one alert to the captain's phone through Moshi's
# push webhook, for use as a config/wedge-alarm `command:` channel.
#
# Usage: fm-notify-moshi.sh [<summary>]
#        fm-notify-moshi.sh --help
#
# The summary is read from $1, or from stdin when $1 is absent or empty. That
# matches the wedge-alarm `command:` contract, which passes the alarm summary
# both ways (docs/wedge-alarm.md owns that contract). Nothing else is read from
# stdin, so curl is free to take the request body from this script's pipe.
#
# Moshi's webhook carries its API token in the JSON body rather than a header,
# so the token is piped into jq and on to curl and never appears in any argv:
# macOS `ps` shows full command lines to every local user, so a token on a
# command line is a token published to the machine. The token is likewise never
# written to disk here and never printed, including on failure.
#
# Token source, first match wins:
#   FM_MOSHI_TOKEN_OP_REF   1Password secret reference, read with `op read`
#   Keychain                `security find-generic-password -w`, service
#                           FM_MOSHI_KEYCHAIN_SERVICE (default firstmate-moshi)
# The Keychain is the default because `security` reads back an item it created
# without an authorization prompt, as long as the keychain holding it is
# unlocked. A locked 1Password vault instead blocks `op read` on a biometric
# prompt, so an op reference trades away-mode reliability for vault-managed
# storage; docs/wedge-alarm.md records that trade-off for the captain.
#
# Environment:
#   FM_MOSHI_TOKEN_OP_REF      1Password secret reference (op://vault/item/field)
#   FM_MOSHI_KEYCHAIN_SERVICE  Keychain service name (default: firstmate-moshi)
#   FM_MOSHI_KEYCHAIN_ACCOUNT  optional Keychain account name
#   FM_MOSHI_TITLE             notification title (default: Firstmate alert)
#   FM_MOSHI_UNIFIED           1/true: add `unified: true`, notifying every
#                              opted-in device on the license; omitted otherwise
#   FM_MOSHI_ENDPOINT          webhook URL (default: Moshi's public endpoint)
#   FM_MOSHI_TIMEOUT_SECS      curl deadline in seconds (default: 8)
#
# The default deadline stays inside the wedge alarm's own 10s per-channel bound
# (FM_WEDGE_ALARM_TIMEOUT_SECS) so a slow network fails as a reported non-zero
# exit rather than as a process-group kill with no diagnostic.
#
# Exit: 0 delivered (2xx), 1 delivery failed, 2 usage or configuration error,
# and 128+signum when a signal ends the run: 129 on HUP, 130 on INT, 143 on
# TERM, so a hand-run `fm-notify-moshi.sh 'test summary'` reports which signal
# ended it instead of reporting every signal as a SIGTERM. Those codes cover the
# failures this script observes and returns from, and no other signal is trapped
# here. `op
# read` carries no deadline of its own, so against a genuinely locked vault it
# blocks on the unlock prompt instead of returning: the alarm's per-channel
# watchdog then kills the process group and the daemon logs rc 124, not the
# exit 2 above. The daemon bounds every channel already, so this script adds no
# second watchdog.
set -u

ENDPOINT_DEFAULT='https://api.getmoshi.app/api/webhook'
KEYCHAIN_SERVICE_DEFAULT='firstmate-moshi'
TITLE_DEFAULT='Firstmate alert'
TIMEOUT_SECS_DEFAULT=8

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -gt 1 ]; then
  echo "error: expected at most one summary argument" >&2
  exit 2
fi

SUMMARY=${1-}
if [ -z "$SUMMARY" ] && [ ! -t 0 ]; then
  SUMMARY=$(cat)
fi
# Trim surrounding whitespace so a stdin-delivered summary's trailing newline
# does not become notification body text.
SUMMARY="${SUMMARY#"${SUMMARY%%[![:space:]]*}"}"
SUMMARY="${SUMMARY%"${SUMMARY##*[![:space:]]}"}"
if [ -z "$SUMMARY" ]; then
  echo "error: empty alert summary; nothing to send" >&2
  exit 2
fi

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 2; }
done

# One bounded, single-line excerpt of a captured stderr file. Every reader here
# emits its secret on stdout only, so these files carry diagnostics and nothing
# else; the cap keeps a verbose reader from flooding the message.
captured_detail() {  # <stderr-file>
  local detail
  detail=$(tr '\n' ' ' < "$1" 2>/dev/null | cut -c1-200)
  detail="${detail#"${detail%%[![:space:]]*}"}"
  detail="${detail%"${detail##*[![:space:]]}"}"
  printf '%s' "$detail"
}

# When a reader RETURNS a failure, both its exit status and its own words are
# reported and neither is interpreted, because the script cannot know the cause:
# a reader that says "The specified item could not be found in the keychain."
# has named a missing item, while a reader that returns some other status
# without saying anything has not named anything, and inventing a cause for it
# would be the guess this reporting exists to remove.
#
# NOT established, and deliberately not promised: whether a locked keychain
# returns a failure here at all rather than BLOCKING on an unlock prompt. If it
# blocks, nothing below runs - a hand run waits on that dialog, and on the alarm
# path the daemon's per-channel watchdog kills the process group and logs 124,
# so this detail never reaches the log through that path.
reader_failure() {  # <reader> <status> <stderr-file>
  local detail
  detail=$(captured_detail "$3")
  if [ -n "$detail" ]; then
    printf '%s exit %s: %s' "$1" "$2" "$detail"
  else
    printf '%s exit %s' "$1" "$2"
  fi
}

# Print the API token on stdout. Never logs or echoes the value itself.
resolve_token() {
  local ref=${FM_MOSHI_TOKEN_OP_REF:-} token status
  local -a lookup=()
  if [ -n "$ref" ]; then
    command -v op >/dev/null 2>&1 || {
      echo "error: FM_MOSHI_TOKEN_OP_REF is set but the 1Password CLI (op) is not installed" >&2
      return 1
    }
    token=$(op read -n -- "$ref" 2>"$TOKEN_ERR") || {
      status=$?
      echo "error: could not read the Moshi token from 1Password (is the vault unlocked?): $(reader_failure op "$status" "$TOKEN_ERR")" >&2
      return 1
    }
  else
    lookup=(-s "${FM_MOSHI_KEYCHAIN_SERVICE:-$KEYCHAIN_SERVICE_DEFAULT}")
    [ -z "${FM_MOSHI_KEYCHAIN_ACCOUNT:-}" ] || lookup+=(-a "$FM_MOSHI_KEYCHAIN_ACCOUNT")
    command -v security >/dev/null 2>&1 || {
      echo "error: no Moshi token source; set FM_MOSHI_TOKEN_OP_REF or install a Keychain" >&2
      return 1
    }
    token=$(security find-generic-password "${lookup[@]}" -w 2>"$TOKEN_ERR") || {
      status=$?
      echo "error: no Moshi token in the Keychain for service '${FM_MOSHI_KEYCHAIN_SERVICE:-$KEYCHAIN_SERVICE_DEFAULT}': $(reader_failure security "$status" "$TOKEN_ERR")" >&2
      return 1
    }
  fi
  # A stored token can carry a trailing newline; a token with embedded newlines
  # is not a Moshi token and must not be smuggled into the request body.
  token="${token%%$'\n'*}"
  token="${token%$'\r'}"
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  [ -n "$token" ] || { echo "error: the stored Moshi token is empty" >&2; return 1; }
  printf '%s' "$token"
}

umask 077
BODY=$(mktemp "${TMPDIR:-/tmp}/fm-moshi-body.XXXXXX") || {
  echo "error: could not create a temporary file in ${TMPDIR:-/tmp} for the response body" >&2
  exit 2
}
CURL_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-moshi-curlerr.XXXXXX") || {
  rm -f -- "$BODY"
  echo "error: could not create a temporary file in ${TMPDIR:-/tmp} for curl's diagnostics" >&2
  exit 2
}
TOKEN_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-moshi-tokenerr.XXXXXX") || {
  rm -f -- "$BODY" "$CURL_ERR"
  echo "error: could not create a temporary file in ${TMPDIR:-/tmp} for the token reader's diagnostics" >&2
  exit 2
}
trap 'rm -f -- "$BODY" "$CURL_ERR" "$TOKEN_ERR"' EXIT
trap 'rm -f -- "$BODY" "$CURL_ERR" "$TOKEN_ERR"; exit 129' HUP
trap 'rm -f -- "$BODY" "$CURL_ERR" "$TOKEN_ERR"; exit 130' INT
trap 'rm -f -- "$BODY" "$CURL_ERR" "$TOKEN_ERR"; exit 143' TERM

TOKEN=$(resolve_token) || exit 2

case "${FM_MOSHI_UNIFIED:-}" in
  1|true|yes) UNIFIED=true ;;
  *) UNIFIED=false ;;
esac

TIMEOUT=${FM_MOSHI_TIMEOUT_SECS:-$TIMEOUT_SECS_DEFAULT}
case "$TIMEOUT" in
  ''|*[!0-9]*) TIMEOUT=$TIMEOUT_SECS_DEFAULT ;;
  *) [ "$TIMEOUT" -gt 0 ] 2>/dev/null || TIMEOUT=$TIMEOUT_SECS_DEFAULT ;;
esac

# The token reaches jq as raw stdin (-Rs), not as --arg, so it stays out of
# jq's argv too; the summary and title are not secret and are escaped by --arg.
CODE=$(printf '%s' "$TOKEN" \
  | jq -Rs \
      --arg title "${FM_MOSHI_TITLE:-$TITLE_DEFAULT}" \
      --arg message "$SUMMARY" \
      --argjson unified "$UNIFIED" \
      '{token: ., title: $title, message: $message}
       + (if $unified then {unified: true} else {} end)' \
  | curl -sS -o "$BODY" -w '%{http_code}' \
      --max-time "$TIMEOUT" \
      -X POST \
      -H 'Content-Type: application/json' \
      --data-binary @- \
      "${FM_MOSHI_ENDPOINT:-$ENDPOINT_DEFAULT}" 2>"$CURL_ERR")
RC=$?

if [ "$RC" -ne 0 ]; then
  # curl's own line is what separates DNS failure, TLS failure and the deadline;
  # -S already asks for it, and the token cannot appear in it because it travels
  # in the request body on stdin, never on curl's command line.
  DETAIL=$(captured_detail "$CURL_ERR")
  if [ -n "$DETAIL" ]; then
    printf 'error: could not reach Moshi (curl exit %s): %s\n' "$RC" "$DETAIL" >&2
  else
    printf 'error: could not reach Moshi (curl exit %s)\n' "$RC" >&2
  fi
  exit 1
fi

case "$CODE" in
  2??) exit 0 ;;
esac
# The response body is Moshi's, not ours, and carries no token; it is the only
# thing that distinguishes a bad token from an outage, so it is worth printing.
printf 'error: Moshi rejected the alert (HTTP %s): %s\n' \
  "$CODE" "$(tr -d '\n' < "$BODY" 2>/dev/null | cut -c1-200)" >&2
exit 1
