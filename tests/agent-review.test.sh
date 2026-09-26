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
    # FAKE_STATUS_FAIL=<state>: that post fails once (not recorded), as a transient API error would
    if [ "${FAKE_STATUS_FAIL:-}" = "$state" ] && [ ! -e "$T/failed-once" ]; then touch "$T/failed-once"; echo "HTTP 502" >&2; exit 1; fi
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
  *" clone "*) [ -z "${FAKE_CLONE_FAIL:-}" ] || { echo "fatal: clone failed" >&2; exit 128; }; mkdir -p "${!#}"
    # a hostile PR can commit .agent-review/pr.txt as a symlink out of the checkout
    [ -z "${FAKE_PLANT:-}" ] || { mkdir -p "${!#}/.agent-review"; ln -s "$FAKE_PLANT" "${!#}/.agent-review/pr.txt"; } ;;
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
# devin shim: approves only if it was pinned to swe-2-max in the sandbox, its inputs are regular
# files inside the checkout, and the prompt points at them by relative path
cat > "$T/bin/devin" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_DEVIN_FAIL:-}" ] && { echo "devin: simulated failure"; exit 1; }
# FAKE_DEVIN_LIMITS=<n>: the first n runs hit the free-tier rate limit
n=$(( $(cat "$T/devin-runs" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/devin-runs"
echo "${0##*/}" >> "$T/devin-bins"
[ "$n" -le "${FAKE_DEVIN_LIMITS:-0}" ] && { echo "Error: Agent error: Reached free model rate limit. \"retryable\": true"; exit 1; }
[ "$1 $2 $3 $4" = "--model swe-2-max --sandbox -p" ] || { echo "bad flags: $*"; exit 2; }
for f in pr.txt pr.diff; do [ -f ".agent-review/$f" ] && [ ! -L ".agent-review/$f" ] || { echo "input $f missing or a symlink"; exit 3; }; done
case "$5" in *"PR metadata: .agent-review/pr.txt. Full diff: .agent-review/pr.diff."*) ;; *) echo "prompt paths not rewritten"; exit 4 ;; esac
echo "VERDICT: APPROVE"
EOF
chmod +x "$T/bin/"*
# a second account that is never rate-limited, and the shim renamed so only the named bin can run
cp "$T/bin/devin" "$T/bin/devin-b"

PASS=0; FAIL=0
# run <name> <expected rc> <expected statuses "state|state|..."> <env...> -- <script args...>
run(){
  local name=$1 want_rc=$2 want=$3; shift 3
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -f "$T/statuses" "$T/heads" "$T/failed-once" "$T/devin-runs" "$T/devin-bins"
  # start from a clean environment so caller-exported AGENT_*/FAKE_* values cannot leak in
  env -i HOME="$HOME" PATH="$T/bin:$PATH" T="$T" FAKE_HEAD=aaaaaaa1111111111111111111111111111111111 \
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
run "failed success post falls back to error, never stale pending" 1 "pending|error" FAKE_STATUS_FAIL=success -- o/r 1 --post
run "failed failure post falls back to error" 1 "pending|error" FAKE_STATUS_FAIL=failure FAKE_REPLY='VERDICT: REQUEST_CHANGES' -- o/r 1 --post
run "request changes posts failure" 1 "pending|failure" FAKE_REPLY='VERDICT: REQUEST_CHANGES' -- o/r 1 --post
run "crashed lane never counts, even with a verdict" 1 "pending|error" FAKE_RC=1 -- o/r 1 --post
run "no verdict posts error" 1 "pending|error" FAKE_REPLY='I could not finish' -- o/r 1 --post
run "same-family lane is refused" 1 "pending|error" AGENT_WRITER_FAMILY=openai -- o/r 1 --post
run "inline prompt over the 128 KiB env limit makes the lane ineligible" 1 "pending|error" FAKE_DIFF_BYTES=130000 -- o/r 1 --post
run "clone failure after pending posts error" 128 "pending|error" FAKE_CLONE_FAIL=1 -- o/r 1 --post
run "checkout mismatch posts one specific error" 4 "pending|error" FAKE_CHECKOUT=bbbbbbb -- o/r 1 --post
case "$(last_desc)" in "checkout mismatch") PASS=$((PASS+1)); echo "ok   checkout mismatch keeps its description" ;; *) FAIL=$((FAIL+1)); echo "FAIL checkout mismatch description: $(last_desc)" ;; esac
run "head moved during review posts error" 3 "pending|error" FAKE_NEW_HEAD=ccccccc2222222222222222222222222222222222 -- o/r 1 --post
case "$(last_desc)" in *"head moved"*) PASS=$((PASS+1)); echo "ok   head move names the reason" ;; *) FAIL=$((FAIL+1)); echo "FAIL head move description: $(last_desc)" ;; esac
# shellcheck disable=SC2016  # the backticks are literal reviewer output
run "downgraded model is labelled degraded" 0 "pending|success" FAKE_REPLY='VERDICT: APPROVE\nthe server resolved `mini-model`' -- o/r 1 --post
case "$(last_desc)" in *"degraded: mini-model"*) PASS=$((PASS+1)); echo "ok   degraded label on status" ;; *) FAIL=$((FAIL+1)); echo "FAIL degraded description: $(last_desc)" ;; esac

