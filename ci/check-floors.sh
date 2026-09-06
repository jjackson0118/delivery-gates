#!/usr/bin/env bash
# check-floors.sh <floors-file> [reports-dir]
#
# Fails the build when a gate examined less than the consumer declared it would,
# or returned "not applicable" for something the consumer declared applies.
#
# WHY THIS EXISTS AS A SEPARATE STEP
#
# Every gate already refuses to pass on a zero denominator: lib/gate.sh turns
# `gate_scanned 0` into exit 2. That catches a gate that examined NOTHING. It
# does not catch a gate that examined less than it used to, and it does not
# catch a gate that decided the whole repository was out of scope.
#
# Those were only ever caught by prove-gates-fail.sh, which runs inside
# delivery-gates against delivery-gates' own fixtures. A consumer of the
# reusable workflow got no denominator enforcement at all, and the README
# described floors in a section a reader takes as describing the product.
#
# Measured on a repository containing one .java file and nothing else:
#
# (each row is prefixed, because a comment whose first word is "shellcheck" is
# read as a shellcheck directive and SC1107 fires on it -- indenting does not
# help, the parser strips leading whitespace)
#
#   > docs             gate=3  adapter=0
#   > shellcheck       gate=3  adapter=0
#   > gradle-wrapper   gate=3  adapter=0
#   > jvm-test         gate=3  adapter=0
#
# Four of five gates checked nothing, the adapter mapped every exit 3 to 0, and
# the pipeline was green. Deleting your markdown, your shell scripts and your
# Gradle build is a way to pass this pipeline, which is the failure the whole
# repository is an argument against, sitting in the part of it other people use.
#
# FLOORS FILE FORMAT
#
#   gate-name=<minimum>   the gate applies, and must scan at least this many
#   gate-name=n/a         the gate is expected to return exit 3 here
#   # comment
#
# A gate with no entry is an error rather than a pass. Silence is how scope
# quietly shrinks, and an unlisted gate is indistinguishable from one somebody
# forgot to declare.
set -euo pipefail

FLOORS="${1:?usage: check-floors.sh <floors-file> [reports-dir]}"
REPORTS="${2:-.gate-reports}"

[ -f "$FLOORS" ] || { printf 'floors file not found: %s\n' "$FLOORS" >&2; exit 2; }
[ -d "$REPORTS" ] || { printf 'no reports directory: %s\n' "$REPORTS" >&2; exit 2; }
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 2; }

# Digits are not enough; the value has to be one `[` can actually compare.
#
# Both this file and prove-gates-fail.sh validated `*[!0-9]*` and then compared
# with `[ "$a" -lt "$b" ]` sitting in an elif. On a value bash cannot parse as
# an integer, `[` writes "integer expression expected" to stderr and returns 2 --
# neither 0 nor 1 -- so control falls through to the OK branch. Measured: a
# floor of 99999999999999999999 printed "OK docs scanned 9 (floor
# 99999999999999999999)" and exited 0, with bash's complaint going nowhere.
#
# Both files already carried a comment naming this exact fall-through as the
# reason to validate before comparing. Both validated digit-ness and not
# representability, so the fall-through they describe was still live in the one
# mechanism that detects scope reduction, announcing success.
#
# 18 digits is the bound: a signed 64-bit integer holds 19, so anything at or
# under 18 is always parseable, and no real denominator comes near it.
_representable() {  # _representable <value>
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 18 ]
}

fail=0
checked=0
declared=""

# Read through a temp file whose status is checked. `while read < <(cmd)` runs
# the command in a subshell and discards its exit status, which is how an
# enumeration failure becomes an empty loop that reports success.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! grep -vE '^\s*#|^\s*$' "$FLOORS" > "$tmp"; then
    # grep exits 1 on no matches, which for this file means "no declarations".
    if [ -s "$tmp" ]; then
        printf 'could not read %s\n' "$FLOORS" >&2
        exit 2
    fi
fi

