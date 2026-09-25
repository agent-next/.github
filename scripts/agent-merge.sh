#!/usr/bin/env bash
# agent-merge: merge ONE PR only when its current head has agent-review=success and all required
# checks pass. The merger never reviews; it only checks the gate and merges that exact SHA.
# usage: AGENT_REVIEW_POSTERS=<login>[,<login>...] agent-merge.sh <owner/repo> <pr>
# Trust boundary: GitHub lets anyone with write access post a commit status, so the gate only counts
# the latest agent-review status if its creator is one of the reviewer identities in
# AGENT_REVIEW_POSTERS (required; no default, so an unconfigured merger fails closed).
set -euo pipefail
R=$1; PR=$2
HEAD=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
POSTERS=${AGENT_REVIEW_POSTERS:?set AGENT_REVIEW_POSTERS to the reviewer identities allowed to post agent-review}
# statuses are newest first; only the latest agent-review status counts
read -r AR BY < <(gh api "repos/$R/commits/$HEAD/statuses" --paginate \
  -q '[.[]|select(.context=="agent-review")]|first|"\(.state // "absent") \(.creator.login // "-")"')
[ "$AR" = success ] || { echo "BLOCKED: agent-review=$AR on ${HEAD:0:7}"; exit 2; }
case ",$POSTERS," in *",$BY,"*) ;; *) echo "BLOCKED: agent-review on ${HEAD:0:7} posted by $BY, not in AGENT_REVIEW_POSTERS"; exit 2 ;; esac
gh pr checks "$PR" -R "$R" --required >/dev/null || { echo "BLOCKED: required checks not green"; gh pr checks "$PR" -R "$R" --required; exit 2; }
gh pr merge "$PR" -R "$R" --squash --match-head-commit "$HEAD"
gh pr view "$PR" -R "$R" --json state,mergeCommit -q '"'"$R"'#'"$PR"': \(.state) \(.mergeCommit.oid[0:7])"'
