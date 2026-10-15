#!/usr/bin/env bash
# agent-review: independent agent review of ONE pull request at ONE head SHA, recorded as the
# commit status `agent-review` on that SHA (the agent-native merge gate; no human approval).
# A new push creates a new SHA without the status, so stale reviews never count.
# usage: agent-review.sh <owner/repo> <pr> [--post]   (without --post: dry run, no status/comment)
#        env: AGENT_REVIEWER lanes (default: droid devin ccz; grok and agy stay callable),
#             AGENT_WRITER_FAMILY writer families (default: anthropic)
# tests: bash tests/agent-review.test.sh (hermetic; gh, git and the lanes are shims, jq is real)
# Reviewer chain (owner decisions 2026-09-25/26/28, lane roster 2026-10-15): droid (Claude Opus 5.5) ->
# devin -> ccz; grok and agy stay callable through AGENT_REVIEWER; gpt6pro is gone (owner 2026-10-14:
# never gpt-6). A lane of a writer's model family (AGENT_WRITER_FAMILY, comma-separated; model names like
# claude/gemini/codex/glm map to their family) is refused, droid included: an anthropic writer family skips
# droid and falls through to devin. ccz (GLM on z.ai) is the stand-in when no frontier lane is healthy; its
# verdict is labelled ccz on the status. The droid lane also audits the model that actually served it (see
# the served-model audit below), because on 2026-10-15 droid exec -m gpt-6.1-sol silently ran 150 min on
# kimi-k3.
# A lane result counts only if the lane exited 0 AND printed a VERDICT line; otherwise the next lane runs.
# Receipts go to $AGENT_REVIEW_OUT (default ./agent-review-receipts).
set -euo pipefail
set -f   # no pathname expansion anywhere: unquoted env lists (lanes, accounts, families) must never match files
[ $# -ge 2 ] || { echo "usage: agent-review.sh <owner/repo> <pr> [--post]
  (without --post: dry run, no status/comment)
  env: AGENT_REVIEWER lanes, default 'droid devin ccz' (grok and agy callable too);
       AGENT_WRITER_FAMILY families, default anthropic" >&2; exit 64; }
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
# robust checkout (2026-10-15: a review died at clone with `curl 18 transfer closed` and `fatal: could not
# fetch <sha> from promisor remote`, because a blob:none clone only fetches blobs lazily): clone and fetch
# retry up to CLONE_TRIES times with backoff, and a partial clone that still fails falls back to a full
# clone with no filter, which never needs a lazy fetch
CLONE_TRIES=${AGENT_REVIEW_CLONE_TRIES:-3}
CLONE_BACKOFF=${AGENT_REVIEW_CLONE_BACKOFF:-15}
clone_try(){ # $1: the clone filter, "" for a full clone; retries, and returns the last attempt's exit code
  local filter=$1 try rc=0
  for try in $(seq 1 "$CLONE_TRIES"); do
    rm -rf "$WORK/src"   # a failed clone leaves a partial tree that must not be reused
    net git "${SLOW[@]}" -c credential.helper='!gh auth git-credential' clone -q ${filter:+"$filter"} "https://github.com/$R.git" "$WORK/src" && return 0
    rc=$?
    echo "clone failed (try $try/$CLONE_TRIES, exit $rc)" >&2
    [ "$try" -eq "$CLONE_TRIES" ] || sleep "$CLONE_BACKOFF"
  done
  return "$rc"
}
fetch_try(){ # retries the PR head fetch; returns the last attempt's exit code
  local try rc=0
  for try in $(seq 1 "$CLONE_TRIES"); do
    net git -C "$WORK/src" fetch -q origin "pull/$PR/head" && return 0
    rc=$?
    echo "fetch failed (try $try/$CLONE_TRIES, exit $rc)" >&2
    [ "$try" -eq "$CLONE_TRIES" ] || sleep "$CLONE_BACKOFF"
  done
  return "$rc"
}
if ! clone_try --filter=blob:none; then
  echo "partial clone still failing; falling back to a full clone without a filter" >&2
  clone_try ""
fi
git -C "$WORK/src" config credential.helper '!gh auth git-credential'
git -C "$WORK/src" config http.lowSpeedLimit 1000
git -C "$WORK/src" config http.lowSpeedTime 120
fetch_try
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
Run the repo's own check command if cheap (see AGENTS.md / Makefile) in the foreground and wait for it;
never end your turn while a command is still running. Do not modify files.
Output: a findings list, each with file:line, severity (blocker/major/minor/nit) and evidence.
Last line exactly one of: VERDICT: APPROVE   or   VERDICT: REQUEST_CHANGES
(REQUEST_CHANGES iff any blocker or major; AI-attribution text and broken links are always major)."
# Reviewer lanes (owner decisions 2026-09-25/26/28, lane roster 2026-10-15): droid is the default reviewer; grok
# and agy remain callable through AGENT_REVIEWER but are out of the default chain. Each lane is a different
# model family; a lane whose family is one of the writers' ($AGENT_WRITER_FAMILY, comma-separated, default
# anthropic; model names like claude/gemini/codex/glm map to their family) is refused. ccz (GLM on z.ai) is the
# stand-in when no frontier lane is healthy; its verdict is labelled ccz on the status.
# A lane result counts only if the lane exited 0 AND printed a VERDICT line; otherwise the next lane runs.
declare -A FAMILY=([droid]=anthropic [grok]=xai [agy]=google [devin]=cognition [ccz]=zai)
# the devin CLI runs several vendors' models; the devin lane runs only swe-2 (owner decision 2026-09-28).
declare -A DEVIN_MODEL=([devin]=swe-2-max)
# writers often name the model or harness instead of the vendor: map those exact names to their family
declare -A FAMILY_ALIAS=([claude]=anthropic [opus]=anthropic [sonnet]=anthropic [haiku]=anthropic [fable]=anthropic
  [gemini]=google [gpt]=openai [codex]=openai [glm]=zai [swe]=cognition
  [pro-zdr]=zai [flash-zdr]=zai [pro-open]=zai [flash-open]=zai [small-open]=zai)
# gateway pool writers: the gateway free pool falls back to GLM (zai/glm-5.3-flash), and its other members
# (deepseek, longcat, cat-jam, ...) have no reviewer lane of their own, so a gateway id counts as the zai
# family -- the family the pool can silently serve -- and refuses the ccz lane like any other zai writer.
# Gateway ids are patterns (custom:gw-*, gw-*), so they are matched, not looked up as exact keys.
writer_family(){ # $1 writer id -> stdout: the model family that id belongs to
  case "$1" in
    custom:gw-*|gw-*) echo zai ;;
    *) echo "${FAMILY_ALIAS[$1]:-$1}" ;;
  esac; }
