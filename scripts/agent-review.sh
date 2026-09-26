#!/usr/bin/env bash
# agent-review: independent agent review of ONE pull request at ONE head SHA, recorded as the
# commit status `agent-review` on that SHA (the agent-native merge gate; no human approval).
# A new push creates a new SHA without the status, so stale reviews never count.
# usage: agent-review.sh <owner/repo> <pr> [--post]   (without --post: dry run, no status/comment)
# tests: bash tests/agent-review.test.sh (hermetic; gh, git and the lane are shims)
# Reviewer chain: grok -> agy -> devin -> devin-sol -> gpt6pro (AGENT_REVIEWER overrides the order); a lane of the writer's model family (AGENT_WRITER_FAMILY) is refused. Receipts go to $AGENT_REVIEW_OUT (default ./agent-review-receipts).
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: agent-review.sh <owner/repo> <pr> [--post]" >&2; exit 64; }
R=$1; PR=$2; POST=${3:-}
OUT=${AGENT_REVIEW_OUT:-$PWD/agent-review-receipts}; mkdir -p "$OUT"
# network steps must not hang the gate: every gh/git network call has a hard limit
# (AGENT_REVIEW_NET_TIMEOUT seconds, default 900; SIGKILL 30 s later), and git also aborts a
# transfer below 1 KB/s for 120 s; a stalled clone once ran 75 min
NET_TIMEOUT=${AGENT_REVIEW_NET_TIMEOUT:-900}
KILL_AFTER=${AGENT_REVIEW_KILL_AFTER:-30}   # SIGKILL this long after SIGTERM, for net and lane limits
net(){ timeout -k "$KILL_AFTER" "$NET_TIMEOUT" "$@"; }
HEAD=$(net gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
WORK=$(mktemp -d); STATE=none   # none -> pending -> final (final = a terminal status was posted)
ABORT="review aborted before a verdict (see runner log)"
# never leave a stale pending status: an abort after "pending" is recorded as error on the head
cleanup(){ [ "$STATE" != pending ] || status error "$ABORT" || true; rm -rf "$WORK"; }
trap cleanup EXIT   # bash also runs this on SIGTERM (verified, bash 5.2; see tests)
REC="$OUT/$(echo "$R" | tr / _)-pr$PR-${HEAD:0:7}.md"

status(){ [ "$POST" = --post ] || return 0
  net gh api -X POST "repos/$R/statuses/$HEAD" -f state="$1" -f context=agent-review -f description="$2" >/dev/null; }

STATE=pending; status pending "review running"   # pending first: a post killed after GitHub recorded it still gets overwritten by cleanup
# https + gh credential helper: works for private repos and does not depend on ssh
SLOW=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=120)
net git "${SLOW[@]}" -c credential.helper='!gh auth git-credential' clone -q --filter=blob:none "https://github.com/$R.git" "$WORK/src"
git -C "$WORK/src" config credential.helper '!gh auth git-credential'
git -C "$WORK/src" config http.lowSpeedLimit 1000
git -C "$WORK/src" config http.lowSpeedTime 120
net git -C "$WORK/src" fetch -q origin "pull/$PR/head"
net git -C "$WORK/src" checkout -q --detach "$HEAD"   # blob:none: checkout fetches blobs
[ "$(git -C "$WORK/src" rev-parse HEAD)" = "$HEAD" ] || { echo "checkout is not $HEAD; refusing to review" >&2; status error "checkout mismatch"; STATE=final; exit 4; }
net gh pr view "$PR" -R "$R" --json title,body,baseRefName,files -q '"TITLE: \(.title)\nBASE: \(.baseRefName)\nFILES: \([.files[].path]|join(", "))\n\nBODY:\n\(.body)"' > "$WORK/pr.txt"
net gh pr view "$PR" -R "$R" --json commits -q '"\nCOMMITS:\n" + ([.commits[] | "--- \(.oid[0:7])\n\(.messageHeadline)\n\(.messageBody)"] | join("\n"))' >> "$WORK/pr.txt"
net gh pr diff "$PR" -R "$R" > "$WORK/pr.diff"

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
# Reviewer chain (owner decisions 2026-09-25/26): grok -> agy -> devin -> devin-sol -> gpt6pro. Each lane is a different model
# family; a lane whose family equals the writer's ($AGENT_WRITER_FAMILY, default anthropic) is refused.
# A lane result counts only if the lane exited 0 AND printed a VERDICT line; otherwise the next lane runs.
declare -A FAMILY=([grok]=xai [agy]=google [devin]=cognition [devin-sol]=openai [gpt6pro]=openai)
# the devin CLI runs several vendors' models; each devin lane pins one so the family map holds.
# devin-sol is paid (owner decision 2026-09-26) and only reviews PRs written by devin's own swe-2 family.
declare -A DEVIN_MODEL=([devin]=swe-2-max [devin-sol]=gpt-6-sol-high)
WRITER_FAMILY=${AGENT_WRITER_FAMILY:-anthropic}
GPT6PRO=${GPT6PRO_BIN:-gpt6pro}
# gpt6pro hands the prompt to its model client in one env string, capped at 128 KiB by Linux
INLINE_MAX=120000
# per-lane time limit in seconds; raise it for large PRs (a 42-file port needed more than 1800)
LANE_TIMEOUT=${AGENT_REVIEW_TIMEOUT:-1800}
review_with(){ case "$1" in
  grok) (cd "$WORK/src" && timeout -k "$KILL_AFTER" "$LANE_TIMEOUT" grok --always-approve --cwd "$WORK/src" -p "$PROMPT") ;;
  agy)  (cd "$WORK/src" && timeout -k "$KILL_AFTER" "$LANE_TIMEOUT" agy --dangerously-skip-permissions --add-dir "$WORK" -p "$PROMPT") ;;
  devin|devin-sol) # sandboxed: writes stay in the throwaway checkout, so the inputs go there too. The checkout
    # is untrusted: drop anything the PR put at .agent-review (e.g. a symlink out of the tree) and stage
    # into a directory created fresh here, so cp never writes through a PR-controlled path.
    [ "$1" = devin ] || [ "$WRITER_FAMILY" = cognition ] || { echo "LANE_INELIGIBLE: paid lane $1 only reviews swe-2-written PRs"; return 65; }
    { rm -rf "$WORK/src/.agent-review" && mkdir "$WORK/src/.agent-review" &&
      cp "$WORK/pr.txt" "$WORK/pr.diff" "$WORK/src/.agent-review/"; } || { echo "LANE_INELIGIBLE: cannot stage review inputs"; return 65; }
    # an account can be rate-limited (free tier, shared) or out of weekly paid quota: rotate through
    # AGENT_REVIEW_DEVIN_BINS (same CLI, other accounts, same pinned model), then back off and rerun
    local drc bin
    for try in 1 2 3; do
      for bin in ${AGENT_REVIEW_DEVIN_BINS:-devin}; do
        (cd "$WORK/src" && timeout -k "$KILL_AFTER" "$LANE_TIMEOUT" "$bin" --model "${DEVIN_MODEL[$1]}" --sandbox -p "${PROMPT//$WORK\//.agent-review/}
Review directly with file reads and read-only git commands; do not invoke skills or subagents.") > "$WORK/devin-try.txt" 2>&1 && { cat "$WORK/devin-try.txt"; return 0; }
        drc=$?   # local: the caller's lane loop owns rc
        grep -qE "rate limit|usage quota has been exhausted" "$WORK/devin-try.txt" || { cat "$WORK/devin-try.txt"; return "$drc"; }
        echo "$1 account $bin rate- or quota-limited (try $try)" >&2
      done
      [ "$try" -eq 3 ] && { cat "$WORK/devin-try.txt"; return "$drc"; }
      sleep "${AGENT_REVIEW_BACKOFF:-120}"
    done ;;
  gpt6pro)
    # no filesystem: metadata, commit messages and the COMPLETE diff go inline; whole prompt too large -> not eligible
    { printf '%s\n\nNo checkout is available to you; the PR metadata, commit messages and the complete diff are inline below.\n=== PR METADATA ===\n' "$PROMPT"
      cat "$WORK/pr.txt"; printf '\n=== COMPLETE DIFF ===\n'; cat "$WORK/pr.diff"; } > "$WORK/gpt6pro-prompt.txt"
    [ "$(wc -c < "$WORK/gpt6pro-prompt.txt")" -le "$INLINE_MAX" ] || { echo "LANE_INELIGIBLE: prompt larger than $INLINE_MAX bytes"; return 65; }
    timeout -k "$KILL_AFTER" "$LANE_TIMEOUT" "$GPT6PRO" - < "$WORK/gpt6pro-prompt.txt" ;;
