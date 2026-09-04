#!/usr/bin/env bash
# Translates the gate contract into an orchestrator's semantics.
#
# Gates speak four states. GitHub Actions speaks two: zero, or not zero. Jenkins
# is the same. Without a translation layer, exit 3 (not applicable) fails the
# build -- so the code added to distinguish "did not apply" from "failed" would
# cause precisely the failure it exists to prevent. That is not hypothetical:
# this adapter was written after confirming a consumer with no shell files would
# have had its entire pipeline fail on a gate that correctly declined to run.
#
# The adapter is where orchestrator knowledge lives, and it is the only place.
# A second orchestrator needs a second adapter, not a second set of gates.
#
#   usage: ci/run-gate.sh <path-to-gate> [args...]
set -uo pipefail

gate="${1:?usage: run-gate.sh <gate> [args...]}"
shift
name="$(basename "$gate" .sh)"

"$gate" "$@"
rc=$?

annotate() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::%s::%s\n' "$1" "$2"; else printf '[%s] %s\n' "$1" "$2"; fi
}

case "$rc" in
    0)
        annotate notice "gate ${name}: pass"
        exit 0
        ;;
    1)
        annotate error "gate ${name}: found what it looks for -- see the gate report artifact"
        exit 1
        ;;
    2)
        # Distinct message from 1 on purpose. A gate that could not run has not
        # cleared anything, and reporting it as a normal failure loses the
        # difference between "your code is wrong" and "the check is broken".
        annotate error "gate ${name}: COULD NOT RUN -- this is a broken check, not a finding"
        exit 1
        ;;
    3)
        annotate notice "gate ${name}: not applicable to this repository -- nothing was checked"
        exit 0
        ;;
    *)
        annotate error "gate ${name}: undefined exit ${rc} -- the gate violated its own contract"
        exit 1
        ;;
esac
