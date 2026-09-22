#!/usr/bin/env bash
# fm-captain-hold-lib.sh - the contract bin/fm-captain-hold.sh's keyed-answer
# intake shares with the caller that relays its refusal.
#
# The intake refuses any caller that is not this home's firstmate ("WHO MAY
# WRITE A RESOLUTION" in bin/fm-captain-hold.sh). A caller that pipes keyed
# answers into it has to tell that refusal apart from an ordinary intake
# failure, because the ordinary close-failure wording names the very command the
# guard just refused and would send a refused worker straight back into it.
#
# What separates them is the exit code below, so it has to have ONE definition.
# The intake and its relay are different files: a literal copied into each would
# keep matching only while both are edited together, and the miss is silent -
# the refused caller reads the ordinary failure text again, which is exactly the
# loop the relay exists to break. bin/fm-gate-refuse-lib.sh and
# bin/fm-lease-lib.sh declare their own refusal codes once for the same reason.
#
# Sourced by bin/fm-captain-hold.sh, which exits with it, and by bin/fm-send.sh,
# which tests for it. This library depends on nothing, so sourcing it can never
# cycle back into either consumer. No side effects on source, set -u / set -e
# safe.

# The exit code every captain-answer resolution refusal uses, distinct from the
# intake's ordinary failures so a caller or test can recognize "the crewmate
# guard fired" rather than a usage error or a skipped key.
# shellcheck disable=SC2034 # Read by the intake and its relay, not by this lib.
FM_CAPTAIN_ANSWER_REFUSE_EXIT=4
