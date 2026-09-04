#!/usr/bin/env bash
# The gate contract.
#
# Sourced by every gate in gates/. Defines the exit-code and reporting contract
# that lets a gate be invoked identically from GitHub Actions, from Jenkins, and
# from the fault harness -- and that lets the harness tell the difference
# between a gate that caught something and a gate that fell over.
#
# EXIT CODES
#   0  pass            -- the gate ran, looked at something, and found nothing
#   1  fail            -- the gate ran and found the thing it looks for
#   2  error           -- the gate could not run, or ran and looked at nothing
#   3  not applicable  -- the gate does not apply to this repository
#
# The 1/2 split is the point. A caller that accepts "non-zero" as proof a gate
# fired will also accept a gate that crashed on startup, which proves nothing
# and is indistinguishable from coverage.
#
# 3 exists because 2 was being used for two different things. A shell linter
# pointed at a repository with no shell files has not failed and has not found
# anything -- it does not apply, and that is a third answer. Collapsing it into
# "error" makes a correct outcome look like a broken gate; collapsing it into
# "pass" is worse, because it claims coverage that was never possible.
#
# The distinction is borrowed from a service-admission contract on another
# system, where the same conflation caused a real incident: a supervisor's
# health loop killed and restarted a service nine times overnight on nodes
# where its prerequisites could never be satisfied. The service was not
# unhealthy. It was not applicable, and nothing could express that.
#
# VACUITY
#   Every gate must declare what it examined, via gate_scanned. A gate that
#   examined nothing exits 2, never 0. An empty scan and a clean scan produce
#   identical output from most tools; treating them the same is how a check
#   reports PASS for weeks after its input silently disappeared.
#
# REPORT
#   Each gate writes ${GATE_REPORT_DIR:-.gate-reports}/<name>.json describing
#   status, findings, matched rule ids, and the scan denominator. Callers assert
#   against that file, never against log text. Grepping logs for "failed" is the
#   same class of mistake as trusting an exit code alone.

set -euo pipefail

GATE_REPORT_DIR="${GATE_REPORT_DIR:-.gate-reports}"

_GATE_NAME=""
_GATE_UNIT=""
_GATE_TOOL="n/a"
_GATE_SCANNED="unset"
_GATE_FINDINGS=0
_GATE_RULES=()
_GATE_START=0
_GATE_NOTE=""

_json_escape() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

# gate_init <name> <scanned-unit>
gate_init() {
    _GATE_NAME="$1"
    _GATE_UNIT="$2"
    _GATE_START=$(date +%s)
    mkdir -p "$GATE_REPORT_DIR"
    printf ':: gate %s starting\n' "$_GATE_NAME" >&2
}

# gate_tool <description>  -- records which tool and version did the work
gate_tool() { _GATE_TOOL="$1"; }

# gate_scanned <n>  -- the denominator. Mandatory.
gate_scanned() { _GATE_SCANNED="$1"; }

# gate_finding <rule-id>  -- one finding, attributed to a rule
gate_finding() {
    _GATE_FINDINGS=$(( _GATE_FINDINGS + 1 ))
    _GATE_RULES+=("$1")
}

gate_note() { _GATE_NOTE="$1"; }

_gate_write_report() {
    local status="$1" exit_code="$2"
    local rules_json="" r
    for r in "${_GATE_RULES[@]:-}"; do
        [ -z "$r" ] && continue
        [ -n "$rules_json" ] && rules_json+=","
        rules_json+="\"$(_json_escape "$r")\""
    done
    local scanned_json="$_GATE_SCANNED"
    [ "$scanned_json" = "unset" ] && scanned_json="null"
    cat > "$GATE_REPORT_DIR/$_GATE_NAME.json" <<JSONEOF
{
  "gate": "$(_json_escape "$_GATE_NAME")",
  "status": "$status",
  "exit_code": $exit_code,
  "findings": $_GATE_FINDINGS,
  "rules": [$rules_json],
  "scanned": $scanned_json,
  "scanned_unit": "$(_json_escape "$_GATE_UNIT")",
  "tool": "$(_json_escape "$_GATE_TOOL")",
  "duration_s": $(( $(date +%s) - _GATE_START )),
  "note": "$(_json_escape "$_GATE_NOTE")"
}
JSONEOF
}

# gate_not_applicable <reason>  -- this gate has no work here. Exits 3.
#
# Distinct from a pass: the caller learns that nothing was checked and can
# decide what that means, rather than being handed a green result.
gate_not_applicable() {
    gate_note "$1"
    _gate_write_report "not_applicable" 3
    printf ':: gate %s NOT APPLICABLE: %s\n' "$_GATE_NAME" "$1" >&2
    exit 3
}

# gate_error <message>  -- the gate could not do its job. Exits 2.
gate_error() {
    gate_note "$1"
    _gate_write_report "error" 2
    printf ':: gate %s ERROR: %s\n' "$_GATE_NAME" "$1" >&2
    exit 2
}

# gate_finish  -- decide and exit. Enforces the vacuity rule.
gate_finish() {
    if [ "$_GATE_SCANNED" = "unset" ]; then
        gate_error "gate did not declare what it scanned"
    fi
    if [ "$_GATE_SCANNED" -eq 0 ]; then
        gate_error "gate scanned 0 ${_GATE_UNIT} -- an empty scan is not a pass"
    fi
    if [ "$_GATE_FINDINGS" -gt 0 ]; then
        _gate_write_report "fail" 1
        printf ':: gate %s FAIL -- %d finding(s) over %s %s\n' \
            "$_GATE_NAME" "$_GATE_FINDINGS" "$_GATE_SCANNED" "$_GATE_UNIT" >&2
        exit 1
    fi
    _gate_write_report "pass" 0
    printf ':: gate %s PASS -- 0 findings over %s %s\n' \
        "$_GATE_NAME" "$_GATE_SCANNED" "$_GATE_UNIT" >&2
    exit 0
}

# require_cmd <command> [hint]  -- a missing tool is an error, never a pass
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || gate_error "required command not found: $1${2:+ ($2)}"
}

# fetch_verified <url> <sha256> <dest>
#
# A gate that fetches its own scanner over the network without verifying it has
# outsourced its verdict to whoever controls that URL.
fetch_verified() {
    local url="$1" want="$2" dest="$3"
    curl -sSfL --retry 3 -o "$dest" "$url" || gate_error "download failed: $url"
    local got
    got=$(sha256sum "$dest" | cut -d' ' -f1)
    [ "$got" = "$want" ] || gate_error "checksum mismatch for $url (want $want, got $got)"
}
