#!/usr/bin/env bash
# pr-open.sh <repo> <branch> -- opens a PR titled after the branch's FIRST
# commit, with every commit message in the body, plus a footer recording what
# actually opened it.
set -euo pipefail
DIR="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

repo="${1:?usage: pr-open.sh <repo> <branch>}"
branch="${2:?usage: pr-open.sh <repo> <branch>}"
gh_check_repo "$repo"

tree="/mnt/raid1/$repo"
# Title from the FIRST commit on the branch, body from all of them.
#
# Both used to read the branch tip with -1, which is the least representative
# commit of a multi-commit branch: the last thing written is usually a doc
# touch-up or a fixup. The squash title on main is what anyone reads in
# `git log --oneline`, and a 700-line change to the ingest path merged under
# the title "docs: document the ingest contract" because of this. The body was
# worse -- three of four commit messages never reached the pull request at all,
# and survived only because GitHub concatenates them when squashing.
base=$(git -C "$tree" merge-base "origin/main" "$branch")
mapfile -t shas < <(git -C "$tree" rev-list --reverse "$base..$branch")
if [ "${#shas[@]}" -eq 0 ]; then
    printf 'ERROR: %s has no commits that main does not already have\n' "$branch" >&2
    exit 1
fi
title=$(git -C "$tree" log --format=%s -1 "${shas[0]}")
if [ "${#shas[@]}" -eq 1 ]; then
    body=$(git -C "$tree" log --format=%b -1 "${shas[0]}")
else
    # Headed by subject so the reader can tell where one commit ends and the
    # next begins; ordered oldest first, which is the order they were reasoned in.
    body=$(git -C "$tree" log --reverse --format='### %s%n%n%b' "$base..$branch")
fi

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
