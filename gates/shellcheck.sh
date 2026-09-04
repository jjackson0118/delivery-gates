#!/usr/bin/env bash
# Static analysis of the gate scripts themselves.
#
# This gate exists because the repository was violating its own argument. The
# README says a check expressible only in workflow YAML is not a gate, it is a
# feature of one CI vendor -- and shellcheck was running as an inline
# `apt-get install && shellcheck` step in ci.yml. It could not be run locally
# the way the others can, could not be run by Jenkins, and could not be
# exercised by prove-gates-fail, which meant the one check with no proof that it
# fires was the check watching everything else.
#
# The denominator is the number of shell files examined. A refactor that moves
# scripts out of gates/ would otherwise leave this gate scanning nothing and
# reporting a pass.

SCRIPT_DIR="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gate.sh
source "$SCRIPT_DIR/../lib/gate.sh" || {
    printf 'FATAL: cannot load the gate contract from %s\n' "$SCRIPT_DIR/../lib/gate.sh" >&2
    exit 2
}

SHELLCHECK_VERSION="0.10.0"
SHELLCHECK_SHA256="6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87"
SEVERITY="${GATE_SHELLCHECK_SEVERITY:-warning}"

gate_init "shellcheck" "shell files"

TARGET="${1:-.}"
cd "$TARGET" || gate_error "cannot enter $TARGET"

require_cmd curl
require_cmd sha256sum
require_cmd jq

BIN_DIR="${GATE_BIN_DIR:-$(mktemp -d)}"
mkdir -p "$BIN_DIR"
if [ ! -x "$BIN_DIR/shellcheck" ]; then
    fetch_verified \
        "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
        "$SHELLCHECK_SHA256" \
        "$BIN_DIR/sc.tar.xz"
    tar xJf "$BIN_DIR/sc.tar.xz" -C "$BIN_DIR" --strip-components=1 \
        "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
    chmod +x "$BIN_DIR/shellcheck"
fi
gate_tool "shellcheck $("$BIN_DIR/shellcheck" --version 2>/dev/null | awk '/^version:/{print $2}')"

# Every executable shell file, discovered rather than listed. A hand-maintained
# file list is a second source of truth that silently stops matching.
# Discovered by extension AND by shebang. An extension-only glob misses every
# extensionless executable -- gradlew being the obvious one, and it runs on
# every machine before anything else does.
# Via gate_lines: a find that fails partway (an unreadable subdirectory is
# enough) used to yield a truncated list that the gate then passed over,
# because the subshell's non-zero status was discarded.
gate_lines files bash -c '
    set -euo pipefail
    {
        find . -type f \( -name "*.sh" -o -name "*.bash" \) \
            -not -path "./.git/*" -not -path "./.work/*"
        find . -type f -not -name "*.*" -not -path "./.git/*" -not -path "./.work/*" \
            -exec sh -c '"'"'head -c 64 "$1" | grep -qE "^#!.*\b(ba)?sh\b"'"'"' _ {} \; -print
    } | sort -u
'

if [ "${#files[@]}" -eq 0 ]; then
    gate_not_applicable "no shell files in this repository"
fi

REPORT="$(mktemp)"
gate_expect_failure_begin
"$BIN_DIR/shellcheck" --severity="$SEVERITY" --format=json1 "${files[@]}" > "$REPORT" 2>/dev/null
rc=$?
gate_expect_failure_end

# Exit 1 means findings. Anything higher means the analyser did not run.
# (This comment deliberately does not begin with the tool's name: a comment
# starting '# shellcheck ' is parsed as a directive, not prose -- which is
# exactly what this gate caught in its own source on its first run.)
if [ "$rc" -gt 1 ]; then
    head -5 "$REPORT" >&2
    rm -f "$REPORT"
    gate_error "shellcheck exited $rc -- the analyser failed to run, which is not a pass"
fi

gate_lines _codes jq -r '.comments[]?.code' "$REPORT"
for code in "${_codes[@]:-}"; do
    if [ -n "$code" ]; then gate_finding "SC$code"; fi
done

gate_lines _msgs jq -r '.comments[]? | "\(.file):\(.line) SC\(.code) \(.message)"' "$REPORT"
for line in "${_msgs[@]:-}"; do
    if [ -n "$line" ]; then printf '   %s\n' "$line" >&2; fi
done

rm -f "$REPORT"
gate_note "severity>=$SEVERITY"
gate_scanned "${#files[@]}"
gate_finish
