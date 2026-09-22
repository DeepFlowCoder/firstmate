#!/usr/bin/env bash
# fm-install-bash.sh - install CI's pinned bash, the interpreter floor the
# behavior suites run under.
#
# WHY THIS EXISTS (do not remove without reading docs/verification/ci-bash-floor.md):
# bash 5.2 can fail to parse a signal trap's body when the signal is delivered
# while the shell is inside a sourced function performing a command
# substitution. The shell prints a parse error and CARRIES ON rather than
# dying, so the handler never runs and the signal is swallowed. A watcher that
# swallows its SIGTERM keeps the test step's output pipe open, and the lane goes
# silent until its cap cancels it. Measured on the CI interpreter: bash 5.2.21
# produced the parse error in 5 of 5 runs of 1500 delivered signals; bash 5.3.0
# and 5.3.9 produced none in 7500 and 6000. Raising the floor removes the race
# at its source. Evidence, exact commands and output: docs/verification/ci-bash-floor.md.
#
# Ubuntu runners still ship bash 5.2, so the floor is installed rather than
# assumed. Downloads the official GNU release tarball, verifies its SHA-256 pin,
# builds it, and installs the binary into the destination directory. Re-running
# with a destination that already holds a binary at or above the floor is a
# no-op, so the step is cheap behind a warm cache.
#
# Usage:
#   fm-install-bash.sh <destination-directory>
#   fm-install-bash.sh --required-version   # print the floor and exit
set -eu

# Single owner of the CI interpreter floor. The workflow lanes, the destination
# short-circuit below, and tests/fm-ci-bash-floor.test.sh all read it from here.
VERSION=5.3
# SHA-256 of the official GNU release tarball
# (https://ftp.gnu.org/gnu/bash/bash-${VERSION}.tar.gz).
SHA256=0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba

die() {
  printf 'fm-install-bash.sh: %s\n' "$*" >&2
  exit 1
}

if [ "${1-}" = --required-version ]; then
  printf '%s\n' "$VERSION"
  exit 0
fi

DESTINATION=${1:?usage: fm-install-bash.sh <destination-directory>}

# fm_bash_meets_floor <bash-binary> is 0 when that binary is at or above
# $VERSION. Compares major then minor numerically, never as strings, so 5.10
# would not read as older than 5.3.
fm_bash_meets_floor() {  # <bash-binary>
  local candidate=$1 reported major minor floor_major floor_minor
  [ -x "$candidate" ] || return 1
  # shellcheck disable=SC2016 # BASH_VERSINFO must expand in the candidate, not here.
  reported=$("$candidate" -c 'printf "%s.%s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null) || return 1
  major=${reported%%.*}
  minor=${reported#*.}
  floor_major=${VERSION%%.*}
  floor_minor=${VERSION#*.}
  case "$major$minor$floor_major$floor_minor" in
    *[!0-9]*) return 1 ;;
  esac
  [ "$major" -gt "$floor_major" ] && return 0
  [ "$major" -eq "$floor_major" ] && [ "$minor" -ge "$floor_minor" ]
}

if fm_bash_meets_floor "$DESTINATION/bash"; then
  "$DESTINATION/bash" --version | head -1
  exit 0
fi

command -v make >/dev/null 2>&1 || die "need make to build bash $VERSION"
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
  || die "need a C compiler to build bash $VERSION"

ARCHIVE="bash-${VERSION}.tar.gz"
URL="https://ftp.gnu.org/gnu/bash/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-bash.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-bash.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-bash.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the bash archive"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-bash.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ARCHIVE" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}

tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
(
  cd "$TMP/bash-${VERSION}"
  ./configure --without-bash-malloc >"$TMP/configure.log" 2>&1 \
    || { tail -20 "$TMP/configure.log" >&2; exit 1; }
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" >"$TMP/make.log" 2>&1 \
    || { tail -20 "$TMP/make.log" >&2; exit 1; }
) || die "building bash $VERSION failed"

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/bash-${VERSION}/bash" "$DESTINATION/bash"
fm_bash_meets_floor "$DESTINATION/bash" \
  || die "installed bash does not meet the $VERSION floor"
"$DESTINATION/bash" --version | head -1
