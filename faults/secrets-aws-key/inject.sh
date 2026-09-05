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
# The key IDENTIFIER is fixed, and the randomness that used to be here made this
# fault a dice roll.
#
# The shape was always right -- AKIA plus 16 uppercase alphanumerics, asserted
# below -- and the rule that fired still varied run to run, because gitleaks'
# aws-access-token rule applies an entropy test to the identifier and a random
# [A-Z0-9]{16} sometimes falls under it. Measured over ten generated ids planted
# alone: aws-access-token twice, generic-api-key seven times, and once NOTHING
# AT ALL -- a well-formed cloud credential that the scanner did not report.
#
# That produced a harness whose result depended on the draw. A fresh clone
# reported "26 proven, 1 mismatched" against the working tree's 27 and 0, on the
# same commit with the same pinned scanner. A proof that is only usually true is
# not a proof, and this one is the corpus entry whose whole job is to assert the
# RULE rather than merely the exit code.
#
# The identifier below is fixed and verified: 6 of 6 runs report
# aws-access-token. It is assembled from two fragments so the complete
# 20-character string never appears in this repository, whose own history this
# gate scans. It authenticates to nothing.
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

_kid_a="P6CFHLNX"; _kid_b="PYTR4M5I"
keyid="AKIA${_kid_a}${_kid_b}"
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
