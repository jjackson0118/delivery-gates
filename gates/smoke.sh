#!/usr/bin/env bash
# Verifies a deployed service actually serves, and serves the build that was
# deployed.
#
# A deploy step's exit code says the commands ran. It does not say the service
# came up, and it does not say the service that came up is the one you shipped.
# Those were both observed failing during a manual deploy rehearsal on this
# project: a release whose symlink flipped and whose unit restarted, reporting a
# build identity from the previous release, from a deploy that returned 0.
#
# The exit codes carry their usual meanings, and the 1/2 split carries the
# weight here more than anywhere else in this repository, because the caller
# does different things with them:
#
#   1  the service answered, and the answer was wrong  -> roll back
#   2  the gate could not find out                     -> do NOT claim the
#                                                         deploy is good, and
#                                                         do not claim it is bad
#
# A caller that treats "non-zero" as "roll back" will roll back a healthy
# release because curl was missing, and a caller that treats non-zero as
# "failed" will report a change failure that never happened.
#
# ENVIRONMENT
#   SMOKE_URL          base URL of the deployed service   (required)
#   SMOKE_EXPECT_SHA   build identity the deploy shipped  (optional but see below)
#   SMOKE_TIMEOUT      seconds per request                (default 5)
#   SMOKE_SETTLE       seconds to wait for readiness      (default 60)

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gate.sh
source "$SCRIPT_DIR/../lib/gate.sh" || {
    printf 'FATAL: cannot load the gate contract from %s\n' "$SCRIPT_DIR/../lib/gate.sh" >&2
    exit 2
}

gate_init "smoke" "checks against the deployed service"
gate_tool "curl"

require_cmd curl

BASE="${SMOKE_URL:-}"
TIMEOUT="${SMOKE_TIMEOUT:-5}"
SETTLE="${SMOKE_SETTLE:-60}"
EXPECT_SHA="${SMOKE_EXPECT_SHA:-}"

# No URL means no deployment to smoke, which is exit 3 (not applicable), not
# exit 2 (could not run). The distinction is the one the contract exists for:
# a repository that builds but does not deploy has not suffered a broken gate.
#
# This is safe only because a fixture must DECLARE smoke as n/a in its floors
# file. A gate that decides it is out of scope maps to success for the
# orchestrator, so without the declaration, forgetting to set SMOKE_URL would
# quietly turn the smoke stage into a no-op that reports green -- which is this
# repository's central complaint, arrived at through its own new gate.
[ -n "$BASE" ] || gate_not_applicable "SMOKE_URL is not set: nothing is deployed to smoke"
BASE="${BASE%/}"
# Each invocation owns its response file, including parallel smoke probes.
BODY_FILE=$(mktemp)
gate_cleanup "$BODY_FILE"

checks=0
report() { printf '   %s\n' "$1" >&2; }

# curl's exit code distinguishes "I could not ask" from "it answered badly", and
# that distinction is the whole 1-versus-2 decision. Kept in one place so the
# mapping is stated once rather than inferred at four call sites.
#   6  DNS failure          -> could not run: the target name is misconfigured
#   7  connection refused   -> a FINDING: nothing is listening where the service
#                              should be, which is exactly what smoke looks for
#   28 timeout              -> a FINDING: a service too slow to answer is a
#                              service the user cannot use
ask() { # ask <path> ; echoes "<curl_rc> <http_code> <body>"
    local path="$1" out rc
    # `|| rc=$?` on purpose. The contract library runs under `set -eE` with an
    # ERR trap that turns any failing command into "the gate could not run", and
    # a bare curl inheriting that made connection-refused exit 2 -- which
    # contradicted the mapping documented at the top of this file, and meant a
    # deployment that never came up would be reported as an unrunnable gate
    # rather than as the broken deploy it is.
    #
    # Caught by the fault sweep, not by reading: the comment said 1 and the code
    # did 2, and both were mine.
    rc=0
    out=$(curl -sS -m "$TIMEOUT" -o "$BODY_FILE" -w '%{http_code}' "$BASE$path" 2>/dev/null) || rc=$?
    printf '%s %s %s' "$rc" "${out:-000}" "$(head -c 400 "$BODY_FILE" 2>/dev/null || true)"
}

