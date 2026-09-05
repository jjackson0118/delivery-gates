#!/usr/bin/env bash
# Plants a key, then suppresses it the way the repository under test would:
# by committing the exact fingerprint gitleaks reports for that finding.
#
# The fingerprint is commit:path:rule:line, and the commit sha is not known
# until the key is committed, so it is read back rather than hardcoded.
set -euo pipefail
command -v openssl >/dev/null || { echo "openssl required" >&2; exit 1; }

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out deploy_key.pem 2>/dev/null
git add deploy_key.pem
git -c user.email=fault@local -c user.name=fault commit -qm "fault: planted private key"

sha=$(git rev-parse HEAD)
line=$(grep -n 'BEGIN' deploy_key.pem | head -1 | cut -d: -f1)
printf '%s:deploy_key.pem:private-key:%s\n' "$sha" "$line" > .gitleaksignore
git add .gitleaksignore
git -c user.email=fault@local -c user.name=fault commit -qm "fault: suppress the finding"
