#!/usr/bin/env bash
# pr-status.sh <repo> <number>
set -euo pipefail
DIR="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

repo="${1:?usage: pr-status.sh <repo> <number>}"
n="${2:?usage: pr-status.sh <repo> <number>}"
gh_check_repo "$repo"; gh_check_number "$n"

pr=$(gh_api GET "https://api.github.com/repos/$GH_OWNER/$repo/pulls/$n")
sha=$(jq -r .head.sha <<<"$pr")
state=$(jq -r .mergeable_state <<<"$pr")
checks=$(gh_api GET "https://api.github.com/repos/$GH_OWNER/$repo/commits/$sha/check-runs")
printf '%-16s #%s  state=%-9s ' "$repo" "$n" "$state"
jq -r '[.check_runs[] | "\(.name)=\(.conclusion // .status)"] | join(" ")' <<<"$checks"
