#!/usr/bin/env bash
# agent-review: independent agent review of ONE pull request at ONE head SHA, recorded as the
# commit status `agent-review` on that SHA (the agent-native merge gate; no human approval).
# A new push creates a new SHA without the status, so stale reviews never count.
# usage: agent-review.sh <owner/repo> <pr> [--post]   (without --post: dry run, no status/comment)
# Reviewer chain: grok -> agy -> gpt6pro (override with AGENT_REVIEWER); never the writer's model family. Receipts go to $AGENT_REVIEW_OUT (default ./agent-review-receipts).
set -euo pipefail
R=$1; PR=$2; POST=${3:-}
OUT=${AGENT_REVIEW_OUT:-$PWD/agent-review-receipts}; mkdir -p "$OUT"
HEAD=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
REC="$OUT/$(echo "$R" | tr / _)-pr$PR-${HEAD:0:7}.md"

status(){ [ "$POST" = --post ] || return 0
  gh api -X POST "repos/$R/statuses/$HEAD" -f state="$1" -f context=agent-review -f description="$2" >/dev/null; }

status pending "${AGENT_REVIEWER:-grok} review running"
# https + gh credential helper: works for private repos and does not depend on ssh
git -c credential.helper='!gh auth git-credential' clone -q --filter=blob:none "https://github.com/$R.git" "$WORK/src"
git -C "$WORK/src" config credential.helper '!gh auth git-credential'
git -C "$WORK/src" fetch -q origin "pull/$PR/head" && git -C "$WORK/src" checkout -q --detach "$HEAD"
gh pr view "$PR" -R "$R" --json title,body,baseRefName,files -q '"TITLE: \(.title)\nBASE: \(.baseRefName)\nFILES: \([.files[].path]|join(", "))\n\nBODY:\n\(.body)"' > "$WORK/pr.txt"
gh pr view "$PR" -R "$R" --json commits -q '"\nCOMMITS:\n" + ([.commits[] | "--- \(.oid[0:7])\n\(.messageHeadline)\n\(.messageBody)"] | join("\n"))' >> "$WORK/pr.txt"
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
(REQUEST_CHANGES iff any blocker or major; AI-attribution text and broken links are always major)."
# Reviewer chain (owner decisions 2026-09-25): grok -> agy -> gpt6pro; a lane that reports it is out
# of quota is skipped. gpt6pro has no filesystem, so it gets the PR metadata and diff inline.
GPT6PRO=${GPT6PRO_BIN:-gpt6pro}
review_with(){ case "$1" in
  grok) (cd "$WORK/src" && timeout 1500 grok --always-approve --cwd "$WORK/src" -p "$PROMPT") ;;
  agy)  (cd "$WORK/src" && timeout 1500 agy --dangerously-skip-permissions --add-dir "$WORK" -p "$PROMPT") ;;
  gpt6pro) { printf '%s\n\nNo checkout is available to you; the PR metadata and diff are inline below.\n=== PR METADATA ===\n' "$PROMPT"
             cat "$WORK/pr.txt"; printf '\n=== DIFF (truncated at 120000 bytes) ===\n'; head -c 120000 "$WORK/pr.diff"; } > "$WORK/gpt6pro-prompt.txt"
           timeout 1500 "$GPT6PRO" "$(cat "$WORK/gpt6pro-prompt.txt")" ;;
  *) echo "unknown reviewer $1"; return 64 ;;
esac; }
OUTQ='402 Payment Required|usage balance exhausted|RESOURCE_EXHAUSTED|quota reached|rate limit'
for REVIEWER in ${AGENT_REVIEWER:-grok agy gpt6pro}; do
  review_with "$REVIEWER" > "$WORK/review.txt" 2>&1 || true
  grep -qiE "$OUTQ" "$WORK/review.txt" || break
  echo "reviewer $REVIEWER unavailable: $(grep -m1 -oiE "$OUTQ" "$WORK/review.txt")" >&2
done
VERDICT=$(grep -oE "VERDICT: (APPROVE|REQUEST_CHANGES)" "$WORK/review.txt" | tail -1 | cut -d" " -f2 || true)

NOW=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
{ echo "# agent-review $R#$PR @ $HEAD"; echo "reviewer: $REVIEWER · $(date -Is)"; echo "verdict: ${VERDICT:-NONE}"
  [ "$NOW" = "$HEAD" ] || echo "NOTE: head moved to $NOW during review; status not posted"; echo; cat "$WORK/review.txt"; } > "$REC"

[ "$NOW" = "$HEAD" ] || { echo "head moved; rerun"; exit 3; }
case "$VERDICT" in
  APPROVE) status success "$REVIEWER: approve" ;;
  REQUEST_CHANGES) status failure "$REVIEWER: changes requested" ;;
  *) status error "$REVIEWER: no verdict (see receipt)" ;;
esac
if [ "$POST" = --post ]; then
  { echo "**agent-review** ($REVIEWER) at \`${HEAD:0:7}\`: **${VERDICT:-NO VERDICT}**"; echo; echo '<details><summary>review</summary>'; echo; cat "$WORK/review.txt"; echo; echo '</details>'; } > "$WORK/comment.md"
  gh pr comment "$PR" -R "$R" -F "$WORK/comment.md" >/dev/null
fi
echo "$R#$PR ${HEAD:0:7} verdict=${VERDICT:-NONE} receipt=$REC"
[ "$VERDICT" = APPROVE ]