# --- 1. the service becomes ready, within a stated budget ------------------
# Polled rather than asked once, because a deploy that restarts the process
# always loses a race with an immediate probe -- and a gate that flakes gets
# deleted, which is worse than a gate that is slightly slow.
ready=0
waited=0
while [ "$waited" -lt "$SETTLE" ]; do
    resp=$(ask /actuator/health/readiness)
    rc="${resp%% *}"; rest="${resp#* }"; code="${rest%% *}"
    if [ "$rc" = "6" ]; then
        gate_error "cannot resolve the host in SMOKE_URL ($BASE) -- misconfigured, not unhealthy"
    fi
    if [ "$code" = "200" ]; then ready=1; break; fi
    waited=$(( waited + 2 ))
    sleep 2
done

checks=$(( checks + 1 ))
if [ "$ready" -ne 1 ]; then
    gate_finding "not-ready"
    report "service did not become ready within ${SETTLE}s (last curl rc=$rc http=$code)"
    # Deliberately continues. The remaining checks still produce evidence about
    # WHY, and a gate that stops at the first finding tells the operator one
    # thing when it knows three.
else
    gate_note "ready after ${waited}s"
fi

# --- 2. the build that answers is the build that was deployed --------------
# The check this gate exists for. A rehearsal produced a service running new
# code and reporting the previous release's identity, from a deploy that
# reported success -- because the identity came from a file the deploy failed to
# rewrite, and nothing compared the two.
#
# Skipped with a stated reason rather than silently when no expectation was
# passed: a gate that quietly checks less is the failure this repository is
# about. The absence still costs a claim in the denominator.
checks=$(( checks + 1 ))
if [ -z "$EXPECT_SHA" ]; then
    gate_note "SMOKE_EXPECT_SHA unset: served build identity was NOT compared to anything"
else
    resp=$(ask /actuator/info)
    rc="${resp%% *}"; rest="${resp#* }"; code="${rest%% *}"; body="${rest#* }"
    if [ "$code" != "200" ]; then
        gate_finding "build-identity-unavailable"
        report "/actuator/info answered $code (curl rc=$rc); cannot confirm which build is serving"
    elif printf '%s' "$body" | grep -qF "$EXPECT_SHA"; then
        gate_note "serving $EXPECT_SHA, as deployed"
    else
        gate_finding "wrong-build-serving"
        report "deployed $EXPECT_SHA but /actuator/info reports: $body"
    fi
fi

# --- 3. a real product response, not just a health endpoint ----------------
# Health endpoints are written to return 200. The point of smoke is to exercise
# the thing the service is for, through the same listener a consumer uses -- so
# SMOKE_URL should be the address consumers reach, not a loopback the operator
# happens to have handy.
checks=$(( checks + 1 ))
resp=$(ask "/api/v1/services/smoke-probe-$$/report?window=P1D")
rc="${resp%% *}"; rest="${resp#* }"; code="${rest%% *}"; body="${rest#* }"
if [ "$code" != "200" ]; then
    gate_finding "product-endpoint-failed"
    report "report endpoint answered $code (curl rc=$rc)"
elif ! printf '%s' "$body" | grep -q 'UNOBSERVED'; then
    # A service with no events for a random name must say UNOBSERVED. If it
    # says anything else -- a zero, an OK, an empty body -- the deployment is
    # serving something that violates the contract it exists to enforce.
    gate_finding "contract-violated"
    report "report for an unknown service did not read UNOBSERVED: $body"
else
    gate_note "report endpoint serves the signal contract"
fi

rm -f "$BODY_FILE"
gate_note "performed $checks checks against $BASE"
gate_scanned "$checks"
gate_finish
