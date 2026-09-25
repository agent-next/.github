#!/usr/bin/env bash
# agent-review: independent agent review of ONE pull request at ONE head SHA, recorded as the
# commit status `agent-review` on that SHA (the agent-native merge gate; no human approval).
# A new push creates a new SHA without the status, so stale reviews never count.
# usage: agent-review.sh <owner/repo> <pr> [--post]   (without --post: dry run, no status/comment)
# Reviewer lane: grok (review-only lane, never a writer). Receipts go to $AGENT_REVIEW_OUT (default ./agent-review-receipts).
set -euo pipefail
R=$1; PR=$2; POST=${3:-}
OUT=${AGENT_REVIEW_OUT:-$PWD/agent-review-receipts}; mkdir -p "$OUT"
HEAD=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
REC="$OUT/$(echo "$R" | tr / _)-pr$PR-${HEAD:0:7}.md"

status(){ [ "$POST" = --post ] || return 0
  gh api -X POST "repos/$R/statuses/$HEAD" -f state="$1" -f context=agent-review -f description="$2" >/dev/null; }

status pending "grok review running"
gh repo clone "$R" "$WORK/src" -- -q --filter=blob:none
git -C "$WORK/src" fetch -q origin "pull/$PR/head" && git -C "$WORK/src" checkout -q --detach "$HEAD"
gh pr view "$PR" -R "$R" --json title,body,baseRefName,files -q '"TITLE: \(.title)\nBASE: \(.baseRefName)\nFILES: \([.files[].path]|join(", "))\n\nBODY:\n\(.body)"' > "$WORK/pr.txt"
gh pr diff "$PR" -R "$R" > "$WORK/pr.diff"

PROMPT="You are the independent reviewer for pull request $R#$PR at head $HEAD. The checkout in the
current directory is that exact commit. PR metadata: $WORK/pr.txt. Full diff: $WORK/pr.diff.
Review THIS PR only, in detail, file by file: correctness bugs, security (secrets, injection, unsafe
permissions), missing or fake tests for changed behavior, broken links/references, public-repo hygiene
(no internal plans/paths/hostnames in public repos), and AI-attribution text (Co-Authored-By AI,
'Generated with' footers) in commits or PR body (check: git log --format=%B origin/HEAD..HEAD).
Run the repo's own check command if cheap (see AGENTS.md / Makefile). Do not modify files.
Output: a findings list, each with file:line, severity (blocker/major/minor/nit) and evidence.
Last line exactly one of: VERDICT: APPROVE   or   VERDICT: REQUEST_CHANGES
(REQUEST_CHANGES iff any blocker or major)."
timeout 1500 grok --always-approve --cwd "$WORK/src" -p "$PROMPT" > "$WORK/review.txt" 2>&1 || true
VERDICT=$(grep -oE 'VERDICT: (APPROVE|REQUEST_CHANGES)' "$WORK/review.txt" | tail -1 | cut -d' ' -f2)

NOW=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
{ echo "# agent-review $R#$PR @ $HEAD"; echo "reviewer: grok · $(date -Is)"; echo "verdict: ${VERDICT:-NONE}"
  [ "$NOW" = "$HEAD" ] || echo "NOTE: head moved to $NOW during review; status not posted"; echo; cat "$WORK/review.txt"; } > "$REC"

[ "$NOW" = "$HEAD" ] || { echo "head moved; rerun"; exit 3; }
case "$VERDICT" in
  APPROVE) status success "grok: approve" ;;
  REQUEST_CHANGES) status failure "grok: changes requested" ;;
  *) status error "grok: no verdict (see receipt)" ;;
esac
if [ "$POST" = --post ]; then
  { echo "**agent-review** (grok) at \`${HEAD:0:7}\`: **${VERDICT:-NO VERDICT}**"; echo; echo '<details><summary>review</summary>'; echo; cat "$WORK/review.txt"; echo; echo '</details>'; } > "$WORK/comment.md"
  gh pr comment "$PR" -R "$R" -F "$WORK/comment.md" >/dev/null
fi
echo "$R#$PR ${HEAD:0:7} verdict=${VERDICT:-NONE} receipt=$REC"
[ "$VERDICT" = APPROVE ]