esac; }
REVIEWER=none; VERDICT=
for LANE in ${AGENT_REVIEWER:-grok agy devin devin-sol gpt6pro}; do
  [ -n "${FAMILY[$LANE]:-}" ] || { echo "unknown reviewer lane $LANE" >&2; exit 64; }
  [ "${FAMILY[$LANE]}" != "$WRITER_FAMILY" ] || { echo "skip $LANE: same family as writer ($WRITER_FAMILY)" >&2; continue; }
  rc=0; review_with "$LANE" > "$WORK/review-$LANE.txt" 2>&1 || rc=$?
  V=$(grep -oE "VERDICT: (APPROVE|REQUEST_CHANGES)" "$WORK/review-$LANE.txt" | tail -1 | cut -d" " -f2 || true)
  if [ "$rc" -eq 0 ] && [ -n "$V" ]; then REVIEWER=$LANE; VERDICT=$V; cp "$WORK/review-$LANE.txt" "$WORK/review.txt"; break; fi
  echo "reviewer $LANE not usable (exit $rc): $(grep -m1 -v '^\s*$' "$WORK/review-$LANE.txt" | cut -c1-160)" | tee -a "$WORK/lanes.txt" >&2
  # keep the end of the failed lane's output: the first line is often only a CLI warning
  tail -n 8 "$WORK/review-$LANE.txt" | cut -c1-240 | sed 's/^/    | /' >> "$WORK/lanes.txt"
