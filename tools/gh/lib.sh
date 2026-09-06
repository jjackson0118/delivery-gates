#!/usr/bin/env bash
# Shared helpers for the GitHub automation scripts.
#
# These scripts live in the repository rather than in ~/bin because they were
# the only shell in this system that no gate ever linted -- automation that
# opens and merges pull requests, exempt from the checks it exists to run.
# Under tools/ the shellcheck gate covers them like everything else.
#
# THE TOKEN NEVER APPEARS IN argv. The first version passed it as
# `curl -H "Authorization: Bearer $tok"`, which puts the credential in
# /proc/<pid>/cmdline for the lifetime of every call -- readable by every other
# local user and by anything with host PID visibility. curl reads it from
# stdin instead.

set -uo pipefail
set +x   # explicit: `bash -x` on these scripts would otherwise print the token

GH_TOKEN_FILE="${GH_TOKEN_FILE:-$HOME/.config/gh-token}"
GH_OWNER="${GH_OWNER:-jjackson0118}"

# Only these repositories. The scripts interpolate the name into an API path,
# so without this a value like '../../orgs/x' reshapes the request. Harmless
# against a token scoped to two repos; not harmless the day that changes.
gh_check_repo() {
    case "$1" in
        delivery-gates|dora-loop) ;;
        *) printf 'refusing unknown repo: %s\n' "$1" >&2; exit 2 ;;
    esac
}

gh_check_number() {
    case "$1" in
        ''|*[!0-9]*) printf 'not a pull request number: %s\n' "$1" >&2; exit 2 ;;
    esac
}

# gh_api <METHOD> <url> [curl args...]
gh_api() {
    local method="$1" url="$2"; shift 2
    [ -r "$GH_TOKEN_FILE" ] || { printf 'no token at %s\n' "$GH_TOKEN_FILE" >&2; exit 2; }
    printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' \
        "$(cat "$GH_TOKEN_FILE")" \
        | curl -sS -K - --connect-timeout 10 --max-time 60 -X "$method" "$url" "$@"
}
