#!/usr/bin/env bash
# Deletes the entire test suite. The most common real-world version of this is
# not deletion but a source-set path that silently stops matching after a
# refactor -- same outcome, no diff to review.
set -euo pipefail
find . -path '*/src/test/java/*' -name '*.java' -delete
find . -type d -empty -delete 2>/dev/null || true
