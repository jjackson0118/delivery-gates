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
# One or more fixtures. Direction 1 runs every gate against every fixture;
# direction 2 injects into the first.
#
# One fixture was not enough, and the gap was measurable rather than
# theoretical. dora-loop has no gates/ directory, so the docs gate's structural
# sections never ran against it -- 1 claim checked where this repository yields
# 26. A coverage analysis deleted those four sections outright and the corpus
# stayed green.
DIRTY=0
_args=()
for _a in "$@"; do
    case "$_a" in
        --dirty) DIRTY=1 ;;
        -*) echo "unknown option: $_a" >&2; exit 2 ;;
        *) _args+=("$_a") ;;
    esac
done
set -- "${_args[@]+"${_args[@]}"}"

[ "$#" -ge 1 ] || {
    echo "usage: prove-gates-fail.sh [--dirty] <fixture> [fixture...]" >&2
    exit 2
}
FIXTURES=()
for _t in "$@"; do FIXTURES+=("$(CDPATH='' cd -P -- "$_t" && pwd)"); done

# Taken HERE, at the top, not later.
#
# The first version of this guard took its baseline just before direction 2,
# which left direction 1 -- the pass that measures every denominator and checks
# them against the floors -- entirely unwatched. That is the half where the
# corruption this guard exists to catch actually occurred. Proven by testing it:
# touching a fixture eight seconds into a run changed nothing, because the
# baseline had not been taken yet. A guard whose blind spot covers the thing it
# was written for is worse than no guard, because it reads as coverage.

# The fixtures are the harness's OTHER input, and until now nothing watched
# them. _code_digest protects the harness from a fault that escapes its scratch
# copy; this protects it from a fixture that changes underneath the run.
#
# Observed, not hypothetical: a mutation-testing run against ../dora-loop was
# editing that tree while this harness copied it, and the result came back
# "25 proven, 1 mismatched". Re-running against the quiet tree gave 26/0 again.
# A number that depends on whether someone else happened to be working at the
# time is not a measurement, and the failure is silent -- it reports a plausible
# number rather than an error, which is the exact defect class this repository
# exists to argue about. The harness should not do it either.
#
# Digested rather than refused-on-dirty: this is meant to be run against a
# working tree mid-development, so a dirty fixture is normal. A fixture that
# changes DURING the run is not.
_fixture_digest() {
    find "${FIXTURES[@]}" -type f -printf '%m %p\n' -exec sha256sum {} + \
        2>/dev/null | sort | sha256sum
}
_fixture_before="$(_fixture_digest)"
TARGET="${FIXTURES[0]}"

# Duplicates and basename collisions both nest: scratch_of does `cp -a src dest`
# and cp copies INTO an existing directory, so the same fixture twice doubles
# every denominator and the run stays green because floors are minimums. Two
# different fixtures sharing a basename is worse -- the second one's gates then
# run over a tree containing both.
_uniq_paths=$(printf '%s\n' "${FIXTURES[@]}" | sort -u | wc -l)
_uniq_names=$(for _f in "${FIXTURES[@]}"; do basename "$_f"; done | sort -u | wc -l)
if [ "$_uniq_paths" -ne "${#FIXTURES[@]}" ] || [ "$_uniq_names" -ne "${#FIXTURES[@]}" ]; then
    echo "fixtures must be distinct paths with distinct basenames" >&2
    printf '  given: %s\n' "$*" >&2
    exit 2
fi

