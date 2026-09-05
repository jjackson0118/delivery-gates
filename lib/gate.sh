#!/usr/bin/env bash
# The gate contract.
#
# Sourced by every gate in gates/. Defines the exit-code and reporting contract
# that lets a gate be invoked identically from GitHub Actions, from Jenkins, and
# from the fault harness -- and that lets the caller tell the difference between
# a gate that caught something and a gate that fell over.
#
# EXIT CODES
#   0  pass            -- ran, examined something, found nothing
#   1  fail            -- ran and found the thing it looks for
#   2  error           -- could not run, or ran and examined nothing
#   3  not applicable  -- does not apply to this repository
#
# The 1/2 split is the point. A caller that accepts "non-zero" as proof a gate
# fired will also accept a gate that crashed on startup, which proves nothing
# and is indistinguishable from coverage.
#
# 3 exists because 2 was doing two jobs. A shell linter pointed at a Java
# repository has not failed and has not found anything -- it does not apply.
# Collapsing that into "error" makes a correct outcome look broken; collapsing
# it into "pass" is worse, because it claims coverage that was never possible.
# The distinction is borrowed from a service-admission contract on another
# system, where the same conflation had a supervisor kill and restart a service
# nine times overnight on nodes where its prerequisites could never be met.
#
# VACUITY
#   Every gate must declare what it examined via gate_scanned, with an integer.
#   A gate that examined nothing exits 2, never 0. An empty scan and a clean
#   scan produce identical output from most tools; treating them the same is how
#   a check reports PASS for weeks after its input silently disappeared.
#
# DEFENCE IN DEPTH
#   A post-merge review found six ways to reach a wrong verdict, every one of
#   them invisible to the fault harness. The layering below exists because each
#   layer was observed failing:
#
#     ERR trap      unhandled command failure -> error, not the raw status
#     EXIT trap     everything ERR cannot see: `set -u` violations, syntax
#                   errors, a failure inside gate_error itself, signals
#     abort file    an abort inside a subshell, whose exit status the parent
#                   discards. Without this, a broken `find` feeding a
#                   `mapfile < <(...)` produced a PASS over a truncated result
#                   set -- in the secret scanner, silently dropping findings.
#     write probe   an unwritable report dir was only discovered at write time,
#                   turning every verdict into exit 1
#     arg checks    gate_scanned "" or "abc" fell through the numeric test and
#                   passed
#
#   None of these were reachable through the fault corpus, which injects source
#   defects into fixtures. Faults now exist for each; see faults/contract-*.

if [ -n "${_GATE_LIB_LOADED:-}" ]; then return 0; fi
_GATE_LIB_LOADED=1

# -E so the ERR trap is inherited by functions and subshells.
set -eEuo pipefail

GATE_REPORT_DIR="${GATE_REPORT_DIR:-.gate-reports}"
GATE_TIMEOUT="${GATE_TIMEOUT:-900}"

_GATE_NAME=""
_GATE_UNIT=""
_GATE_TOOL="n/a"
_GATE_SCANNED="unset"
_GATE_FINDINGS=0
_GATE_RULES=()
_GATE_START=0
_GATE_NOTE=""
_GATE_FINISHED=0
_GATE_EXPECT_DEPTH=0
_GATE_ABORT_FILE=""
_GATE_CLEANUP=()

# --------------------------------------------------------------------------
# JSON
# --------------------------------------------------------------------------

