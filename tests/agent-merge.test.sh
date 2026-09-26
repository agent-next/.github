#!/usr/bin/env bash
# Hermetic tests for scripts/agent-merge.sh: gh is a shim, so no GitHub call is made.
# Oracle: whether the script asked gh to merge, plus its exit code.
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
  "pr checks"*) [ -z "${FAKE_CHECKS_RED:-}" ] || { echo "test  fail"; exit 1; } ;;
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

run "latest agent-review success by an allowed poster merges" 0 yes
if grep -q -- "--match-head-commit aaaaaaa1111111111111111111111111111111111" "$T/merged"; then PASS=$((PASS+1)); echo "ok   merge is pinned to the reviewed head"; else FAIL=$((FAIL+1)); echo "FAIL merge not pinned: $(cat "$T/merged" 2>/dev/null)"; fi
run "failed review blocks" 2 no FAKE_STATE=failure
run "review posted by an unlisted identity blocks" 2 no FAKE_POSTER=someone-else
run "red required checks block" 2 no FAKE_CHECKS_RED=1
run "head moved during the gate check blocks" 2 no FAKE_NEW_HEAD=ccccccc2222222222222222222222222222222222
run "unset AGENT_REVIEW_POSTERS fails closed" 1 no AGENT_REVIEW_POSTERS=
run "hung head lookup hits the network timeout and never merges" 124 no FAKE_HEAD_HANG=1 AGENT_MERGE_NET_TIMEOUT=1

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
