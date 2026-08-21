#!/usr/bin/env bash
# tests/live-e2e-helpers.sh - host-state neutralizers for the opt-in live-e2e
# suites.
#
# Source it from a live-e2e test file, before it drives any firstmate executable:
#   # shellcheck source=tests/live-e2e-helpers.sh
#   . "$ROOT/tests/live-e2e-helpers.sh"
#
# These suites drive real harnesses, real credentials, and real daemons, so they
# build their own labs and deliberately stay outside tests/lib.sh: its temp-root
# registry, fixture builders, and fake-binary shims would stand between them and
# the vendor behavior they exist to measure. That also leaves them outside the
# one place the ordinary suites inherit their environment exemptions from, which
# is why this file exists rather than a copy of the export in each suite.
#
# Retire the free-disk-space guard (bin/fm-disk-space-lib.sh), for the same
# reason tests/lib.sh and tests/herdr-test-safety.sh retire it. The guard covers
# one launch, a fresh crewmate or scout dispatch, so the suites that need this
# are the ones that drive such a dispatch from a lab on the host's real
# filesystem; a suite that only opens a session no longer needs it and no longer
# sources this file. Without it that dispatch would be refused for how full the
# machine happens to be rather than fail at what the suite asserts. Being opt-in
# changes how often that bites, not whether the verdict depends on host state. 0
# is the captain's own off switch, so nothing about the guard's real behavior is
# special-cased.
export FM_DISK_SPACE_MIN_GB=0
