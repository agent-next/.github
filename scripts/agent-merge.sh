#!/usr/bin/env bash
# agent-merge: merge ONE PR only when its current head has agent-review=success and all required
# checks pass. The merger never reviews; it only checks the gate and merges that exact SHA.
# usage: AGENT_REVIEW_POSTERS=<login>[,<login>...] agent-merge.sh <owner/repo> <pr>
# tests: bash tests/agent-merge.test.sh (hermetic; gh is a shim)
# Trust boundary: GitHub lets anyone with write access post a commit status, so the gate only counts
# the latest agent-review status if its creator is one of the reviewer identities in
# AGENT_REVIEW_POSTERS (required; no default, so an unconfigured merger fails closed).
set -euo pipefail
R=$1; PR=$2
# every gh call has a hard limit (AGENT_MERGE_NET_TIMEOUT seconds, default 300) so a stalled link
# cannot hang the merger; a timed-out lookup leaves the gate closed
NET_TIMEOUT=${AGENT_MERGE_NET_TIMEOUT:-300}
GH=$(command -v gh); gh(){ timeout -k 30 "$NET_TIMEOUT" "$GH" "$@"; }
HEAD=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
POSTERS=${AGENT_REVIEW_POSTERS:?set AGENT_REVIEW_POSTERS to the reviewer identities allowed to post agent-review}
# the latest agent-review status (by created_at, across all pages) is the only one that counts
read -r AR BY < <(gh api "repos/$R/commits/$HEAD/statuses?per_page=100" --paginate --slurp |
  jq -r '[.[][]|select(.context=="agent-review")]|sort_by(.created_at, .id)|last|"\(.state // "absent") \(.creator.login // "-")"')
[ "$AR" = success ] || { echo "BLOCKED: agent-review=$AR on ${HEAD:0:7}"; exit 2; }
case ",$POSTERS," in *",$BY,"*) ;; *) echo "BLOCKED: agent-review on ${HEAD:0:7} posted by $BY, not in AGENT_REVIEW_POSTERS"; exit 2 ;; esac
gh pr checks "$PR" -R "$R" --required >/dev/null || { echo "BLOCKED: required checks not green"; gh pr checks "$PR" -R "$R" --required || true; exit 2; }
NOW=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
[ "$NOW" = "$HEAD" ] || { echo "BLOCKED: head moved ${HEAD:0:7} -> ${NOW:0:7} during the gate check; rerun"; exit 2; }
gh pr merge "$PR" -R "$R" --squash --match-head-commit "$HEAD"
gh pr view "$PR" -R "$R" --json state,mergeCommit -q '"'"$R"'#'"$PR"': \(.state) \(.mergeCommit.oid[0:7])"'
