#!/usr/bin/env bash
# agent-merge: merge ONE PR only when its current head has agent-review=success and all required
# checks pass. The merger never reviews; it only checks the gate and merges that exact SHA.
# usage: agent-merge.sh <owner/repo> <pr>
set -euo pipefail
R=$1; PR=$2
HEAD=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
AR=$(gh api "repos/$R/commits/$HEAD/status" -q '[.statuses[]|select(.context=="agent-review")|.state]|first // "absent"')
[ "$AR" = success ] || { echo "BLOCKED: agent-review=$AR on ${HEAD:0:7}"; exit 2; }
gh pr checks "$PR" -R "$R" --required >/dev/null || { echo "BLOCKED: required checks not green"; gh pr checks "$PR" -R "$R" --required; exit 2; }
gh pr merge "$PR" -R "$R" --squash --match-head-commit "$HEAD"
gh pr view "$PR" -R "$R" --json state,mergeCommit -q '"'"$R"'#'"$PR"': \(.state) \(.mergeCommit.oid[0:7])"'