printf '#!/usr/bin/env bash\nsleep 5\necho "VERDICT: APPROVE"\n' > "$T/bin/slow5"; chmod +x "$T/bin/slow5"
run "lane over AGENT_REVIEW_TIMEOUT never counts" 1 "pending|error" AGENT_REVIEW_TIMEOUT=1 GPT6PRO_BIN="$T/bin/slow5" -- o/r 1 --post
echo "do not overwrite" > "$T/victim"
run "devin lane: pinned model, sandbox, staged inputs" 0 "pending|success" AGENT_REVIEWER=devin -- o/r 1 --post
run "devin lane: planted symlink is not written through" 0 "pending|success" AGENT_REVIEWER=devin FAKE_PLANT="$T/victim" -- o/r 1 --post
case "$(cat "$T/victim")" in "do not overwrite") PASS=$((PASS+1)); echo "ok   planted symlink target untouched" ;; *) FAIL=$((FAIL+1)); echo "FAIL planted symlink target was overwritten" ;; esac
run "devin rate limit is retried, then reviews" 0 "pending|success" AGENT_REVIEWER=devin FAKE_DEVIN_LIMITS=2 AGENT_REVIEW_BACKOFF=0 -- o/r 1 --post
run "devin rate limit on every try never counts" 1 "pending|error" AGENT_REVIEWER=devin FAKE_DEVIN_LIMITS=9 AGENT_REVIEW_BACKOFF=0 -- o/r 1 --post
if grep -q "rate limit" "$T/out/"*.md; then PASS=$((PASS+1)); echo "ok   receipt keeps the failed lane's error"; else FAIL=$((FAIL+1)); echo "FAIL receipt lacks the lane error"; fi
run "rate-limited account rotates to the next account" 0 "pending|success" AGENT_REVIEWER=devin AGENT_REVIEW_DEVIN_BINS="devin devin-b" FAKE_DEVIN_LIMITS=1 AGENT_REVIEW_BACKOFF=0 -- o/r 1 --post
case "$(paste -sd' ' "$T/devin-bins")" in "devin devin-b") PASS=$((PASS+1)); echo "ok   second account ran right after the limit" ;; *) FAIL=$((FAIL+1)); echo "FAIL account order: $(paste -sd' ' "$T/devin-bins")" ;; esac
run "failed lane falls through to the next lane" 0 "pending|success" AGENT_REVIEWER="devin gpt6pro" FAKE_DEVIN_FAIL=1 -- o/r 1 --post
case "$(last_desc)" in "gpt6pro: approve") PASS=$((PASS+1)); echo "ok   fallback verdict comes from the next lane" ;; *) FAIL=$((FAIL+1)); echo "FAIL fallback description: $(last_desc)" ;; esac

# SIGTERM (outer timeout, CI cancel) during the review must not leave pending behind
rm -f "$T/statuses" "$T/heads"
printf '#!/usr/bin/env bash\nsleep 3\necho "VERDICT: APPROVE"\n' > "$T/bin/slowlane"; chmod +x "$T/bin/slowlane"
env -i HOME="$HOME" PATH="$T/bin:$PATH" T="$T" FAKE_HEAD=aaaaaaa1111111111111111111111111111111111 AGENT_REVIEW_OUT="$T/out" \
    AGENT_REVIEWER=gpt6pro GPT6PRO_BIN="$T/bin/slowlane" bash "$SCRIPT" o/r 1 --post > "$T/log" 2>&1 &
pid=$!; sleep 1; kill -TERM "$pid"; wait "$pid"; rc=$?
got=$(cut -d'|' -f1 "$T/statuses" 2>/dev/null | paste -sd'|' -)
if [ "$rc" = 143 ] && [ "$got" = "pending|error" ]; then PASS=$((PASS+1)); echo "ok   SIGTERM posts error"
else FAIL=$((FAIL+1)); echo "FAIL SIGTERM: rc=$rc statuses='$got' (want 143, 'pending|error')"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