done
[ -f "$WORK/review.txt" ] || { echo "no reviewer lane produced a verdict" > "$WORK/review.txt"; cat "$WORK/lanes.txt" >> "$WORK/review.txt" 2>/dev/null || true; }

# lanes may route to a weaker model than requested; surface that on the status and receipt
DOWNGRADE=$(grep -oE "server resolved \`[^\`]+\`" "$WORK/review.txt" | head -1 | tr -d '\`' || true)
LABEL=$REVIEWER; [ -z "$DOWNGRADE" ] || LABEL="$REVIEWER (degraded: ${DOWNGRADE#server resolved })"
NOW=$(net gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
{ echo "# agent-review $R#$PR @ $HEAD"; echo "reviewer: $LABEL (${FAMILY[$REVIEWER]:-none}) · writer family: $WRITER_FAMILY · $(date -Is)"; [ -f "$WORK/lanes.txt" ] && cat "$WORK/lanes.txt"; echo "verdict: ${VERDICT:-NONE}"
  [ "$NOW" = "$HEAD" ] || echo "NOTE: head moved to $NOW during review; posted error, rerun"; echo; cat "$WORK/review.txt"; } > "$REC"

[ "$NOW" = "$HEAD" ] || { ABORT="head moved during review; rerun"; echo "$ABORT"; exit 3; }
case "$VERDICT" in
  APPROVE) status success "$LABEL: approve" ;;
  REQUEST_CHANGES) status failure "$LABEL: changes requested" ;;
  *) status error "$LABEL: no verdict (see receipt)" ;;
esac
STATE=final
if [ "$POST" = --post ]; then
  { echo "**agent-review** ($LABEL) at \`${HEAD:0:7}\`: **${VERDICT:-NO VERDICT}**"; echo; echo '<details><summary>review</summary>'; echo; cat "$WORK/review.txt"; echo; echo '</details>'; } > "$WORK/comment.md"
  net gh pr comment "$PR" -R "$R" -F "$WORK/comment.md" >/dev/null
fi
echo "$R#$PR ${HEAD:0:7} verdict=${VERDICT:-NONE} receipt=$REC"
[ "$VERDICT" = APPROVE ]
