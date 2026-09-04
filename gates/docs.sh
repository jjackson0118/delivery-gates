#!/usr/bin/env bash
# Checks documentation against the code it describes.
#
# Prose about a moving system drifts, silently, and reads as authoritative the
# whole time. This repository has already shipped a README claiming "7 proven"
# against an actual 13, a Jenkins wrapper that did not exist, a gate mode wired
# to nothing, and a module documented in a Layout block that the build
# deliberately refused to include. An adversarial review found those; a review
# is not a control.
#
# What this gate checks is only the mechanical half -- the claims that can be
# resolved against the tree. Whether a paragraph is *true* still needs a reader.
# But "does this file exist", "does this line number exist", "does the number in
# the prose match the corpus" are decidable, and those were most of the findings.
#
# The denominator is the number of claims checked, so a refactor that stops the
# extraction from matching anything shows up as a small number rather than as
# silence.

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gate.sh
source "$SCRIPT_DIR/../lib/gate.sh" || {
    printf 'FATAL: cannot load the gate contract from %s\n' "$SCRIPT_DIR/../lib/gate.sh" >&2
    exit 2
}

gate_init "docs" "documented claims"
gate_tool "docs.sh (internal)"

TARGET="${1:-.}"
cd "$TARGET" || gate_error "cannot enter $TARGET"

docs=()
gate_lines docs find . -name '*.md' -not -path './.git/*' -not -path './.work/*'
if [ "${#docs[@]}" -eq 0 ]; then
    gate_not_applicable "no markdown files in this repository"
fi

claims=0
report() { printf '   %s\n' "$1" >&2; }

# --- 1. source citations resolve, to a file and to a line ------------------
# Ported from a documentation auditor on another system that validates every
# file:line citation against the repository at HEAD. Broken citations there went
# from 65 to 0 once something checked them.
cites=()
gate_lines cites bash -c '
    grep -ohnE "[A-Za-z0-9_./-]+\.(sh|java|kts|yml|yaml|md|properties):[0-9]+" "$@" | sort -u
' _ "${docs[@]}"
for c in "${cites[@]:-}"; do
    [ -n "$c" ] || continue
    ref="${c#*:}"                      # strip the grep line number
    file="${ref%%:*}"; line="${ref##*:}"
    case "$file" in http*|*@*) continue ;; esac
    claims=$(( claims + 1 ))
    if [ ! -f "$file" ]; then
        gate_finding "citation-missing-file"
        report "cited file does not exist: $file (from $ref)"
    elif [ "$(wc -l < "$file")" -lt "$line" ]; then
        gate_finding "citation-line-out-of-range"
        report "cited line beyond end of file: $ref"
    fi
done

# --- 2. every gate is documented, and every documented gate exists ---------
# Sections 2-5 describe this repository's own structure. A consumer that
# vendors this gate has markdown and citations but no gates/ or faults/, and
# must not be failed for the absence of something it never claimed to have.
if [ -d gates ] && [ -f README.md ]; then
onDisk=()
gate_lines onDisk bash -c 'for f in gates/*.sh; do basename "$f" .sh; done' _
for g in "${onDisk[@]:-}"; do
    [ -n "$g" ] || continue
    claims=$(( claims + 1 ))
    if ! grep -qF "\`$g\`" README.md 2>/dev/null; then
        gate_finding "gate-undocumented"
        report "gate exists but is not named in README.md: $g"
    fi
done
documented=()
gate_lines documented bash -c "grep -ohE '^\\*\\*\`[a-z0-9-]+\`\\*\\*' README.md 2>/dev/null | tr -d '*\`' || true"
for g in "${documented[@]:-}"; do
    [ -n "$g" ] || continue
    claims=$(( claims + 1 ))
    if [ ! -f "gates/$g.sh" ]; then
        gate_finding "documented-gate-missing"
        report "README documents a gate with no script: $g"
    fi
done

