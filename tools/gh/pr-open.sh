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
# Refs are read from the remote, not from whatever this checkout last saw. A
# stale origin/main widens the base and puts already-merged commits in the body.
git -C "$tree" fetch --quiet --prune origin \
    || { printf 'ERROR: could not fetch origin\n' >&2; exit 1; }

base=$(git -C "$tree" merge-base "origin/main" "$branch") \
    || { printf 'ERROR: no merge base between origin/main and %s\n' "$branch" >&2; exit 1; }

# Enumerated through a temp file whose exit status is checked, never
# `mapfile < <(cmd)`.
#
# That construct runs the command in a subshell and DISCARDS its exit status,
# so a failed rev-list is indistinguishable from a branch with no commits, and
# a partial read silently truncates the list the title and body are built from.
# lib/gate.sh has gate_lines() for exactly this, faults/contract-broken-enumeration
# exists to prove it is caught, and its description calls it THE WORST ONE --
# and the first version of this change used it anyway. shellcheck at
# severity>=warning does not flag it, so nothing here caught it either.
shas_file=$(mktemp)
trap 'rm -f "$shas_file"' EXIT
# --topo-order, not --reverse alone: --reverse orders by COMMIT DATE, so a merge
# commit on the branch, a cherry-pick, or clock skew picks the wrong first
# commit -- the same class of wrong title this change exists to fix.
if ! git -C "$tree" rev-list --topo-order --reverse --no-merges "$base..$branch" > "$shas_file"; then
    printf 'ERROR: could not enumerate commits on %s\n' "$branch" >&2
    exit 1
fi
mapfile -t shas < "$shas_file"

if [ "${#shas[@]}" -eq 0 ]; then
    printf 'ERROR: %s has no commits that main does not already have\n' "$branch" >&2
    exit 1
fi

title=$(git -C "$tree" log --format=%s -1 "${shas[0]}")
if [ "${#shas[@]}" -eq 1 ]; then
    body=$(git -C "$tree" log --format=%b -1 "${shas[0]}")
else
    # Headed by subject so the reader can tell where one commit ends and the
    # next begins; oldest first, the order they were reasoned in.
    body=""
    for sha in "${shas[@]}"; do
        body+="### $(git -C "$tree" log --format=%s -1 "$sha")"$'\n\n'
        body+="$(git -C "$tree" log --format=%b -1 "$sha")"$'\n\n'
    done
fi

# Says what is true rather than what sounds reassuring. An earlier version of
# this footer said "required checks are enforced identically either way -- the
# ruleset bypass list is empty", which is true and worthless: the bypass list
# is empty AND the ruleset requires zero approvals, so nothing human stood
# between this branch and main. That sentence is in the permanent record of six
# merged pull requests, which is why this one is explicit.
footer=$'\n\n---\n\n_Opened and merged by automation on `testbed1`, authenticated by a fine-grained PAT owned by @jjackson0118 — so git records a human author where there was none. **Zero human approval is required to merge here** (`required_approving_review_count: 0`); the required status checks are the only thing standing in the way, and they are enforced on this token like anyone else (the ruleset bypass list is empty and the token holds no Administration permission)._'

# GitHub rejects a body over 65536 characters with a 422. Truncating with a
# visible marker beats losing the pull request, and the commits are still in
# git either way.
full_body="$body$footer"
limit=60000
if [ "${#full_body}" -gt "$limit" ]; then
    full_body="${full_body:0:$limit}"$'\n\n_[truncated: see the commits on the branch]_'"$footer"
fi

payload=$(jq -n --arg t "$title" --arg h "$branch" --arg b "$full_body" \
    '{title:$t, head:$h, base:"main", body:$b}')

# An API failure must not exit 0. curl without --fail exits 0 on a 4xx, and the
# jq ERROR branch exits 0 too, so every failure mode here -- a stale head, a
# validation error, an oversized body -- used to be reported as a line of text
# with a success status, which any caller reads as "the PR was opened".
response=$(gh_api POST "https://api.github.com/repos/$GH_OWNER/$repo/pulls" -d "$payload")
if [ -z "$(jq -r '.number // empty' <<<"$response")" ]; then
    printf 'ERROR: %s %s\n' \
        "$(jq -r '.message // "no response"' <<<"$response")" \
        "$(jq -c '.errors // empty' <<<"$response")" >&2
    exit 1
fi
jq -r '"PR #\(.number)  \(.html_url)"' <<<"$response"