# Escapes for JSON, including the C0 control characters. Rule ids and notes are
# attacker-influenced -- they come from the repository under test -- and a CRLF
# in a scanned file was enough to emit a report no parser would accept, which
# makes every downstream assertion fail open.
_json_escape() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
    s=${s//$'\b'/\\b}; s=${s//$'\f'/\\f}
    local out="" i c
    for (( i=0; i<${#s}; i++ )); do
        c=${s:i:1}
        if [[ $c < $'\x20' ]]; then printf -v c '\\u%04x' "'$c"; fi
        out+=$c
    done
    printf '%s' "$out"
}

# --------------------------------------------------------------------------
# Failure handling
# --------------------------------------------------------------------------

_gate_mark_abort() {
    if [ -n "$_GATE_ABORT_FILE" ]; then : > "$_GATE_ABORT_FILE" 2>/dev/null || true; fi
}

# Any command failing outside an explicit check.
_gate_on_err() {
    local rc=$1 line=$2
    # Subshells inherit this trap under set -E. Without the guard it fires in
    # the subshell and again in the parent, writing the report twice and leaving
    # the less informative of the two messages.
    if [ "${BASHPID:-$$}" != "$$" ]; then exit "$rc"; fi
    trap - ERR
    _gate_mark_abort
    gate_error "unexpected failure at line $line (exit $rc) -- the gate did not complete"
}

# The last net. Installed at source time, because ERR cannot see a `set -u`
# violation, a syntax error, a signal, or a failure inside gate_error -- all of
# which otherwise leave the process exiting with a raw status and no report.
_gate_on_exit() {
    local rc=$?
    if [ "${BASHPID:-$$}" != "$$" ]; then exit "$rc"; fi
    if [ "$_GATE_FINISHED" = 1 ]; then _gate_run_cleanup; exit "$rc"; fi
    trap - ERR EXIT
    _gate_run_cleanup
    _GATE_NOTE="abnormal termination (raw exit $rc), normalised to 2"
    _gate_write_report "error" 2 2>/dev/null || true
    printf ':: gate %s ERROR: abnormal termination (raw exit %s) -- normalised to 2\n' \
        "${_GATE_NAME:-?}" "$rc" >&2
    exit 2
}
trap _gate_on_exit EXIT

_gate_run_cleanup() {
    local f
    for f in "${_GATE_CLEANUP[@]:-}"; do
        if [ -n "$f" ]; then rm -rf -- "$f" 2>/dev/null || true; fi
    done
    _GATE_CLEANUP=()
}

# gate_cleanup <path>  -- removed however the gate terminates
gate_cleanup() { _GATE_CLEANUP+=("$1"); }

# --------------------------------------------------------------------------
# Lifecycle
# --------------------------------------------------------------------------

# gate_init <name> <scanned-unit>
gate_init() {
    _GATE_NAME="$1"
    _GATE_UNIT="$2"
    _GATE_START=$(date +%s)

    mkdir -p "$GATE_REPORT_DIR" || {
        printf ':: gate %s ERROR: cannot create report dir %s\n' "$_GATE_NAME" "$GATE_REPORT_DIR" >&2
        _GATE_FINISHED=1; exit 2
    }
    # CDPATH= and -P: cd consults CDPATH for a relative path and prints the
    # resolved directory to stdout, which the command substitution would capture
    # -- turning GATE_REPORT_DIR into a two-line string and breaking every write.
    GATE_REPORT_DIR="$(CDPATH='' cd -P -- "$GATE_REPORT_DIR" && pwd)" || {
        printf ':: gate %s ERROR: cannot resolve report dir\n' "$_GATE_NAME" >&2
        _GATE_FINISHED=1; exit 2
    }

    # Prove writability now. mkdir -p succeeds on an existing read-only
    # directory, so unwritability was previously discovered at write time --
    # after gate_error had disarmed the trap, which made every verdict exit 1.
    if ! : > "$GATE_REPORT_DIR/.$_GATE_NAME.probe" 2>/dev/null; then
        printf ':: gate %s ERROR: report dir %s is not writable\n' "$_GATE_NAME" "$GATE_REPORT_DIR" >&2
        _GATE_FINISHED=1; exit 2
    fi
    rm -f "$GATE_REPORT_DIR/.$_GATE_NAME.probe"

    # A crashed run must not leave the previous run's verdict behind for a
    # caller to read as current.
    rm -f "$GATE_REPORT_DIR/$_GATE_NAME.json"
    _GATE_ABORT_FILE="$GATE_REPORT_DIR/.$_GATE_NAME.aborted"
    rm -f "$_GATE_ABORT_FILE"

    trap '_gate_on_err $? $LINENO' ERR
    printf ':: gate %s starting\n' "$_GATE_NAME" >&2
}

gate_tool() { _GATE_TOOL="$1"; }
gate_note() { _GATE_NOTE="$1"; }

# gate_scanned <n>  -- the denominator. Must be a non-negative integer.
#
# Validated here rather than in gate_finish. The comparison there lives in an
# `if` condition, where a failure is invisible to both errexit and the ERR trap:
# gate_scanned "" or "abc" made the test error to stderr, skipped the body, and
# passed the gate. An empty denominator is the exact case the vacuity rule
# exists for, and it was the one case that slipped through it.
gate_scanned() {
    case "${1:-}" in
        ''|*[!0-9]*)
            gate_error "gate_scanned given a non-integer denominator: '${1:-}'" ;;
    esac
    _GATE_SCANNED=$(( 10#$1 ))
}

# gate_finding <rule-id>
gate_finding() {
    _GATE_FINDINGS=$(( _GATE_FINDINGS + 1 ))
    _GATE_RULES+=("$1")
}

_gate_write_report() {
    local status="$1" exit_code="$2"
    local rules_json="" r
    for r in "${_GATE_RULES[@]:-}"; do
        if [ -z "$r" ]; then continue; fi
        if [ -n "$rules_json" ]; then rules_json+=","; fi
        rules_json+="\"$(_json_escape "$r")\""
    done
    local scanned_json="$_GATE_SCANNED"
    if [ "$scanned_json" = "unset" ]; then scanned_json="null"; fi
    local dest="$GATE_REPORT_DIR/$_GATE_NAME.json"
    local tmp="$dest.partial.$$"
    # Written to a temp file and moved into place, so a full disk or a killed
    # process cannot leave a truncated report that still parses as present.
    cat > "$tmp" <<JSONEOF
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
    mv -f "$tmp" "$dest"
}

# gate_error <message>  -- the gate could not do its job. Exits 2.
gate_error() {
    trap - ERR
    _gate_mark_abort
    gate_note "$1"
    _GATE_FINISHED=1
    # Non-fatal: if the report cannot be written there is nothing left to catch
    # a failure here, and the exit code matters more than the artifact.
    _gate_write_report "error" 2 2>/dev/null \
        || printf ':: gate %s ERROR: report write failed\n' "$_GATE_NAME" >&2
    printf ':: gate %s ERROR: %s\n' "$_GATE_NAME" "$1" >&2
    exit 2
}

# gate_not_applicable <reason>  -- no work here. Exits 3.
gate_not_applicable() {
    gate_note "$1"
    _GATE_FINISHED=1
    _gate_write_report "not_applicable" 3
    printf ':: gate %s NOT APPLICABLE: %s\n' "$_GATE_NAME" "$1" >&2
    exit 3
}

# gate_finish  -- decide and exit.
gate_finish() {
    if [ "$_GATE_EXPECT_DEPTH" -ne 0 ]; then
        gate_error "gate_expect_failure region left open -- errexit and the ERR trap are still suspended"
    fi
    # A subshell that aborted took its exit status with it. Without this the
    # parent carries on over a truncated result set and reports a pass.
    if [ -n "$_GATE_ABORT_FILE" ] && [ -e "$_GATE_ABORT_FILE" ]; then
        gate_error "a subprocess aborted -- the scan is incomplete and its result cannot be trusted"
    fi
    if [ "$_GATE_SCANNED" = "unset" ]; then
        gate_error "gate did not declare what it scanned"
    fi
    if [ "$_GATE_SCANNED" -eq 0 ]; then
        gate_error "gate scanned 0 ${_GATE_UNIT} -- an empty scan is not a pass"
    fi
    if [ "$_GATE_FINDINGS" -gt 0 ]; then
        _GATE_FINISHED=1
        _gate_write_report "fail" 1
        printf ':: gate %s FAIL -- %d finding(s) over %s %s\n' \
            "$_GATE_NAME" "$_GATE_FINDINGS" "$_GATE_SCANNED" "$_GATE_UNIT" >&2
        exit 1
    fi
    _GATE_FINISHED=1
    _gate_write_report "pass" 0
    printf ':: gate %s PASS -- 0 findings over %s %s\n' \
        "$_GATE_NAME" "$_GATE_SCANNED" "$_GATE_UNIT" >&2
    exit 0
}

# --------------------------------------------------------------------------
# Regions where a non-zero exit is data
# --------------------------------------------------------------------------
#
# A scanner reporting findings exits non-zero, and that is data rather than an
# error. `set +e` alone does not help: the ERR trap fires regardless of errexit,
# because errexit controls whether the shell exits, not whether the trap runs.
#
# Not nestable, deliberately. The first version re-armed unconditionally, so an
# inner `end` left the outer region unprotected; and a forgotten `end` disabled
# errexit for the remainder of the gate, which still reached a clean PASS with
# unhandled failures behind it.
gate_expect_failure_begin() {
    if [ "$_GATE_EXPECT_DEPTH" -ne 0 ]; then
        gate_error "gate_expect_failure regions cannot nest"
    fi
    _GATE_EXPECT_DEPTH=1
    trap - ERR
    set +e
}

gate_expect_failure_end() {
    if [ "$_GATE_EXPECT_DEPTH" -ne 1 ]; then
        gate_error "gate_expect_failure_end without a matching begin"
    fi
    _GATE_EXPECT_DEPTH=0
    set -e
    trap '_gate_on_err $? $LINENO' ERR
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# require_cmd <command> [hint]  -- a missing tool is an error, never a pass
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || gate_error "required command not found: $1${2:+ ($2)}"
}

# gate_capture <output-file> <cmd...>
#
# Runs a command whose non-zero exit is expected, with a timeout, and returns
# its status in GATE_LAST_RC. Every scanner call goes through this: an unbounded
# scanner is indistinguishable from a hung one, and produces no report either way.
gate_capture() {
    local out="$1"; shift
    gate_expect_failure_begin
    timeout "$GATE_TIMEOUT" "$@" > "$out" 2>/dev/null
    GATE_LAST_RC=$?
    gate_expect_failure_end
    if [ "$GATE_LAST_RC" -eq 124 ]; then
        gate_error "timed out after ${GATE_TIMEOUT}s: $*"
    fi
}

# gate_lines <array-name> <cmd...>
#
# Fills an array from a command's stdout, via a temp file rather than process
# substitution. `mapfile < <(cmd)` runs cmd in a subshell whose exit status is
# discarded: a failing `find` produced a truncated file list and the gate passed
# over it. In the secret scanner the same shape silently dropped findings.
gate_lines() {
    local -n _arr="$1"; shift
    local tmp; tmp="$(mktemp)"
    if ! "$@" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        gate_error "enumeration failed, cannot establish a denominator: $*"
    fi
    mapfile -t _arr < "$tmp"
    rm -f "$tmp"
}

# fetch_verified <url> <sha256> <dest>
fetch_verified() {
    local url="$1" want="$2" dest="$3"
    curl -sSfL --retry 3 --connect-timeout 10 --max-time 300 -o "$dest" "$url" \
        || gate_error "download failed: $url"
    local got
    got=$(sha256sum "$dest" | cut -d' ' -f1)
    [ "$got" = "$want" ] || gate_error "checksum mismatch for $url (want $want, got $got)"
}
