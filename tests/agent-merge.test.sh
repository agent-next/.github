#!/usr/bin/env bash
# Hermetic tests for scripts/agent-merge.sh: gh is a shim, so no GitHub call is made.
# Oracle: whether the script asked gh to merge, its exit code, and the gate lines it printed.
# usage: bash tests/agent-merge.test.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/agent-merge.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/gh" <<'SHIM'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--json headRefOid"*)
    [ -z "${FAKE_HEAD_HANG:-}" ] || sleep 30
    n=$(( $(cat "$T/heads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/heads"
    if [ "$n" -gt 1 ] && [ -n "${FAKE_NEW_HEAD:-}" ]; then echo "$FAKE_NEW_HEAD"; else echo "$FAKE_HEAD"; fi ;;
  "api repos/"*"/statuses"*)
    printf '[[{"context":"ci","state":"success","created_at":"2026-01-01T00:00:03Z","id":3,"creator":{"login":"bot"}},'
    printf '{"context":"agent-review","state":"pending","created_at":"2026-01-01T00:00:01Z","id":1,"creator":{"login":"rev"}},'
    printf '{"context":"agent-review","state":"%s","created_at":"2026-01-01T00:00:02Z","id":2,"creator":{"login":"%s"}}]]\n' \
      "${FAKE_STATE:-success}" "${FAKE_POSTER:-rev}" ;;
  "pr checks"*)
    # FAKE_CHECKS_HANG: the checks lookup stalls, as on a trickling link
    [ -z "${FAKE_CHECKS_HANG:-}" ] || sleep 15
    case "$args" in
      *"--required"*)
        # red required checks: table on stdout, rc 1, no message (gh's SilentError)
        [ -z "${FAKE_CHECKS_RED:-}" ] || { echo "test  fail"; exit 1; }
        # pending required checks: rc 8 (gh's PendingError)
        [ -z "${FAKE_CHECKS_PENDING:-}" ] || { echo "test  pending"; exit 8; }
        # repo declares no required checks (gh prints this on stderr, rc 1)
        [ -z "${FAKE_NO_REQUIRED:-}" ] || { echo "no required checks reported on the 'sbx' branch" >&2; exit 1; }
        # head has no checks at all, required or not (gh prints this on stderr, rc 1)
        [ -z "${FAKE_NO_CHECKS:-}" ] || { echo "no checks reported on the 'sbx' branch" >&2; exit 1; }
        # any other gh failure: network, auth, rate limit
        [ -z "${FAKE_GH_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; } ;;
      *"--json name,bucket"*)
        [ -z "${FAKE_GH_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
        [ -z "${FAKE_ALL_NO_CHECKS:-}" ] || { echo "no checks reported on the 'sbx' branch" >&2; exit 1; }
        printf '%s\n' "${FAKE_ALL_CHECKS:-[]}" ;;
      *) echo "gh shim: unexpected checks call: $args" >&2; exit 99 ;;
    esac ;;
  "pr merge"*) echo "$args" > "$T/merged" ;;
  *"--json state,mergeCommit"*) echo "o/r#1: MERGED abcdef0" ;;
  *) echo "gh shim: unexpected: $args" >&2; exit 99 ;;
esac
SHIM
chmod +x "$T/bin/gh"

PASS=0; FAIL=0
# run <name> <expected rc> <expected merged: yes|no> <env...>
run(){
  local name=$1 want_rc=$2 want_merged=$3; shift 3
  rm -f "$T/heads" "$T/merged"
  env -i HOME="$HOME" PATH="$T/bin:$PATH" T="$T" FAKE_HEAD=aaaaaaa1111111111111111111111111111111111 \
      AGENT_REVIEW_POSTERS=rev "$@" bash "$SCRIPT" o/r 1 > "$T/log" 2>&1
  local rc=$? merged=no; [ -e "$T/merged" ] && merged=yes
  if [ "$rc" = "$want_rc" ] && [ "$merged" = "$want_merged" ]; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name: rc=$rc (want $want_rc) merged=$merged (want $want_merged)"; sed 's/^/     /' "$T/log"; fi
}
# said <line the last run must have printed> <name of the claim>: every gate names its mode or reason
said(){
  if grep -qF -- "$1" "$T/log"; then PASS=$((PASS+1)); echo "ok   $2"
  else FAIL=$((FAIL+1)); echo "FAIL $2: log lacks: $1"; sed 's/^/     /' "$T/log"; fi
  }

