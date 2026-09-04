#!/usr/bin/env bash
# Proves each gate fires on the fault it exists to catch, and stays quiet on
# clean input.
#
# WHY BOTH DIRECTIONS. A gate never observed refusing anything is not known to
# work. A gate never observed accepting anything is not known to discriminate.
# Only the pair establishes that the gate is measuring something. This harness
# runs every gate against a clean tree and against a corpus of injected faults,
# and requires the expected answer in both directions.
#
# WHY IT INVOKES THE REAL GATE. The harness calls gates/<name>.sh -- the same
# script GitHub Actions calls and the same script Jenkins calls. If the proof
# re-implemented the check, it would prove a copy works. That is the single
# property that separates this from theatre, and it is why gates are scripts
# rather than workflow YAML.
#
# WHY IT ASSERTS MORE THAN AN EXIT CODE. A gate that crashes on startup also
# exits non-zero. Accepting "non-zero" as proof would accept a broken scanner as
# coverage. So each fault declares an exact expected exit code, and optionally
# the exact rule id that must appear in the gate's report. Asserting the rule
# proves the gate matched the planted fault rather than tripping over something
# else -- for a vulnerability scanner, it is also the difference between a
# loaded database and an empty one.
#
# WHO TESTS THE HARNESS. faults/_control-noop injects nothing and must come back
# clean; anything red there means a flaky gate is contaminating the run.
# faults/_selftest-phantom declares a fault it never injects, and the harness is
# required to report a MISMATCH for it. If this harness ever reports "caught"
# for a fault that was never applied, every other row is worthless.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: prove-gates-fail.sh <path-to-target-repo>}"
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ROWS=()

record() { ROWS+=("$1|$2|$3|$4|$5|${6:-}"); }

run_gate_in() {
    # run_gate_in <dir> <gate> ; echoes exit code, leaves report in <dir>/.gate-reports
    local dir="$1" gate="$2" rc=0
    ( cd "$dir" && GATE_REPORT_DIR="$dir/.gate-reports" \
        GATE_BIN_DIR="${GATE_BIN_DIR:-$WORK/bin}" \
        GATE_SECRETS_MODE=history \
        "$ROOT/gates/$gate.sh" . >/dev/null 2>&1 ) || rc=$?
    echo "$rc"
}

scratch() {
    local dest="$WORK/$1"
    cp -a "$TARGET" "$dest"
    echo "$dest"
}

printf '\n=== direction 1: every gate must be QUIET on a clean tree ===\n'
for g in "$ROOT"/gates/*.sh; do
    name="$(basename "$g" .sh)"
    dir="$(scratch "clean-$name")"
    rc="$(run_gate_in "$dir" "$name")"
    # 3 is a legitimate clean-tree answer: the gate does not apply to this
    # fixture. Accepting only 0 would force every gate to be relevant to every
    # repository, which is how a linter ends up reporting a pass on a language
    # it never looked at.
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
        label="quiet on clean input (exit 0)"
        [ "$rc" -eq 3 ] && label="not applicable to this fixture (exit 3)"
        printf '  OK    %-18s %s\n' "$name" "$label"
        record "clean:$name" "-" "0 or 3" "$rc" "ok" "no fault injected; the gate must stay silent or declare itself not applicable"; PASS=$((PASS+1))
    else
        printf '  BAD   %-18s fired on clean input (exit %s) -- gate does not discriminate\n' "$name" "$rc"
        record "clean:$name" "-" "0 or 3" "$rc" "MISMATCH" "no fault injected; the gate must stay silent or declare itself not applicable"; FAIL=$((FAIL+1))
    fi
done

printf '\n=== direction 2: every declared fault must be CAUGHT ===\n'
for f in "$ROOT"/faults/*/; do
    id="$(basename "$f")"
    # shellcheck disable=SC1091
    GATE=""; EXPECT_EXIT=""; EXPECT_RULE=""; SELFTEST=""; DESCRIPTION=""
    source "$f/fault.env"

    dir="$(scratch "fault-$id")"
    ( cd "$dir" && bash "$f/inject.sh" ) || { printf '  BAD   %-18s injector failed\n' "$id"; FAIL=$((FAIL+1)); continue; }

    rc="$(run_gate_in "$dir" "$GATE")"
    report="$dir/.gate-reports/$GATE.json"

    verdict="ok"
    if [ "$rc" -ne "$EXPECT_EXIT" ]; then
        verdict="MISMATCH"
    elif [ -n "$EXPECT_RULE" ]; then
        if ! jq -e --arg r "$EXPECT_RULE" '.rules | index($r)' "$report" >/dev/null 2>&1; then
            verdict="MISMATCH"
        fi
    fi

    if [ "${SELFTEST:-}" = "mismatch" ]; then
        # inverted: this fault exists to prove the harness can say "not caught"
        if [ "$verdict" = "MISMATCH" ]; then
            printf '  OK    %-18s harness correctly reported NOT CAUGHT for an uninjected fault\n' "$id"
            record "$id" "$GATE" "$EXPECT_EXIT" "$rc" "ok (inverted)" "$DESCRIPTION"; PASS=$((PASS+1))
        else
            printf '  BAD   %-18s harness claimed CAUGHT for a fault it never injected -- the harness is lying\n' "$id"
            record "$id" "$GATE" "$EXPECT_EXIT" "$rc" "HARNESS LIED" "$DESCRIPTION"; FAIL=$((FAIL+1))
        fi
        continue
    fi

    if [ "$verdict" = "ok" ]; then
        printf '  OK    %-18s caught by %s (exit %s%s)\n' "$id" "$GATE" "$rc" "${EXPECT_RULE:+, rule $EXPECT_RULE}"
        record "$id" "$GATE" "$EXPECT_EXIT" "$rc" "ok" "$DESCRIPTION"; PASS=$((PASS+1))
    else
        printf '  BAD   %-18s expected exit %s%s, got exit %s\n' \
            "$id" "$EXPECT_EXIT" "${EXPECT_RULE:+ rule $EXPECT_RULE}" "$rc"
        printf '        this fault exists because: %s\n' "$DESCRIPTION"
        [ -f "$report" ] && printf '        report: %s\n' "$(jq -c '{status,exit_code,findings,rules,scanned}' "$report")"
        record "$id" "$GATE" "$EXPECT_EXIT" "$rc" "MISMATCH" "$DESCRIPTION"; FAIL=$((FAIL+1))
    fi
done

printf '\n=== result: %d proven, %d mismatched ===\n' "$PASS" "$FAIL"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## Gate proof"
        echo
        echo "Gates proven against \`$(cd "$TARGET" && git rev-parse --short HEAD 2>/dev/null || echo unknown)\`"
        echo
        echo "| case | gate | expected exit | actual | verdict |"
        echo "|---|---|---|---|---|"
        for r in "${ROWS[@]}"; do IFS='|' read -r a b c d e _ <<<"$r"; echo "| $a | $b | $c | $d | $e |"; done
        echo
        echo "<details><summary>What each case is for</summary>"
        echo
        for r in "${ROWS[@]}"; do
            IFS='|' read -r a _ _ _ _ f <<<"$r"
            [ -n "$f" ] && echo "- **$a** -- $f"
        done
        echo
        echo "</details>"
        echo
        echo "**$PASS proven, $FAIL mismatched.**"
    } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$FAIL" -eq 0 ]
