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
# chmod first: a fault that plants an unreadable directory would otherwise
# leave the scratch tree undeletable.
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ROWS=()

# Declared minimum denominators for this fixture. See fixtures/*.floors.
declare -A FLOOR=()
FLOOR_FILE="$ROOT/fixtures/$(basename "$TARGET").floors"
if [ -f "$FLOOR_FILE" ]; then
    while IFS='=' read -r _g _n; do
        case "$_g" in ''|\#*) continue ;; esac
        FLOOR["$_g"]="$_n"
    done < "$FLOOR_FILE"
else
    printf 'no floor file at %s -- scope reduction cannot be detected for this fixture\n' "$FLOOR_FILE" >&2
    exit 2
fi

# report_scanned <dir> <gate> ; echoes the denominator, or "null"
report_scanned() {
    jq -r '.scanned // "null"' "$1/.gate-reports/$2.json" 2>/dev/null || echo "null"
}

record() { ROWS+=("$1|$2|$3|$4|$5|${6:-}"); }

run_gate_in() {
    # run_gate_in <dir> <gate> ; echoes exit code, leaves report in <dir>/.gate-reports
    #
    # A gate named "_synthetic" is built by the fault itself, at
    # .synthetic/gate.sh. Some defects live in the contract library rather than
    # in any repository under test -- an unbound variable, an unwritable report
    # directory, a bad denominator -- and cannot be expressed by injecting a
    # source defect into a fixture. Those faults ship a minimal gate instead.
    local dir="$1" gate="$2" rc=0 script
    if [ "$gate" = "_synthetic" ]; then
        script="$dir/.synthetic/gate.sh"
    else
        script="$ROOT/gates/$gate.sh"
    fi
    ( cd "$dir" && GATE_REPORT_DIR="$dir/.gate-reports" \
        GATE_BIN_DIR="${GATE_BIN_DIR:-$WORK/bin}" \
        GATE_SECRETS_MODE=history \
        GATE_LIB="$ROOT/lib/gate.sh" \
        "$script" . >/dev/null 2>&1 ) || rc=$?
    echo "$rc"
}