run "latest agent-review success by an allowed poster merges" 0 yes
said "gate: required checks" "a merge through required checks names its gate mode"
if grep -q -- "--match-head-commit aaaaaaa1111111111111111111111111111111111" "$T/merged"; then PASS=$((PASS+1)); echo "ok   merge is pinned to the reviewed head"; else FAIL=$((FAIL+1)); echo "FAIL merge not pinned: $(cat "$T/merged" 2>/dev/null)"; fi
run "failed review blocks" 2 no FAKE_STATE=failure
run "review posted by an unlisted identity blocks" 2 no FAKE_POSTER=someone-else
run "red required checks block" 2 no FAKE_CHECKS_RED=1
said "BLOCKED: required checks not green" "red required checks keep today's block message"
run "pending required checks block" 2 no FAKE_CHECKS_PENDING=1
said "BLOCKED: required checks not green" "pending required checks keep today's block message"
run "head moved during the gate check blocks" 2 no FAKE_NEW_HEAD=ccccccc2222222222222222222222222222222222
run "unset AGENT_REVIEW_POSTERS fails closed" 1 no AGENT_REVIEW_POSTERS=
run "hung head lookup hits the network timeout and never merges" 124 no FAKE_HEAD_HANG=1 AGENT_MERGE_NET_TIMEOUT=1

# repos that declare no required checks: the script gates on every reported check itself
run "no required checks: every check pass or skipping merges" 0 yes FAKE_NO_REQUIRED=1 \
    FAKE_ALL_CHECKS='[{"name":"ci","bucket":"pass"},{"name":"agent-review","bucket":"pass"},{"name":"lint","bucket":"skipping"}]'
said "gate: all reported checks (repo has no required checks)" "a merge without required checks names its gate mode"
if grep -q -- "--match-head-commit aaaaaaa1111111111111111111111111111111111" "$T/merged"; then PASS=$((PASS+1)); echo "ok   the all-checks merge is pinned to the reviewed head"; else FAIL=$((FAIL+1)); echo "FAIL all-checks merge not pinned: $(cat "$T/merged" 2>/dev/null)"; fi
run "no required checks: one pending check blocks" 2 no FAKE_NO_REQUIRED=1 \
    FAKE_ALL_CHECKS='[{"name":"ci","bucket":"pass"},{"name":"lint","bucket":"pending"}]'
said "BLOCKED: check lint is pending" "a pending check is named with its state"
run "no required checks: one failed check blocks" 2 no FAKE_NO_REQUIRED=1 \
    FAKE_ALL_CHECKS='[{"name":"ci","bucket":"fail"}]'
said "BLOCKED: check ci is fail" "a failed check is named with its state"
run "no required checks: one cancelled check blocks" 2 no FAKE_NO_REQUIRED=1 \
    FAKE_ALL_CHECKS='[{"name":"ci","bucket":"pass"},{"name":"lint","bucket":"cancel"}]'
said "BLOCKED: check lint is cancel" "a cancelled check is named with its state"
run "no required checks: zero reported checks block" 2 no FAKE_NO_REQUIRED=1 FAKE_ALL_NO_CHECKS=1
said "BLOCKED: no checks reported on aaaaaaa; nothing to gate on" "zero reported checks leave nothing to gate on"
run "a head with no checks at all blocks" 2 no FAKE_NO_CHECKS=1
said "BLOCKED: no checks reported on aaaaaaa; nothing to gate on" "a head without any check leaves nothing to gate on"

# gh itself failing (network, auth, rate limit) is not a green gate
run "gh failure during the required-checks lookup blocks" 2 no FAKE_GH_FAIL=1
said "gh pr checks --required failed" "a gh failure in the required lookup says gh failed"
run "gh failure during the all-checks lookup blocks" 2 no FAKE_NO_REQUIRED=1 FAKE_GH_FAIL=1
said "gh pr checks failed" "a gh failure in the all-checks lookup says gh failed"
run "hung checks lookup hits the network timeout and never merges" 2 no FAKE_CHECKS_HANG=1 AGENT_MERGE_NET_TIMEOUT=1
said "gh pr checks --required failed (exit 124)" "a timed-out checks lookup is a gh failure"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
