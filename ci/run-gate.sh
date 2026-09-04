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

# A signal death is not a contract violation. Reporting it as one sends the
# reader after the wrong bug: a cancelled job, an OOM kill and a broken gate
# look identical unless the adapter names them.
case "$rc" in
    13[0-9]|14[0-3])
        annotate error "gate ${name}: killed by signal $((rc-128)) -- did not complete"
        exit 1
        ;;
esac

# Trusting the exit code alone is the practice this repository argues against,
# and it is what let a crashed gate report a verdict with no artifact behind it.
report="${GATE_REPORT_DIR:-.gate-reports}/${name}.json"
case "$rc" in
    0|1|3)
        if [ ! -s "$report" ]; then
            annotate error "gate ${name}: exited ${rc} but wrote no report -- treating as could-not-run"
            exit 1
        fi
        if command -v jq >/dev/null 2>&1 && ! jq -e . "$report" >/dev/null 2>&1; then
            annotate error "gate ${name}: report is not valid JSON -- treating as could-not-run"
            exit 1
        fi
        ;;
esac

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