WRITER_FAMILY=${AGENT_WRITER_FAMILY:-anthropic}
# normalize (case, spaces) and allow only known families: a typo must fail closed, never let a writer's family review
WRITER_FAMILY=$(printf '%s' "$WRITER_FAMILY" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
[ -n "${WRITER_FAMILY//,/}" ] || { echo "empty AGENT_WRITER_FAMILY" >&2; ABORT="empty writer family"; exit 64; }
IFS=, read -ra WRITERS <<< "$WRITER_FAMILY"   # split without pathname expansion: a * must not match files
for i in "${!WRITERS[@]}"; do
  f=$(writer_family "${WRITERS[$i]}")
  [[ "$f" =~ ^[a-z0-9-]+$ && " anthropic ${FAMILY[*]} " == *" $f "* ]] || { echo "unknown writer family '${WRITERS[$i]}' in AGENT_WRITER_FAMILY" >&2; ABORT="unknown writer family"; exit 64; }
  WRITERS[$i]=$f
done
WRITER_FAMILY=$(IFS=,; printf '%s' "${WRITERS[*]}")
# per-lane time limit in seconds; raise it for large PRs (a 42-file port needed more than 1800)
LANE_TIMEOUT=${AGENT_REVIEW_TIMEOUT:-1800}
# the droid lane is pinned to the owner's named final reviewer (2026-10-14) and runs with -o stream-json so
# its transcript is auditable; everything the audit needs is defined below the lane table
DROID_MODEL=claude-opus-5-5
DROID_CWD=$WORK/src
FACTORY_HOME=${AGENT_REVIEW_FACTORY_HOME:-$HOME/.factory}
review_with(){ case "$1" in
  grok) (cd "$WORK/src" && timeout -k "$KILL_AFTER" "$LANE_TIMEOUT" grok --always-approve --cwd "$WORK/src" -p "$PROMPT") ;;
  agy)  (cd "$WORK/src" && timeout -k "$KILL_AFTER" "$LANE_TIMEOUT" agy --dangerously-skip-permissions --add-dir "$WORK" -p "$PROMPT") ;;
  devin) # sandboxed: writes stay in the throwaway checkout, so the inputs go there too. The checkout
    # is untrusted: drop anything the PR put at .agent-review (e.g. a symlink out of the tree) and stage
    # into a directory created fresh here, so cp never writes through a PR-controlled path.
    { rm -rf "$WORK/src/.agent-review" && mkdir "$WORK/src/.agent-review" &&
      cp "$WORK/pr.txt" "$WORK/pr.diff" "$WORK/src/.agent-review/"; } || { echo "LANE_INELIGIBLE: cannot stage review inputs"; return 65; }
    # an account can be rate-limited (free tier, shared) or out of its weekly quota: rotate through
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
  droid) # -o stream-json turns the lane's stdout into an auditable event stream (see the audit below);
    # < /dev/null keeps it headless, --auto medium lets it read the checkout without prompting
    (cd "$WORK/src" && timeout -k "$KILL_AFTER" "$LANE_TIMEOUT" "${AGENT_REVIEW_DROID_BIN:-droid}" exec --auto medium -m "$DROID_MODEL" -r high -o stream-json --cwd "$WORK/src" "$PROMPT" < /dev/null) ;;
  ccz) # --model pins glm-5.3; an inherited CCZ_TIER (ccz's tier selector) is dropped so it cannot pick a model that
    # must not see private code. The runner's own CLAUDE.md files are disabled: host instructions (e.g. "answer in
    # Chinese") made long reviews end without the English VERDICT line, which then never counts. --safe-mode also
    # drops hooks, MCP servers, skills and plugins, so a PR shipping .claude/settings.json cannot run commands here.
    (cd "$WORK/src" && env -u CCZ_TIER CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 timeout -k "$KILL_AFTER" "$LANE_TIMEOUT" "${CCZ_BIN:-ccz}" --safe-mode --model glm-5.3 --add-dir "$WORK" -p "$PROMPT
Review directly with file reads and read-only git commands; do not invoke skills or subagents." < /dev/null) ;;
esac; }
# Served-model audit (droid only). The lane's stdout is a stream of JSON events, not prose: the review text
# is the finalText of its last {"type":"completion"} event, and the session id is in the first
# {"type":"system","session_id": ...} event. That event's `model` field is only the model that was
# REQUESTED; what actually served the session is in ${AGENT_REVIEW_FACTORY_HOME:-$HOME/.factory}/
# sessions/<cwd-slug>/<session_id>.jsonl, where <cwd-slug> is the review cwd with every / replaced by a -
# and its {"type":"message", "message": {"modelId": ..., "apiProvider": ...}} lines carry the model.
# 2026-10-15: droid exec -m gpt-6.1-sol silently served a 150-minute review on kimi-k3, so a droid verdict
# counts only if EVERY modelId in that file is the pinned $DROID_MODEL; otherwise -- including a missing
# session file -- the lane result is NONE, the receipt records the mismatch, and the chain falls through.
droid_text(){ # $1 events file -> stdout: the finalText of its last completion event
  jq -cR 'fromjson? | select(.type=="completion") | .finalText // empty' "$1" | tail -n 1 | jq -r .; }