while IFS='=' read -r gate floor || [ -n "${gate:-}" ]; do
    [ -n "$gate" ] || continue
    gate="${gate//[[:space:]]/}"
    floor="${floor//[[:space:]]/}"
    report="$REPORTS/$gate.json"

    # Counted once per distinct gate: the summary line is what a reader uses to
    # judge coverage, and three copies of one entry is not three gates.
    case " $declared " in
        *" $gate "*)
            printf '  BAD      %-16s declared more than once in %s\n' "$gate" "$FLOORS"
            fail=1
            continue
            ;;
    esac
    declared="$declared $gate"
    checked=$(( checked + 1 ))

    if [ ! -f "$report" ]; then
        printf '  MISSING  %-16s declared in %s, but no report was written\n' "$gate" "$FLOORS"
        fail=1
        continue
    fi

    status=$(jq -r '.status // "?"' "$report")
    scanned=$(jq -r '.scanned // 0' "$report")
    unit=$(jq -r '.scanned_unit // "items"' "$report")

    if [ "$floor" = "n/a" ]; then
        if [ "$status" = "not_applicable" ]; then
            printf '  OK       %-16s not applicable, as declared\n' "$gate"
        else
            printf '  MISMATCH %-16s declared n/a but ran and reported %s over %s %s\n' \
                "$gate" "$status" "$scanned" "$unit"
            fail=1
        fi
        continue
    fi

    if ! _representable "$floor"; then
        printf '  BAD      %-16s floor "%s" is not a comparable integer, and not n/a\n' "$gate" "$floor"
        fail=1
        continue
    fi

    # The REPORT's value is validated too, not only the declaration.
    #
    # `[ "$scanned" -lt "$floor" ]` sits in an elif below, and `[` on a
    # non-integer writes "integer expression expected" to stderr and returns 2 --
    # which is neither 0 nor 1, so control falls through to the OK branch and the
    # gate passes. lib/gate.sh:189-195 and prove-gates-fail.sh:118-125 each
    # document this exact fall-through as the reason to validate before
    # comparing; this script was written without it. Measured: a report with
    # "scanned": "lots" printed OK and exited 0.
    if ! _representable "$scanned"; then
        printf '  BAD      %-16s report scanned value is not a comparable integer: %s\n' "$gate" "$scanned"
        fail=1
        continue
    fi

    if [ "$status" = "not_applicable" ]; then
        printf '  MISMATCH %-16s declared applicable with floor %s, but returned not applicable\n' \
            "$gate" "$floor"
        printf '           a gate that decided this repository is out of scope has not\n'
        printf '           checked it -- that is a change to what is covered, not a pass\n'
        fail=1
    elif [ "$scanned" -lt "$floor" ]; then
        printf '  BELOW    %-16s scanned %s %s, floor is %s\n' "$gate" "$scanned" "$unit" "$floor"
        printf '           the gate ran and examined less than declared: scope shrank\n'
        fail=1
    else
        printf '  OK       %-16s scanned %s %s (floor %s)\n' "$gate" "$scanned" "$unit" "$floor"
    fi
done < "$tmp"

# Now the other direction: a gate that RAN and has no declaration.
#
# This script iterated the floors file and never looked at the reports, so a
# gate could run, write a report, and be silently unenforced -- while the header
# above claimed "A gate with no entry is an error rather than a pass. Silence is
# how scope quietly shrinks." That claim was false for as long as it has been
# written here. Measured: five valid reports plus a floors file containing only
# `docs=3` reported "1 declared gate(s) checked" and exited 0, with four gates
# never examined.
#
# The correct implementation already existed twenty lines away, in
# prove-gates-fail.sh, which loops over gates/*.sh and errors with "a gate with
# no floor opts itself out of scope-reduction detection". The mechanism was
# ported to consumers and the loop was inverted on the way.
for report in "$REPORTS"/*.json; do
    [ -e "$report" ] || continue
    rgate="$(basename "$report" .json)"
    case " $declared " in
        *" $rgate "*) ;;
        *)
            printf '  UNDECLARED %-14s ran and wrote a report, but %s does not declare it\n' \
                "$rgate" "$FLOORS"
            printf '             an undeclared gate is exempt from every check in this file\n'
            fail=1
            ;;
    esac
done

# An empty floors file would otherwise report success having enforced nothing --
# the vacuity rule, applied to the thing that enforces the vacuity rule.
if [ "$checked" -eq 0 ]; then
    printf '\n%s declares no gates. A floors file that enforces nothing is not a floors file.\n' \
        "$FLOORS" >&2
    exit 2
fi

printf '\n%d declared gate(s) checked against %s\n' "$checked" "$FLOORS"
exit "$fail"
