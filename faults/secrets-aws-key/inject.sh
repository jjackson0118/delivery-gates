#!/usr/bin/env bash
# Plants an AWS-shaped credential in a scratch clone.
#
# Generated at runtime, never committed to this repository. Three reasons:
#
#   - Nothing is ever pushed, so GitHub push protection -- a pre-receive hook --
#     cannot see it. That is operating outside the control's scope rather than
#     evading the control.
#   - A committed fixture credential would poison this repository's own history
#     scan forever, to prove a point once.
#   - The canonical AKIAIOSFODNN7EXAMPLE key is allowlisted by gitleaks and by
#     GitHub precisely because it is the documented example. Using it, the
#     scanner exits 0 and the proof proves nothing.
#
# Random bytes authenticate to nothing, so the planted value is inert.
#
# The key id must be exactly AKIA + 16 uppercase alphanumerics or gitleaks
# classifies it as generic-api-key rather than aws-access-token. The first
# version of this script filtered base64 down to [A-Z0-9] and sometimes came up
# short, so the harness saw the right exit code for the wrong reason -- which is
# precisely what asserting the rule id, rather than only the exit code, exists
# to catch.
set -euo pipefail

rand_upper() {  # rand_upper <n>
    local n="$1" out=""
    while [ "${#out}" -lt "$n" ]; do
        out+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Z0-9')
    done
    printf '%s' "${out:0:$n}"
}
rand_mixed() {
    local n="$1" out=""
    while [ "${#out}" -lt "$n" ]; do
        out+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9/+')
    done
    printf '%s' "${out:0:$n}"
}

keyid="AKIA$(rand_upper 16)"
secret="$(rand_mixed 40)"

[ "${#keyid}" -eq 20 ] || { echo "generated key id is ${#keyid} chars, expected 20" >&2; exit 1; }
[ "${#secret}" -eq 40 ] || { echo "generated secret is ${#secret} chars, expected 40" >&2; exit 1; }

cat > planted-credentials.tf <<TF
provider "aws" {
  access_key = "${keyid}"
  secret_key = "${secret}"
}
TF
git add planted-credentials.tf
git -c user.email=fault@local -c user.name=fault commit -qm "fault: planted credential"
