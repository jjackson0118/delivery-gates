#!/usr/bin/env bash
# pr-merge.sh <repo> <number> -- squash-merges only when the ruleset allows it.
#
# Squash because the ruleset requires linear history. The merge is attempted
# rather than forced: if a required check has not passed, GitHub refuses and
# this reports why. Nothing here bypasses a gate, and with an empty bypass list
# and no Administration permission on the token, nothing could.
set -euo pipefail
DIR="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

repo="${1:?usage: pr-merge.sh <repo> <number>}"
n="${2:?usage: pr-merge.sh <repo> <number>}"
gh_check_repo "$repo"; gh_check_number "$n"

pr=$(gh_api GET "https://api.github.com/repos/$GH_OWNER/$repo/pulls/$n")
branch=$(jq -r .head.ref <<<"$pr")
title=$(jq -r .title <<<"$pr")

out=$(gh_api PUT "https://api.github.com/repos/$GH_OWNER/$repo/pulls/$n/merge" \
    -d "$(jq -n --arg t "$title" '{merge_method:"squash", commit_title:$t}')")

if [ "$(jq -r '.merged // false' <<<"$out")" = "true" ]; then
    printf 'MERGED  %s #%s  %s\n' "$repo" "$n" "$(jq -r .sha <<<"$out" | cut -c1-7)"
    gh_api DELETE "https://api.github.com/repos/$GH_OWNER/$repo/git/refs/heads/$branch" >/dev/null \
        && printf '  branch %s deleted\n' "$branch"
else
    printf 'REFUSED %s #%s: %s\n' "$repo" "$n" "$(jq -r .message <<<"$out")"
fi
