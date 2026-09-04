#!/usr/bin/env bash
# pr-open.sh <repo> <branch> -- opens a PR whose body is the branch's commit
# message plus a footer recording what actually opened it.
set -euo pipefail
DIR="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

repo="${1:?usage: pr-open.sh <repo> <branch>}"
branch="${2:?usage: pr-open.sh <repo> <branch>}"
gh_check_repo "$repo"

tree="/mnt/raid1/$repo"
title=$(git -C "$tree" log --format=%s -1 "$branch")
body=$(git -C "$tree" log --format=%b -1 "$branch")

# Says what is true rather than what sounds reassuring. An earlier version of
# this footer said "required checks are enforced identically either way -- the
# ruleset bypass list is empty", which is true and worthless: the bypass list
# is empty AND the ruleset requires zero approvals, so nothing human stood
# between this branch and main. That sentence is in the permanent record of six
# merged pull requests, which is why this one is explicit.
footer=$'\n\n---\n\n_Opened and merged by automation on `testbed1`, authenticated by a fine-grained PAT owned by @jjackson0118 — so git records a human author where there was none. **Zero human approval is required to merge here** (`required_approving_review_count: 0`); the required status checks are the only thing standing in the way, and they are enforced on this token like anyone else (the ruleset bypass list is empty and the token holds no Administration permission)._'

payload=$(jq -n --arg t "$title" --arg h "$branch" --arg b "$body$footer" \
    '{title:$t, head:$h, base:"main", body:$b}')

gh_api POST "https://api.github.com/repos/$GH_OWNER/$repo/pulls" -d "$payload" \
    | jq -r 'if .number then "PR #\(.number)  \(.html_url)" else "ERROR: \(.message) \(.errors // "")" end'