droid_session(){ # $1 events file -> stdout: the session id of its first system event
  jq -rR 'fromjson? | select(.type=="system") | .session_id // empty' "$1" | head -n 1; }
droid_session_file(){ # $1 events file -> stdout: the session file that run wrote (nothing if it has no id)
  local sid; sid=$(droid_session "$1")
  [ -n "$sid" ] || return 0
  printf '%s\n' "$FACTORY_HOME/sessions/${DROID_CWD//\//-}/$sid.jsonl"; }
droid_audit(){ # $1 session file -> stdout: its modelId tally ("model=count ..."); rc 1 unless every
  # modelId is $DROID_MODEL (a missing or model-less session file fails too). The tally alone is the
  # oracle, never `grep -q` in a pipeline: grep -q exits on the first mismatching line, jq then dies
  # on SIGPIPE, and under pipefail the race made a LONG mismatched session read as a pass. Here the
  # decision needs only the tally: all-$DROID_MODEL is exactly one "model=count" pair, i.e. no
  # separator space and the model name in front of the one count.
  local counts tally
  [ -s "$1" ] || { echo "no session file"; return 1; }
  counts=$(jq -rR 'fromjson? | select(.type=="message") | .message.modelId // empty' "$1" | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
  [ -n "${counts// /}" ] || { echo "no modelId recorded"; return 1; }
  echo "${counts% }"
  tally=${counts%" "}   # drop the awk trailing space; the pairs inside stay separated by spaces
  case "$tally" in
    *" "*) return 1 ;;                      # more than one model was served
    "$DROID_MODEL"=[0-9]*) return 0 ;;      # every message came from the pinned model
    *) return 1 ;;
  esac; }