scratch() {
    local dest="$WORK/$1"
    cp -a "$TARGET" "$dest"
    # A fixture with reports from a manual run would hand every fault a stale
    # verdict to read as current.
    rm -rf "$dest/.gate-reports"
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
    floor="${FLOOR[$name]:-}"
    if [ -z "$floor" ]; then
        printf '  BAD   %-18s no floor declared in %s -- a gate with no floor opts itself out of scope-reduction detection\n' \
            "$name" "$(basename "$FLOOR_FILE")"
        record "clean:$name" "-" "floor" "-" "MISMATCH" "gate has no declared minimum denominator"; FAIL=$((FAIL+1))
        continue
    fi
    scanned="$(report_scanned "$dir" "$name")"
    if [ "$rc" -eq 3 ]; then
        # The floor declares the gate applies here. Declaring itself irrelevant
        # to a fixture it is expected to examine is a scope reduction wearing a
        # different exit code.
        printf '  BAD   %-18s reported NOT APPLICABLE, but %s declares a floor of %s\n' \
            "$name" "$(basename "$FLOOR_FILE")" "$floor"
        record "clean:$name" "-" ">=$floor" "n/a (exit 3)" "MISMATCH" "gate declared itself not applicable to a fixture it is expected to examine"; FAIL=$((FAIL+1))
    elif [ "$rc" -ne 0 ]; then
        printf '  BAD   %-18s fired on clean input (exit %s) -- gate does not discriminate\n' "$name" "$rc"
        record "clean:$name" "-" "0" "$rc" "MISMATCH" "no fault injected; the gate must stay silent"; FAIL=$((FAIL+1))
    elif [ "$scanned" = "null" ] || [ "$scanned" -lt "$floor" ]; then
        printf '  BAD   %-18s scanned %s, floor is %s -- the gate is examining less than it used to\n' \
            "$name" "$scanned" "$floor"
        record "clean:$name" "-" ">=$floor" "$scanned" "MISMATCH" "denominator fell below the declared floor"; FAIL=$((FAIL+1))
    else
        printf '  OK    %-18s quiet on clean input, scanned %s (floor %s)\n' "$name" "$scanned" "$floor"
        record "clean:$name" "-" ">=$floor" "$scanned" "ok" "no fault injected; the gate must stay silent and examine at least its declared floor"; PASS=$((PASS+1))
    fi
done

# Injectors run with nothing confining them to their scratch copy. One that
# edits the real gates would weaken an unproven path invisibly -- and most of
# the surface is unproven, which is what the review that prompted this found.
_code_digest() { find "$ROOT/gates" "$ROOT/lib" "$ROOT/ci" -type f -exec sha256sum {} + | sort | sha256sum; }
_digest_before="$(_code_digest)"

printf '\n=== direction 2: every declared fault must be CAUGHT ===\n'
for f in "$ROOT"/faults/*/; do
    id="$(basename "$f")"
    GATE=""; EXPECT_EXIT=""; EXPECT_RULE=""; SELFTEST=""; DESCRIPTION=""; EXPECT_SCANNED_MIN=""; report_note=""
    # fault.env is read, not sourced into this shell.
    #
    # `source` ran repository content with the harness's own functions in
    # scope, so a fault.env could redefine run_gate_in and fabricate every
    # direction-2 row. Demonstrated: "22 proven, 0 mismatched" with the gates
    # deliberately broken and _selftest-phantom still reporting NOT CAUGHT --
    # the harness whose whole job is to prevent a green result standing in for
    # a measurement, producing exactly that about itself.
    #
    # Now: evaluated in a clean subshell that inherits no functions, with only
    # five known keys read back through a defined channel.
    while IFS='=' read -r _k _v; do
        case "$_k" in
            GATE)        GATE="$_v" ;;
            EXPECT_EXIT) EXPECT_EXIT="$_v" ;;
            EXPECT_RULE) EXPECT_RULE="$_v" ;;
            SELFTEST)    SELFTEST="$_v" ;;
            DESCRIPTION) DESCRIPTION="$_v" ;;
            EXPECT_SCANNED_MIN) EXPECT_SCANNED_MIN="$_v" ;;
        esac
    done < <(env -i bash --noprofile --norc -c '
        set -euo pipefail
        . "$1" >/dev/null 2>&1 || exit 1
        for k in GATE EXPECT_EXIT EXPECT_RULE SELFTEST DESCRIPTION EXPECT_SCANNED_MIN; do
            printf "%s=%s\n" "$k" "${!k:-}"
        done' _ "$f/fault.env")
    [ -n "$GATE" ] || { printf '  BAD   %-18s fault.env declares no GATE\n' "$id"; FAIL=$((FAIL+1)); continue; }

    dir="$(scratch "fault-$id")"
    ( cd "$dir" && bash "$f/inject.sh" ) || { printf '  BAD   %-18s injector failed\n' "$id"; FAIL=$((FAIL+1)); continue; }

    rc="$(run_gate_in "$dir" "$GATE")"
    report="$dir/.gate-reports/$GATE.json"

    verdict="ok"
    if [ "$rc" -ne "$EXPECT_EXIT" ]; then
        verdict="MISMATCH"
    elif [ -n "$EXPECT_SCANNED_MIN" ] && {
             s="$(report_scanned "$dir" "$GATE")"
             [ "$s" = "null" ] || [ "$s" -lt "$EXPECT_SCANNED_MIN" ]; }; then
        verdict="MISMATCH"
        report_note="scanned $(report_scanned "$dir" "$GATE"), expected at least $EXPECT_SCANNED_MIN"
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
        [ -n "$report_note" ] && printf '        %s\n' "$report_note"
        printf '        this fault exists because: %s\n' "$DESCRIPTION"
        [ -f "$report" ] && printf '        report: %s\n' "$(jq -c '{status,exit_code,findings,rules,scanned}' "$report")"
        record "$id" "$GATE" "$EXPECT_EXIT" "$rc" "MISMATCH" "$DESCRIPTION"; FAIL=$((FAIL+1))
    fi
done

if [ "$(_code_digest)" != "$_digest_before" ]; then
    printf '\n!! gates/, lib/ or ci/ changed while the fault loop ran -- an injector\n'
    printf '!! escaped its scratch copy. Every result above is suspect.\n'
    FAIL=$((FAIL+1))
fi

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
