#!/usr/bin/env bash
# Inverts one assertion in the suite.
set -euo pipefail
f=$(find . -name 'MetricTest.java' | head -1)
[ -n "$f" ] || { echo "MetricTest.java not found" >&2; exit 1; }
sed -i 's/assertThat(m.observedN()).isZero();/assertThat(m.observedN()).isEqualTo(999);/' "$f"
grep -q 'isEqualTo(999)' "$f" || { echo "injection did not apply" >&2; exit 1; }
