#!/usr/bin/env bash
# Generates a throwaway RSA key at runtime. It is real key material and it is
# therefore never committed to this repository -- it exists for the seconds the
# scratch clone lives, and it protects nothing.
set -euo pipefail
command -v openssl >/dev/null || { echo "openssl required" >&2; exit 1; }
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out deploy_key.pem 2>/dev/null
git add deploy_key.pem
git -c user.email=fault@local -c user.name=fault commit -qm "fault: planted private key"