# --- 3. every fault named in prose exists ----------------------------------
if [ -d faults ]; then
named=()
gate_lines named bash -c "grep -ohE 'faults/[A-Za-z0-9_-]+' \"\$@\" | sort -u" _ "${docs[@]}"
for f in "${named[@]:-}"; do
    [ -n "$f" ] || continue
    # A trailing separator means the prose wrote a glob (faults/contract-*) and
    # the extraction stopped at the wildcard. That is a reference to a family,
    # not to a fault, and there is nothing to resolve.
    case "$f" in *-|*_) continue ;; esac
    claims=$(( claims + 1 ))
    if [ ! -d "$f" ]; then
        gate_finding "fault-missing"
        report "prose names a fault that does not exist: $f"
    fi
done

fi

# --- 4. the exit-code table matches the implementation ---------------------
for code in 0 1 2 3; do
    claims=$(( claims + 1 ))
    if ! grep -qE "^\| \`$code\` \|" README.md 2>/dev/null; then
        gate_finding "exit-code-undocumented"
        report "lib/gate.sh can exit $code but the README table does not list it"
    fi
done
tabled=()
gate_lines tabled bash -c "grep -oE '^\\| \`[0-9]+\` \\|' README.md 2>/dev/null | grep -oE '[0-9]+' || true"
for code in "${tabled[@]:-}"; do
    [ -n "$code" ] || continue
    claims=$(( claims + 1 ))
    case "$code" in
        0|1|2|3) ;;
        *) gate_finding "exit-code-not-implemented"
           report "README documents exit $code, which lib/gate.sh never produces" ;;
    esac
done

# --- 5. the claimed proof count matches the corpus -------------------------
# The harness proves one row per gate (quiet on clean input) plus one per fault.
# This is the check that would have caught "7 proven" standing against 13: the
# number was hand-transcribed, and nothing compared it to anything.
if grep -qE '[0-9]+ proven, [0-9]+ mismatched' README.md 2>/dev/null; then
    claims=$(( claims + 1 ))
    stated_p=$(grep -oE '[0-9]+ proven' README.md | head -1 | grep -oE '[0-9]+')
    stated_m=$(grep -oE '[0-9]+ mismatched' README.md | head -1 | grep -oE '[0-9]+')
    # One row per gate per fixture in direction 1, plus one per fault in
    # direction 2. The fixture count was implicit at 1 until the harness took
    # more than one, and this check went red on the change that introduced the
    # second -- correctly: the formula encoded an assumption that had stopped
    # being true, which is the drift it exists to find.
    n_gates=$(find gates -maxdepth 1 -name '*.sh' | wc -l)
    n_faults=$(find faults -maxdepth 1 -mindepth 1 -type d | wc -l)
    n_fixtures=$(find fixtures -maxdepth 1 -name '*.floors' 2>/dev/null | wc -l)
    [ "$n_fixtures" -eq 0 ] && n_fixtures=1
    expected=$(( n_gates * n_fixtures + n_faults ))
    if [ "$stated_p" != "$expected" ]; then
        gate_finding "proof-count-drift"
        report "README claims $stated_p proven; $n_gates gates x $n_fixtures fixtures + $n_faults faults = $expected"
    fi
    if [ "$stated_m" != "0" ]; then
        gate_finding "proof-count-mismatched-nonzero"
        report "README records $stated_m mismatched -- a published proof should be clean"
    fi
else
    gate_finding "proof-count-absent"
    report "README states no proof result at all"
fi

fi  # end sections 2-5

# --- 6. relative links resolve ---------------------------------------------
# Resolved relative to the file that contains the link, not to the repository
# root. The first version globbed every markdown file together and checked the
# targets from the root, so a correct link from docs/ to a sibling was reported
# as dead -- the gate was wrong about the one thing it was added to check.
for doc in "${docs[@]}"; do
    docdir="$(dirname "$doc")"
    links=()
    gate_lines links bash -c "grep -ohE '\\]\\([^)#][^)]*\\)' \"\$1\" | tr -d ']()' | sort -u" _ "$doc"
    for l in "${links[@]:-}"; do
        [ -n "$l" ] || continue
        case "$l" in http*|mailto:*|'#'*) continue ;; esac
        claims=$(( claims + 1 ))
        if [ ! -e "$docdir/$l" ]; then
            gate_finding "dead-relative-link"
            report "relative link does not resolve: $l (from $doc)"
        fi
    done
done

gate_note "checked $claims claims across ${#docs[@]} markdown file(s)"
gate_scanned "$claims"
gate_finish