droid_served_as(){ # $1 session file -> stdout: "<modelId> via <apiProvider>" of its last message
  jq -rR 'fromjson? | select(.type=="message") | "\(.message.modelId) via \(.message.apiProvider // "unknown")"' "$1" | tail -n 1; }
REVIEWER=none; VERDICT=; SERVED=
for LANE in ${AGENT_REVIEWER:-droid devin ccz}; do
  [ -n "${FAMILY[$LANE]:-}" ] || { echo "unknown reviewer lane $LANE" >&2; exit 64; }
  [[ ",$WRITER_FAMILY," != *",${FAMILY[$LANE]},"* ]] || { echo "skip $LANE: same family as a writer ($WRITER_FAMILY)" | tee -a "$WORK/lanes.txt" >&2; continue; }
  rc=0; review_with "$LANE" > "$WORK/review-$LANE.txt" 2>&1 || rc=$?
  SERVED=; WHY=
  if [ "$LANE" = droid ] && [ "$rc" -eq 0 ]; then
    # the lane's output is the event stream: keep it as the transcript, swap the review text into its place
    cp "$WORK/review-$LANE.txt" "$WORK/droid-events.json"
    echo "reviewer droid (Opus 5.5) transcript: $(grep -c . "$WORK/droid-events.json") events" >> "$WORK/lanes.txt"
    droid_text "$WORK/droid-events.json" > "$WORK/review-$LANE.txt" || true
  fi
  V=$(grep -oE "VERDICT: (APPROVE|REQUEST_CHANGES)" "$WORK/review-$LANE.txt" | tail -1 | cut -d" " -f2 || true)
  if [ "$LANE" = droid ] && [ "$rc" -eq 0 ] && [ -n "$V" ]; then
    sess=$(droid_session_file "$WORK/droid-events.json")
    if [ -n "$sess" ] && counts=$(droid_audit "$sess"); then
      SERVED="served: $(droid_served_as "$sess")"
    else
      WHY="served-model mismatch: ${counts:-no session file}"   # name the real reason on the next line
      echo "$WHY" | tee -a "$WORK/lanes.txt" >&2
      V=
    fi
  fi
  if [ "$rc" -eq 0 ] && [ -n "$V" ]; then REVIEWER=$LANE; VERDICT=$V; cp "$WORK/review-$LANE.txt" "$WORK/review.txt"; break; fi
  echo "reviewer $LANE not usable${WHY:+ ($WHY)} (exit $rc): $(grep -m1 -v '^\s*$' "$WORK/review-$LANE.txt" | cut -c1-160)" | tee -a "$WORK/lanes.txt" >&2
  # keep the end of the failed lane's output: the first line is often only a CLI warning
  tail -n 8 "$WORK/review-$LANE.txt" | cut -c1-240 | sed 's/^/    | /' >> "$WORK/lanes.txt"
done
[ -f "$WORK/review.txt" ] || { echo "no reviewer lane produced a verdict" > "$WORK/review.txt"; cat "$WORK/lanes.txt" >> "$WORK/review.txt" 2>/dev/null || true; }

# lanes may route to a weaker model than requested; surface that on the status and receipt
DOWNGRADE=$(grep -oE "server resolved \`[^\`]+\`" "$WORK/review.txt" | head -1 | tr -d '\`' || true)
LABEL=$REVIEWER; [ -z "$DOWNGRADE" ] || LABEL="$REVIEWER (degraded: ${DOWNGRADE#server resolved })"
NOW=$(net gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
{ echo "# agent-review $R#$PR @ $HEAD"; echo "reviewer: $LABEL (${FAMILY[$REVIEWER]:-none})${SERVED:+ · $SERVED} · writer family: $WRITER_FAMILY · $(date -Is)"; [ -f "$WORK/lanes.txt" ] && cat "$WORK/lanes.txt"; echo "verdict: ${VERDICT:-NONE}"
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
