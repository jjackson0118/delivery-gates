#!/usr/bin/env bash
# Scans for credentials with gitleaks.
#
# SCOPE. Two different controls get confused with each other:
#
#   diff     scans the commits this change introduces. Fast, blocking, and it
#            prevents new credentials from landing.
#   history  scans every commit ever. Once it finds something it never goes
#            green again, because you cannot un-commit history. Gating pull
#            requests on history means one historical hit blocks every pull
#            request forever, and the only ways out are a force-push or a
#            blanket allowlist nobody reads. So history runs on a schedule and
#            reports; it does not block. Its output is a rotation list, not a
#            merge decision.
#
# THE SHALLOW-CLONE TRAP. On a pull request, actions/checkout gives a shallow
# merge commit unless fetch-depth is 0. A diff scan then examines one commit,
# finds nothing, and passes -- a gate that measured almost nothing while
# reporting coverage. The gate contract's vacuity rule catches this: the commit
# count is the declared denominator, so a truncated range shows up as a number
# rather than as silence.
#
# REDACTION. --redact is not cosmetic. CI logs on a public repository are world
# readable forever; an unredacted report publishes the credential it just found.
# The record of a detection must not become the leak.
#
# THE SCANNER'S OWN SUPPLY CHAIN. gitleaks is fetched over the network and then
# gets to decide whether this build ships. It is checksum-pinned. Note honestly
# that gitleaks publishes no checksums file for its release archives, so this
# pin was captured by hand from one download: it detects a later substitution,
# it does not verify the original. That is trust on first use, and calling it
# verification would overstate it.

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gate.sh
source "$SCRIPT_DIR/../lib/gate.sh" || {
    printf 'FATAL: cannot load the gate contract from %s\n' "$SCRIPT_DIR/../lib/gate.sh" >&2
    exit 2
}

GITLEAKS_VERSION="8.30.1"
GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

gate_init "secrets" "commits"

TARGET="${1:-.}"
MODE="${GATE_SECRETS_MODE:-diff}"
BASE_REF="${GATE_BASE_REF:-}"

require_cmd git
require_cmd jq
require_cmd curl
require_cmd sha256sum

cd "$TARGET" || gate_error "cannot enter $TARGET"
git rev-parse --git-dir >/dev/null 2>&1 || gate_error "$TARGET is not a git repository"

# --- provision the scanner --------------------------------------------------
BIN_DIR="${GATE_BIN_DIR:-$(mktemp -d)}"
mkdir -p "$BIN_DIR"
if [ ! -x "$BIN_DIR/gitleaks" ]; then
    fetch_verified \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        "$GITLEAKS_SHA256" \
        "$BIN_DIR/gl.tar.gz"
    tar xzf "$BIN_DIR/gl.tar.gz" -C "$BIN_DIR" gitleaks
    chmod +x "$BIN_DIR/gitleaks"
fi
gate_tool "gitleaks $("$BIN_DIR/gitleaks" version 2>/dev/null | tr -d '\n')"

# --- establish the scan range, and count it ---------------------------------
if [ "$MODE" = "history" ]; then
    LOG_OPTS="--all"
    scanned=$(git rev-list --all --count)
else
    if [ -z "$BASE_REF" ]; then
        if git rev-parse HEAD~1 >/dev/null 2>&1; then
            BASE_REF="HEAD~1"
        else
            LOG_OPTS="--all"
            BASE_REF=""
        fi
    fi
    if [ -n "$BASE_REF" ]; then
        git cat-file -e "${BASE_REF}^{commit}" 2>/dev/null \
            || gate_error "base ref '$BASE_REF' not present -- shallow clone? needs fetch-depth: 0"
        LOG_OPTS="${BASE_REF}..HEAD"
        scanned=$(git rev-list --count "${BASE_REF}..HEAD")
    else
        scanned=$(git rev-list --all --count)
    fi
fi

REPORT="$(mktemp)"
SCANLOG="$(mktemp)"; gate_cleanup "$SCANLOG"
gate_expect_failure_begin
"$BIN_DIR/gitleaks" git \
    --redact \
    --no-banner \
    --exit-code 1 \
    --log-opts="$LOG_OPTS" \
    --report-format json \
    --report-path "$REPORT" \
    . 2>"$SCANLOG"
rc=$?
gate_expect_failure_end

# gitleaks: 0 = clean, 1 = leaks found, anything else = it did not run properly
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    gate_error "gitleaks exited $rc -- the scanner failed to run, which is not a pass"
fi

if [ -s "$REPORT" ]; then
    # Via gate_lines, not `< <(...)`. Process substitution runs the producer in
    # a subshell whose exit status the parent discards: a jq failure here used
    # to drop every finding on the floor and let the gate report PASS while
    # holding detected secrets.
    _rules=()
    gate_lines _rules bash -c 'jq -r ".[].RuleID" "$1" | sort -u' _ "$REPORT"
    for rule in "${_rules[@]:-}"; do
        if [ -n "$rule" ]; then gate_finding "$rule"; fi
    done
fi
rm -f "$REPORT"

# The denominator comes from what gitleaks reports having scanned, not from a
# separate `git rev-list` that never sees LOG_OPTS. Computed independently they
# can disagree silently: narrowing the range to a single commit left the count
# reporting ten, so the gate claimed ten commits examined having examined one.
actually_scanned="$(grep -oE '[0-9]+ commits scanned' "$SCANLOG" | grep -oE '^[0-9]+' | tail -1)"
if [ -z "$actually_scanned" ]; then
    gate_error "gitleaks did not report how many commits it scanned -- the denominator cannot be established from the scanner's own work"
fi
# Deliberately not asserted equal to the requested range. gitleaks scans diffs,
# so it legitimately reports fewer than `git rev-list` counts whenever the range
# contains an empty commit -- this fixture has one, and a strict equality check
# failed on it immediately. The scanner's own count is the honest denominator
# because it is the work; the declared floor in fixtures/*.floors is what
# catches a range that has been quietly narrowed.
gate_note "$(printf 'mode=%s range=%s requested=%s scanned=%s' "$MODE" "$LOG_OPTS" "$scanned" "$actually_scanned")"
gate_scanned "$actually_scanned"
gate_finish
