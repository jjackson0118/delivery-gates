#!/usr/bin/env bash
# Cites a plausible path that is not there -- the shape a citation takes after
# the file it names is renamed or deleted.
set -euo pipefail
readme=$(find . -maxdepth 1 -iname 'README.md' | head -1)
[ -n "$readme" ] || { echo "no README to modify" >&2; exit 1; }
printf '\nSee core/src/main/java/does/not/Exist.java:42 for details.\n' >> "$readme"
