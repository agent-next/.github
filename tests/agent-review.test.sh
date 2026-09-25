#!/usr/bin/env bash
# Hermetic tests for scripts/agent-review.sh: gh, git and the reviewer lane are shims, so no
# network, GitHub status or model call is made. Oracle: the exact sequence of agent-review
# statuses the script would post, plus its exit code.
# usage: bash tests/agent-review.test.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/agent-review.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--json headRefOid"*)
    n=$(( $(cat "$T/heads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/heads"
    if [ "$n" -gt 1 ] && [ -n "${FAKE_NEW_HEAD:-}" ]; then echo "$FAKE_NEW_HEAD"; else echo "$FAKE_HEAD"; fi ;;
  "api -X POST "*"/statuses/"*)
    state=${args#*state=}; state=${state%% *}; desc=${args#*description=}
    echo "$state|$desc" >> "$T/statuses" ;;
  *"--json title"*) echo "TITLE: test" ;;
  *"--json commits"*) echo "COMMITS:" ;;
  "pr diff"*) head -c "${FAKE_DIFF_BYTES:-20}" /dev/zero | tr '\0' 'x'; echo ;;
  "pr comment"*) : ;;
  *) echo "gh shim: unexpected: $args" >&2; exit 99 ;;
esac
EOF

cat > "$T/bin/git" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *" clone "*) [ -z "${FAKE_CLONE_FAIL:-}" ] || { echo "fatal: clone failed" >&2; exit 128; }; mkdir -p "${!#}" ;;
  *" rev-parse HEAD") echo "${FAKE_CHECKOUT:-$FAKE_HEAD}" ;;
  *) : ;;
esac
EOF

cat > "$T/bin/lane" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%b\n' "$FAKE_REPLY"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/bin/"*

PASS=0; FAIL=0
# run <name> <expected rc> <expected statuses "state|state|..."> <env...> -- <script args...>
run(){
  local name=$1 want_rc=$2 want=$3; shift 3
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -f "$T/statuses" "$T/heads"
  env PATH="$T/bin:$PATH" T="$T" FAKE_HEAD=aaaaaaa1111111111111111111111111111111111 \
      AGENT_REVIEW_OUT="$T/out" AGENT_REVIEWER=gpt6pro GPT6PRO_BIN="$T/bin/lane" \
      FAKE_REPLY='findings\nVERDICT: APPROVE' "${envs[@]}" \
      bash "$SCRIPT" "$@" > "$T/log" 2>&1
  local rc=$? got; got=$(cut -d'|' -f1 "$T/statuses" 2>/dev/null | paste -sd'|' -)
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name: rc=$rc (want $want_rc) statuses='$got' (want '$want')"; sed 's/^/     /' "$T/log"; fi
}
last_desc(){ tail -1 "$T/statuses" | cut -d'|' -f2-; }

run "usage without args" 64 "" --
run "approve posts pending then success" 0 "pending|success" -- o/r 1 --post
run "dry run posts nothing" 0 "" -- o/r 1
run "request changes posts failure" 1 "pending|failure" FAKE_REPLY='VERDICT: REQUEST_CHANGES' -- o/r 1 --post
run "crashed lane never counts, even with a verdict" 1 "pending|error" FAKE_RC=1 -- o/r 1 --post
run "no verdict posts error" 1 "pending|error" FAKE_REPLY='I could not finish' -- o/r 1 --post
run "same-family lane is refused" 1 "pending|error" AGENT_WRITER_FAMILY=openai -- o/r 1 --post
run "oversized inline prompt makes the lane ineligible" 1 "pending|error" FAKE_DIFF_BYTES=250000 -- o/r 1 --post
run "clone failure after pending posts error" 128 "pending|error" FAKE_CLONE_FAIL=1 -- o/r 1 --post
run "checkout mismatch posts one specific error" 4 "pending|error" FAKE_CHECKOUT=bbbbbbb -- o/r 1 --post
case "$(last_desc)" in "checkout mismatch") PASS=$((PASS+1)); echo "ok   checkout mismatch keeps its description" ;; *) FAIL=$((FAIL+1)); echo "FAIL checkout mismatch description: $(last_desc)" ;; esac
run "head moved during review posts error" 3 "pending|error" FAKE_NEW_HEAD=ccccccc2222222222222222222222222222222222 -- o/r 1 --post
case "$(last_desc)" in *"head moved"*) PASS=$((PASS+1)); echo "ok   head move names the reason" ;; *) FAIL=$((FAIL+1)); echo "FAIL head move description: $(last_desc)" ;; esac
# shellcheck disable=SC2016  # the backticks are literal reviewer output
run "downgraded model is labelled degraded" 0 "pending|success" FAKE_REPLY='VERDICT: APPROVE\nthe server resolved `mini-model`' -- o/r 1 --post
case "$(last_desc)" in *"degraded: mini-model"*) PASS=$((PASS+1)); echo "ok   degraded label on status" ;; *) FAIL=$((FAIL+1)); echo "FAIL degraded description: $(last_desc)" ;; esac

# SIGTERM (outer timeout, CI cancel) during the review must not leave pending behind
rm -f "$T/statuses" "$T/heads"
printf '#!/usr/bin/env bash\nsleep 3\necho "VERDICT: APPROVE"\n' > "$T/bin/slowlane"; chmod +x "$T/bin/slowlane"
env PATH="$T/bin:$PATH" T="$T" FAKE_HEAD=aaaaaaa1111111111111111111111111111111111 AGENT_REVIEW_OUT="$T/out" \
    AGENT_REVIEWER=gpt6pro GPT6PRO_BIN="$T/bin/slowlane" bash "$SCRIPT" o/r 1 --post > "$T/log" 2>&1 &
pid=$!; sleep 1; kill -TERM "$pid"; wait "$pid"; rc=$?
got=$(cut -d'|' -f1 "$T/statuses" 2>/dev/null | paste -sd'|' -)
if [ "$rc" = 143 ] && [ "$got" = "pending|error" ]; then PASS=$((PASS+1)); echo "ok   SIGTERM posts error"
else FAIL=$((FAIL+1)); echo "FAIL SIGTERM: rc=$rc statuses='$got' (want 143, 'pending|error')"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
