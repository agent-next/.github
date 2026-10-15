#!/usr/bin/env bash
# agent-merge: merge ONE PR only when its current head has agent-review=success and the checks gate
# is green. The merger never reviews; it only checks the gate and merges that exact SHA.
# The checks gate has two modes, and every merge names the one it used on one line:
#   gate: required checks                                     the repo declares required checks
#   gate: all reported checks (repo has no required checks)   the script gates itself: every check
#     on the head must be pass or skipping (any fail, pending, cancel or unknown state blocks), and
#     a head reporting no check at all blocks too, since nothing else would gate the merge
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
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
HEAD=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
POSTERS=${AGENT_REVIEW_POSTERS:?set AGENT_REVIEW_POSTERS to the reviewer identities allowed to post agent-review}
# the latest agent-review status (by created_at, across all pages) is the only one that counts
read -r AR BY < <(gh api "repos/$R/commits/$HEAD/statuses?per_page=100" --paginate --slurp |
  jq -r '[.[][]|select(.context=="agent-review")]|sort_by(.created_at, .id)|last|"\(.state // "absent") \(.creator.login // "-")"')
[ "$AR" = success ] || { echo "BLOCKED: agent-review=$AR on ${HEAD:0:7}"; exit 2; }
case ",$POSTERS," in *",$BY,"*) ;; *) echo "BLOCKED: agent-review on ${HEAD:0:7} posted by $BY, not in AGENT_REVIEW_POSTERS"; exit 2 ;; esac
# gh pr checks exits 0 only when nothing is red or pending; it exits 1 for a failed check and 8 for
# a still-pending one, both with no message of their own (its table says which). A repo with no
# required checks gets "no required checks reported on the '<branch>' branch" (a head reporting no
# check at all gets "no checks reported ..."), and is then gated on every reported check below, so
# such repos keep one merge path instead of a hand merge. Any other exit is gh itself failing
# (network, auth, rate limit, timeout), which closes the gate like a red check and says so.
REQ_RC=0; REQ_ERR=$(gh pr checks "$PR" -R "$R" --required 2>&1 >/dev/null) || REQ_RC=$?
case "$REQ_RC" in
  0) echo "gate: required checks" ;;
  1|8)
    case "$REQ_ERR" in
      *"no required checks reported"*|*"no checks reported"*)
        echo "gate: all reported checks (repo has no required checks)"
        # bucket is gh's own verdict per check (pass/fail/pending/skipping/cancel); agent-review
        # counts like any other check here, it is already gated above
        ALL_RC=0; ALL=$(gh pr checks "$PR" -R "$R" --json name,bucket 2>"$TMP/all-err") || ALL_RC=$?
        if [ "$ALL_RC" -ne 0 ]; then
          if grep -q "no checks reported" "$TMP/all-err"; then
            echo "BLOCKED: no checks reported on ${HEAD:0:7}; nothing to gate on"; exit 2
          fi
          E=$(head -1 "$TMP/all-err")
          if [ -n "$E" ]; then echo "BLOCKED: gh pr checks failed (exit $ALL_RC): $E"
          else echo "BLOCKED: gh pr checks failed (exit $ALL_RC)"; fi
          exit 2
        fi
        N=$(printf '%s\n' "$ALL" | jq -r 'if type=="array" then length else "" end') || N=""
        case "$N" in ''|*[!0-9]*) echo "BLOCKED: cannot read the checks reported on ${HEAD:0:7}"; exit 2 ;; esac
        [ "$N" -gt 0 ] || { echo "BLOCKED: no checks reported on ${HEAD:0:7}; nothing to gate on"; exit 2; }
        BAD=$(printf '%s\n' "$ALL" | jq -r '[.[]|select(.bucket!="pass" and .bucket!="skipping")]|
          if length==0 then "" else "\(.[0].name) is \(.[0].bucket // "unknown")" end') || { echo "BLOCKED: cannot read the checks reported on ${HEAD:0:7}"; exit 2; }
        [ -z "$BAD" ] || { echo "BLOCKED: check $BAD"; exit 2; } ;;
      "") # gh's silent verdicts: exit 1 = a required check failed, 8 = one is still pending
        echo "BLOCKED: required checks not green"; gh pr checks "$PR" -R "$R" --required || true; exit 2 ;;
      *) echo "BLOCKED: gh pr checks --required failed (exit $REQ_RC): ${REQ_ERR%%$'\n'*}"; exit 2 ;;
    esac ;;
  *)
    if [ -n "$REQ_ERR" ]; then echo "BLOCKED: gh pr checks --required failed (exit $REQ_RC): ${REQ_ERR%%$'\n'*}"
    else echo "BLOCKED: gh pr checks --required failed (exit $REQ_RC)"; fi
    exit 2 ;;
esac
NOW=$(gh pr view "$PR" -R "$R" --json headRefOid -q .headRefOid)
[ "$NOW" = "$HEAD" ] || { echo "BLOCKED: head moved ${HEAD:0:7} -> ${NOW:0:7} during the gate check; rerun"; exit 2; }
gh pr merge "$PR" -R "$R" --squash --match-head-commit "$HEAD"
gh pr view "$PR" -R "$R" --json state,mergeCommit -q '"'"$R"'#'"$PR"': \(.state) \(.mergeCommit.oid[0:7])"'
