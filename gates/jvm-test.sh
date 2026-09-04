#!/usr/bin/env bash
# Runs the JVM test suite and asserts it actually ran something.
#
# "BUILD SUCCESSFUL" is not evidence that tests passed. Gradle prints it when
# the test task was UP-TO-DATE and never executed, when a source set is empty
# and the task reports NO-SOURCE, and when the suite genuinely passed. Three
# very different situations, one output.
#
# So this gate does not read the build's exit code as its verdict. It reads the
# JUnit XML and counts. Zero executed tests is an error, not a pass -- a suite
# that ran nothing is the purest form of a green result standing in for a
# measurement that never happened.
#
# --rerun-tasks is deliberate. Up-to-date checking is correct for a developer
# loop and wrong for a gate: a gate that can be satisfied by a cache entry is
# not observing the current tree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gate.sh
source "$SCRIPT_DIR/../lib/gate.sh"

gate_init "jvm-test" "tests"

TARGET="${1:-.}"
cd "$TARGET" || gate_error "cannot enter $TARGET"

[ -x ./gradlew ] || gate_error "no ./gradlew in $TARGET"
require_cmd python3

gate_tool "gradle wrapper ($(sed -n 's|.*gradle-\([0-9.]*\)-bin\.zip.*|\1|p' gradle/wrapper/gradle-wrapper.properties | head -1))"

set +e
./gradlew test --rerun-tasks --console=plain >/tmp/jvm-test-$$.log 2>&1
build_rc=$?
set -e

# The XML is the source of truth, not the exit code.
mapfile -t xml < <(find . -path '*/build/test-results/test/*.xml' -type f 2>/dev/null)
if [ "${#xml[@]}" -eq 0 ]; then
    tail -20 "/tmp/jvm-test-$$.log" >&2
    rm -f "/tmp/jvm-test-$$.log"
    gate_error "no JUnit XML produced -- the test task did not run, which is not a pass"
fi

read -r total failures errors skipped < <(python3 - "${xml[@]}" <<'PY'
import sys, xml.etree.ElementTree as ET
t=f=e=s=0
for p in sys.argv[1:]:
    try:
        r = ET.parse(p).getroot()
    except Exception:
        continue
    for suite in ([r] if r.tag == "testsuite" else r.iter("testsuite")):
        t += int(suite.get("tests", 0))
        f += int(suite.get("failures", 0))
        e += int(suite.get("errors", 0))
        s += int(suite.get("skipped", 0))
print(t, f, e, s)
PY
)

executed=$(( total - skipped ))

for _ in $(seq 1 "$failures"); do gate_finding "test-failure"; done
for _ in $(seq 1 "$errors");   do gate_finding "test-error"; done

# A green build with a red count, or vice versa, means the two disagree and
# neither should be trusted.
if [ "$build_rc" -eq 0 ] && [ $(( failures + errors )) -gt 0 ]; then
    gate_error "gradle exited 0 while JUnit XML reports $((failures+errors)) failure(s) -- the build result and the test results disagree"
fi
if [ "$build_rc" -ne 0 ] && [ $(( failures + errors )) -eq 0 ]; then
    tail -20 "/tmp/jvm-test-$$.log" >&2
    rm -f "/tmp/jvm-test-$$.log"
    gate_error "gradle exited $build_rc with no test failures recorded -- the build broke outside the suite"
fi
rm -f "/tmp/jvm-test-$$.log"

gate_note "executed=$executed skipped=$skipped failures=$failures errors=$errors"
gate_scanned "$executed"
gate_finish