# Distinct is not enough: one fixture must not CONTAIN another.
#
# The check above tests set-identity, and the property that actually causes the
# damage is path containment. This repository's own prove-gates.yml checks
# dora-loop out at path: dora-loop INSIDE the delivery-gates checkout and then
# passes both -- two distinct absolute paths with two distinct basenames, so the
# guard was satisfied while fixture 2 contained fixture 1. Measured on a nested
# tree, gates run directly against the workspace reported 33 documented claims
# and 31 shell files against a true 28 and 30: delivery-gates' own denominators
# inflated by exactly dora-loop's file counts, and inflation is invisible
# because floors are minimums.
#
# scratch_of now clones rather than copies, so the harness itself no longer
# carries an untracked nested checkout into the scratch, and the numbers above
# are unchanged through it. This check is therefore not what fixes that -- it
# stops the arrangement being created at all, for the case where gates are run
# directly against a workspace, which is what the reusable pipeline does.
for _a in "${FIXTURES[@]}"; do
    for _b in "${FIXTURES[@]}"; do
        [ "$_a" = "$_b" ] && continue
        case "$_b/" in
            "$_a"/*)
                echo "fixture nests inside another fixture:" >&2
                printf '  %s contains %s\n' "$_a" "$_b" >&2
                printf '  check them out as siblings; a containing fixture scans the contained one\n' >&2
                exit 2
                ;;
        esac
    done
done
WORK="$(mktemp -d)"
# chmod first: a fault that plants an unreadable directory would otherwise
# leave the scratch tree undeletable.
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ROWS=()

# Declared minimum denominators for this fixture. See fixtures/*.floors.
declare -A FLOOR=()
# Derived from the fixture directory name, overridable because a caller's
# checkout path is not ours to dictate. This defaulted silently to the basename
# and CI checks the fixture out as "fixture/", so the harness looked for
# fixtures/fixture.floors and exited 2 -- green locally, red on the runner,
# because local and CI were pointed at differently-named copies of the same
# repository. Checklist rule 3, in the file that describes checklist rule 3.
load_floors() {
    FLOOR=()
    FLOOR_FILE="${GATE_FLOORS:-$ROOT/fixtures/$(basename "$1").floors}"
    if [ -f "$FLOOR_FILE" ]; then
        while IFS='=' read -r _g _n || [ -n "$_g" ]; do
            # Strip \r from BOTH halves before anything looks at them: on a CRLF
            # file a blank line arrives as "\r", which is not empty, so the
            # skip below missed it and the malformed-value check then reported
            # an entry with no name.
            _g="${_g%$'\r'}"; _n="${_n%$'\r'}"
            case "$_g" in ''|\#*) continue ;; esac
            # Validated here, because the comparison downstream sits in an
            # `elif`, where `[`'s "integer expression expected" is invisible to
            # errexit: the condition evaluates false and control falls through
            # to the OK branch. A CRLF floors file silently disabled every floor
            # and the run stayed green.
            case "$_n" in
                n/a) ;;
                ''|*[!0-9]*) printf 'malformed floor in %s: %s=%s\n' "$FLOOR_FILE" "$_g" "$_n" >&2; exit 2 ;;
            esac
            FLOOR["$_g"]="$_n"
        done < "$FLOOR_FILE"
    else
        printf 'no floor file at %s -- scope reduction cannot be detected for this fixture.\n' "$FLOOR_FILE" >&2
        printf 'create it, or point GATE_FLOORS at the right one.\n' >&2
        exit 2
    fi
}
load_floors "$TARGET"

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

# Clone the fixture. Do not copy it.
#
# This used to be `cp -a`, and that was the only copy path -- there was no mode,
# flag or code path in which this harness measured a clean checkout. Every
# denominator it published was therefore measured against whatever branch
# happened to be checked out, plus the author's local refs and gitignored
# scratch.
#
# That is not hypothetical. A README transcript published from this harness
# reported `shellcheck scanned 4` because a gitignored backups/ directory held
# three of the author's own perturbation scripts, and `secrets scanned 22`
# because the working tree carried 34 commits across nine local branches. A
# clean checkout gives 1 and 17. Five of ten rows were wrong, and they were
# attributed to a commit that was never merged.
#
# docs/REVIEW.md rule 4 already said this exactly -- "any threshold measured
# from a developer's checkout is measured in the wrong place; clone to a temp
# directory and measure there" -- and was written from this same failure the day
# before it recurred. It recurred because the only tool that produces these
# numbers could not obey it. A rule the toolchain cannot follow is not a
# control.
#
# --single-branch --no-tags is load-bearing, not tidiness. A plain `git clone`
# of a local repository creates a remote-tracking ref for every local branch, so
# `git rev-list --all` still counts them: measured on this fixture, cp -a gave
# 34 commits, plain clone gave 34, and --single-branch gave 17 -- identical to a
# fresh clone from the remote. The obvious fix would have reproduced the exact
# defect it was written to remove.
scratch_of() {
    local src="$1" dest="$WORK/$2"

    git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
        || { echo "fixture is not a git repository: $src" >&2; exit 2; }

    if [ "$DIRTY" -eq 1 ]; then
        cp -a "$src" "$dest"
        rm -rf "$dest/.gate-reports"
    else
        git clone --quiet --single-branch --no-tags "$src" "$dest" \
            || { echo "could not clone fixture: $src" >&2; exit 2; }
        # Belt and braces: a clone should carry nothing untracked, and if that
        # ever stops being true the numbers stop being reproducible again.
        local stray
        stray=$(git -C "$dest" status --porcelain --ignored | wc -l)
        [ "$stray" -eq 0 ] \
            || { echo "clone of $src carried $stray untracked/ignored entries" >&2; exit 2; }
    fi

    echo "$dest"
}

scratch() { scratch_of "$TARGET" "$1"; }

# Say which tree was measured, every run, before any number is printed.
#
# The failure this guards against is not a wrong number; it is a number whose
# provenance nobody recorded. A run that silently tested HEAD while the author
# had uncommitted work, or silently tested uncommitted work and then had its
# output pasted into a README, are the same defect from opposite directions.
for _f in "${FIXTURES[@]}"; do
    _n="$(basename "$_f")"
    _head="$(git -C "$_f" rev-parse --short HEAD 2>/dev/null || echo '?')"
    _pending=$(git -C "$_f" status --porcelain 2>/dev/null | wc -l)
    if [ "$DIRTY" -eq 1 ]; then
        printf '  fixture %-16s WORKING TREE at %s (%s uncommitted)\n' "$_n" "$_head" "$_pending"
    elif [ "$_pending" -gt 0 ]; then
        printf '  fixture %-16s %s -- %s uncommitted change(s) NOT included\n' "$_n" "$_head" "$_pending"
    else
        printf '  fixture %-16s %s\n' "$_n" "$_head"
    fi
done
if [ "$DIRTY" -eq 1 ]; then
    printf '\n  !! --dirty: measured against working trees, not commits. These numbers\n'
    printf '  !! are NOT publishable -- nobody else can reproduce them. Use a clean\n'
    printf '  !! run for anything that ends up in a document.\n'
fi

printf '\n=== direction 1: every gate must be QUIET on a clean tree ===\n'
for FIXTURE in "${FIXTURES[@]}"; do
  fixname="$(basename "$FIXTURE")"
  load_floors "$FIXTURE"
  printf '  -- fixture: %s\n' "$fixname"
  for g in "$ROOT"/gates/*.sh; do
    name="$(basename "$g" .sh)"
    dir="$(scratch_of "$FIXTURE" "clean-$fixname-$name")"
    rc="$(run_gate_in "$dir" "$name")"
    # 3 is a legitimate clean-tree answer: the gate does not apply to this
    # fixture. Accepting only 0 would force every gate to be relevant to every
    # repository, which is how a linter ends up reporting a pass on a language
    # it never looked at.
    floor="${FLOOR[$name]:-}"
    if [ -z "$floor" ]; then
        printf '  BAD   %-18s no floor declared in %s -- a gate with no floor opts itself out of scope-reduction detection\n' \
            "$name" "$(basename "$FLOOR_FILE")"
        record "clean:$fixname:$name" "-" "floor" "-" "MISMATCH" "gate has no declared minimum denominator"; FAIL=$((FAIL+1))
        continue
    fi
    scanned="$(report_scanned "$dir" "$name")"
    if [ "$floor" = "n/a" ]; then
        # Declared not applicable. Stated rather than omitted, because omission
        # is indistinguishable from forgetting -- and a gate that starts
        # examining a fixture it was declared irrelevant to is also a change
        # worth catching, in the opposite direction.
        if [ "$rc" -eq 3 ]; then
            printf '  OK    %-18s not applicable, as declared (exit 3)\n' "$name"
            record "clean:$fixname:$name" "-" "n/a" "exit 3" "ok" "declared not applicable to this fixture"; PASS=$((PASS+1))
        else
            printf '  BAD   %-18s declared n/a in %s but returned exit %s\n' \
                "$name" "$(basename "$FLOOR_FILE")" "$rc"
            record "clean:$fixname:$name" "-" "n/a" "$rc" "MISMATCH" "gate ran against a fixture it was declared irrelevant to"; FAIL=$((FAIL+1))
        fi
    elif [ "$rc" -eq 3 ]; then
        # The floor declares the gate applies here. Declaring itself irrelevant
        # to a fixture it is expected to examine is a scope reduction wearing a
        # different exit code.
        printf '  BAD   %-18s reported NOT APPLICABLE, but %s declares a floor of %s\n' \
            "$name" "$(basename "$FLOOR_FILE")" "$floor"
        record "clean:$fixname:$name" "-" ">=$floor" "n/a (exit 3)" "MISMATCH" "gate declared itself not applicable to a fixture it is expected to examine"; FAIL=$((FAIL+1))
    elif [ "$rc" -ne 0 ]; then
        printf '  BAD   %-18s fired on clean input (exit %s) -- gate does not discriminate\n' "$name" "$rc"
        record "clean:$fixname:$name" "-" "0" "$rc" "MISMATCH" "no fault injected; the gate must stay silent"; FAIL=$((FAIL+1))
    elif [ "$scanned" = "null" ] || [ "$scanned" -lt "$floor" ]; then
        printf '  BAD   %-18s scanned %s, floor is %s -- the gate is examining less than it used to\n' \
            "$name" "$scanned" "$floor"
        record "clean:$fixname:$name" "-" ">=$floor" "$scanned" "MISMATCH" "denominator fell below the declared floor"; FAIL=$((FAIL+1))
    else
        printf '  OK    %-18s quiet on clean input, scanned %s (floor %s)\n' "$name" "$scanned" "$floor"
        record "clean:$fixname:$name" "-" ">=$floor" "$scanned" "ok" "no fault injected; the gate must stay silent and examine at least its declared floor"; PASS=$((PASS+1))
    fi
  done
done
load_floors "$TARGET"

# Injectors run with nothing confining them to their scratch copy. One that
# edits the real gates would weaken an unproven path invisibly -- and most of
# the surface is unproven, which is what the review that prompted this found.
# Covers everything an injector could change to alter a later verdict, not just
# the three directories the first version watched. A review escaped that one by
# rewriting faults/, fixtures/, tools/gh/ (the token-handling code) and this
# script itself -- none of which were hashed -- and by restoring a sabotaged
# gate before the single end-of-loop comparison ran.
#
# Modes are included: chmod -x on a gate is a change the content hash cannot see.
_code_digest() {
    find "$ROOT/gates" "$ROOT/lib" "$ROOT/ci" "$ROOT/faults" "$ROOT/fixtures" \
         "$ROOT/tools" "$ROOT/prove-gates-fail.sh" -type f -printf '%m %p\n' -exec sha256sum {} + \
        2>/dev/null | sort | sha256sum
}
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
    # NUL-delimited, because a newline-delimited channel is forgeable by its
    # own payload. The previous version printed six "key=value" lines and the
    # parent re-read them with a line loop: a newline inside the LAST value --
    # nothing follows it to overwrite -- set every other variable. A review
    # weaponised that into "26 proven, 0 mismatched" with a genuinely broken
    # gate and _selftest-phantom reporting caught. The earlier `source` evasion
    # needed a specific `if` on $id; this one needed nothing.
    #
    # Values are also refused if they contain a newline at the source, each key
    # is accepted once, and every field is validated below. Framing alone is
    # not enough when the reader is this credulous.
    # No newline check inside the subshell. Two attempts at one failed there:
    # "$(printf "\n")" is the empty string because command substitution strips
    # trailing newlines, so the pattern matched every value; and $'\n' contains
    # a literal single quote, which terminates the single-quoted script this
    # subshell runs. Neither is needed -- NUL framing already stops a value
    # forging a key, and the field validators below reject newlines everywhere
    # except DESCRIPTION, where one is untidy rather than dangerous.
    _seen=""
    # Read through a temp file whose exit status is checked.
    #
    # This was `done < <(timeout 10 env -i bash ...)`, which is the construct
    # lib/gate.sh:gate_lines() exists to replace and that
    # faults/contract-broken-enumeration proves the gates catch -- its own
    # DESCRIPTION calls it THE WORST ONE. It was fixed in tools/gh/pr-open.sh
    # and left here, in the file the entire proof rests on.
    #
    # It was not benign. The producer prints the keys in a fixed order ending
    # with EXPECT_SCANNED_MIN, and its exit status was discarded, so a truncated
    # read or a timeout dropped that key FIRST -- and it is consumed under a
    # `[ -n "$EXPECT_SCANNED_MIN" ]` guard, which silently skips when unset. The
    # denominator assertion added specifically to catch a gate examining less
    # than it declares was itself silently droppable, through the construct this
    # repository names as its worst.
    _envout="$(mktemp)"
    if ! timeout 10 env -i bash --noprofile --norc -c '
        set -euo pipefail
        . "$1" >/dev/null 2>&1 || exit 1
        for k in GATE EXPECT_EXIT EXPECT_RULE SELFTEST DESCRIPTION EXPECT_SCANNED_MIN; do
            v="${!k:-}"
            printf "%s\0%s\0" "$k" "$v"
        done' _ "$f/fault.env" </dev/null > "$_envout"; then
        rm -f "$_envout"
        printf '  BAD   %-18s fault.env could not be read -- its declarations are unknown, not empty\n' "$id"
        record "$id" "?" "-" "-" "MISMATCH" "fault.env unreadable"; FAIL=$((FAIL+1)); continue
    fi
    while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
        case " $_seen " in *" $_k "*) printf '  BAD   %-18s fault.env sets %s more than once\n' "$id" "$_k"; FAIL=$((FAIL+1)); continue 2 ;; esac
        _seen="$_seen $_k"
        case "$_k" in
            GATE)        GATE="$_v" ;;
            EXPECT_EXIT) EXPECT_EXIT="$_v" ;;
            EXPECT_RULE) EXPECT_RULE="$_v" ;;
            SELFTEST)    SELFTEST="$_v" ;;
            DESCRIPTION) DESCRIPTION="$_v" ;;
            EXPECT_SCANNED_MIN) EXPECT_SCANNED_MIN="$_v" ;;
        esac
    done < "$_envout"
    rm -f "$_envout"

    # Validated, not merely parsed. An unvalidated EXPECT_EXIT or
    # EXPECT_SCANNED_MIN reaches `[` as a non-integer, where the error is
    # invisible to errexit and the comparison quietly evaluates false.
    _bad=""
    case "$GATE" in ''|*[!A-Za-z0-9_-]*) _bad="GATE" ;; esac
    case "$EXPECT_EXIT" in ''|[0-3]) ;; *) _bad="EXPECT_EXIT" ;; esac
    case "$SELFTEST" in ''|mismatch) ;; *) _bad="SELFTEST" ;; esac
    case "$EXPECT_SCANNED_MIN" in ''|*[!0-9]*) [ -z "$EXPECT_SCANNED_MIN" ] || _bad="EXPECT_SCANNED_MIN" ;; esac
    if [ -n "$_bad" ]; then
        printf '  BAD   %-18s fault.env has an invalid %s\n' "$id" "$_bad"
        record "$id" "${GATE:-?}" "-" "-" "MISMATCH" "invalid $_bad in fault.env"; FAIL=$((FAIL+1)); continue
    fi
    [ -n "$GATE" ] || { printf '  BAD   %-18s fault.env declares no GATE\n' "$id"; FAIL=$((FAIL+1)); continue; }

    _digest_fault_before="$(_code_digest)"
    dir="$(scratch "fault-$id")"
    ( cd "$dir" && bash "$f/inject.sh" ) || { printf '  BAD   %-18s injector failed\n' "$id"; FAIL=$((FAIL+1)); continue; }

    rc="$(run_gate_in "$dir" "$GATE")"
    if [ "$(_code_digest)" != "$_digest_fault_before" ]; then
        printf '  BAD   %-18s the harness tree changed while this fault ran -- its injector escaped its scratch copy\n' "$id"
        record "$id" "$GATE" "-" "-" "MISMATCH" "injector modified the harness tree"; FAIL=$((FAIL+1))
        _digest_before="$(_code_digest)"
        continue
    fi
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

if [ "$(_fixture_digest)" != "$_fixture_before" ]; then
    printf '\n!! a fixture tree changed while this run was in progress. Every\n'
    printf '!! denominator above was measured against a moving target, so the\n'
    printf '!! result is void rather than merely wrong. Re-run against a quiet tree.\n'
    FAIL=$((FAIL+1))
fi

if [ "$DIRTY" -eq 1 ]; then
    printf '\n=== result: %d proven, %d mismatched (--dirty: NOT PUBLISHABLE) ===\n' "$PASS" "$FAIL"
else
    printf '\n=== result: %d proven, %d mismatched ===\n' "$PASS" "$FAIL"
fi

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
