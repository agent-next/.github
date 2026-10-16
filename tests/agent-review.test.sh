#!/usr/bin/env bash
# Hermetic tests for scripts/agent-review.sh: gh, git and the reviewer lanes are shims, so no
# network, GitHub status or model call is made (jq is real: the droid audit parses real JSON).
# Oracle: the exact sequence of agent-review statuses the script would post, plus its exit code.
# usage: bash tests/agent-review.test.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/agent-review.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
# FAKE_GH_HANG=<glob>: a gh call matching it hangs, as on a trickling link
case "$args" in ${FAKE_GH_HANG:-"no match"}) sleep 30 ;; esac
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
# the -C dir of the current call (the checkout's alternates are read from there)
dir=; prev=
for a in "$@"; do [ "$prev" = "-C" ] && dir=$a; prev=$a; done
case "$args" in
  *" clone "*)
    [ -z "${FAKE_CLONE_HANG:-}" ] || sleep 30
    case "$args" in *"http.lowSpeedLimit=1000"*"http.lowSpeedTime=120"*) ;; *) echo "clone without stall abort: $args" >&2; exit 97 ;; esac
    n=$(( $(cat "$T/clone-runs" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/clone-runs"
    case "$args" in *"blob:none"*) echo partial >> "$T/clone-filters" ;; *) echo full >> "$T/clone-filters" ;; esac
    # FAKE_CLONE_FAIL: every clone fails; FAKE_CLONE_FAIL_TIMES=<n>: the first n fail (a flaky link),
    # as the 2026-10-15 `curl 18 transfer closed` / promisor-fetch failure did
    if [ -n "${FAKE_CLONE_FAIL:-}" ] || [ "$n" -le "${FAKE_CLONE_FAIL_TIMES:-0}" ]; then
      echo "fatal: could not fetch abc from promisor remote" >&2; exit 128; fi
    # FAKE_PARTIAL_FAIL: only the blob:none clone fails; the unfiltered fallback clone works
    case "$args" in *"blob:none"*) [ -z "${FAKE_PARTIAL_FAIL:-}" ] || { echo "curl 18 transfer closed with outstanding read data remaining" >&2; exit 128; } ;; esac
    mkdir -p "${!#}/.git/objects/info"
    # a hostile PR can commit .agent-review/pr.txt as a symlink out of the checkout
    [ -z "${FAKE_PLANT:-}" ] || { mkdir -p "${!#}/.agent-review"; ln -s "$FAKE_PLANT" "${!#}/.agent-review/pr.txt"; } ;;
  *" config http.lowSpeed"*) echo "${args##*config }" >> "$T/git-config" ;;
  *" fetch "*)
    [ -z "${FAKE_FETCH_HANG:-}" ] || sleep 30
    echo "$args" >> "$T/fetch-args"
    n=$(( $(cat "$T/fetch-runs" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/fetch-runs"
    [ "$n" -le "${FAKE_FETCH_FAIL_TIMES:-0}" ] && { echo "curl 18 transfer closed" >&2; exit 128; }
    # the stall abort must be persisted in the clone, not only passed to clone
    [ "$(paste -sd' ' "$T/git-config" 2>/dev/null)" = "http.lowSpeedLimit 1000 http.lowSpeedTime 120" ] || { echo "fetch without stall abort" >&2; exit 97; } ;;
  *" checkout "*)
    [ -z "${FAKE_CHECKOUT_HANG:-}" ] || sleep 30
    n=$(( $(cat "$T/checkout-runs" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/checkout-runs"
    # FAKE_CHECKOUT_FAIL_TIMES=<n>: the first n checkouts fail (a lazy promisor blob fetch), as the
    # clone can: the checkout must retry, then fall back to fetching every object
    [ "$n" -le "${FAKE_CHECKOUT_FAIL_TIMES:-0}" ] && { echo "fatal: could not fetch $FAKE_HEAD from promisor remote" >&2; exit 128; }
    # the alternates the script appended for AGENT_REVIEW_REFERENCE, if any
    if [ -n "$dir" ] && [ -f "$dir/.git/objects/info/alternates" ]; then cp "$dir/.git/objects/info/alternates" "$T/alternates"; fi ;;
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
[ "$n" -le "${FAKE_DEVIN_LIMITS:-0}" ] && { echo "Error: Agent error: ${FAKE_DEVIN_LIMIT_MSG:-Reached free model rate limit.} \"retryable\": true"; exit 1; }
[ "$1 $2 $3 $4" = "--model swe-2-max --sandbox -p" ] || { echo "bad flags: $*"; exit 2; }
for f in pr.txt pr.diff; do [ -f ".agent-review/$f" ] && [ ! -L ".agent-review/$f" ] || { echo "input $f missing or a symlink"; exit 3; }; done
case "$5" in *"PR metadata: .agent-review/pr.txt. Full diff: .agent-review/pr.diff."*) ;; *) echo "prompt paths not rewritten"; exit 4 ;; esac
echo "VERDICT: APPROVE"
EOF
# ccz shim: approves only if pinned to glm-5.3, headless, and not steered by an inherited CCZ_TIER
cat > "$T/bin/ccz" <<'EOF'
#!/usr/bin/env bash
[ -z "${CCZ_TIER+x}" ] || { echo "CCZ_TIER leaked: $CCZ_TIER"; exit 5; }
[ "${CLAUDE_CODE_DISABLE_CLAUDE_MDS:-}" = 1 ] || { echo "host CLAUDE.md files would steer the reviewer"; exit 6; }
# --safe-mode: hooks, MCP servers and plugins a PR ships in .claude/ must not load
[ "$1 $2 $3 $4" = "--safe-mode --model glm-5.3 --add-dir" ] || { echo "bad flags: $*"; exit 2; }
[ -f "$5/pr.txt" ] && [ -f "$5/pr.diff" ] || { echo "review inputs not reachable via --add-dir: $5"; exit 4; }
case " $* " in *" -p "*) ;; *) echo "not headless"; exit 3 ;; esac
echo "VERDICT: APPROVE"
EOF
# droid shim: emits the stream-json event stream and writes the session file the served-model audit
# reads. It refuses to run unless it was pinned to claude-opus-5-5 AND asked for stream-json, so a lane
# that loses either flag cannot quietly pass the audit.
# grok/agy shims: they left the default chain but stay callable, so the lane flags are still pinned
cat > "$T/bin/grok" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T/grok-args"
case " $* " in *" --always-approve "*) ;; *) echo "grok ran without --always-approve: $*"; exit 2 ;; esac
case " $* " in *" --cwd "*) ;; *) echo "grok ran without --cwd: $*"; exit 3 ;; esac
case " $* " in *" -p "*) ;; *) echo "grok not headless: $*"; exit 4 ;; esac
echo "VERDICT: APPROVE"
EOF
cat > "$T/bin/agy" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T/agy-args"
case " $* " in *" --dangerously-skip-permissions "*) ;; *) echo "agy ran without --dangerously-skip-permissions: $*"; exit 2 ;; esac
case " $* " in *" --add-dir "*) ;; *) echo "agy ran without --add-dir: $*"; exit 3 ;; esac
case " $* " in *" -p "*) ;; *) echo "agy not headless: $*"; exit 4 ;; esac
echo "VERDICT: APPROVE"
EOF
cat > "$T/bin/droid" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_DROID_FAIL:-}" ] || { echo "droid: simulated failure"; exit 1; }
echo "$*" >> "$T/droid-args"
case " $* " in *" -o stream-json "*) ;; *) echo "droid ran without -o stream-json: $*"; exit 5 ;; esac
case " $* " in *" -m claude-opus-5-5 "*) ;; *) echo "droid not pinned to claude-opus-5-5: $*"; exit 6 ;; esac
cwd=; prev=
for a in "$@"; do [ "$prev" = "--cwd" ] && cwd=$a; prev=$a; done
[ -n "$cwd" ] || { echo "droid ran without --cwd"; exit 7; }
# FAKE_DROID_SECOND_RUN_NO_SESSION: run 2 emits a verdict but writes no session file, so a repeated
# droid lane cannot inherit run 1's tally (the per-lane state reset must hold)
n=$(( $(cat "$T/droid-runs" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/droid-runs"
if [ "$n" -gt 1 ] && [ -n "${FAKE_DROID_SECOND_RUN_NO_SESSION:-}" ]; then
  printf '{"type":"system","session_id":"sess-0000000000000002","model":"claude-opus-5-5"}\n'
  jq -cn --arg t "${FAKE_DROID_REPLY:-findings
VERDICT: APPROVE}" '{type:"completion",finalText:$t}'
  exit 0
fi
sid=sess-0000000000000001
printf '{"type":"system","session_id":"%s","model":"claude-opus-5-5"}\n' "$sid"
if [ "${FAKE_DROID_EVENTS:-stream}" = stream ]; then
  jq -cn --arg t "${FAKE_DROID_REPLY:-findings
VERDICT: APPROVE}" '{type:"completion",finalText:$t}'
fi
[ -z "${FAKE_DROID_NO_SESSION:-}" ] || exit 0
slug=$(printf '%s' "$cwd" | tr / -)
mkdir -p "${AGENT_REVIEW_FACTORY_HOME:?}/sessions/$slug"
sess="${AGENT_REVIEW_FACTORY_HOME}/sessions/$slug/$sid.jsonl"
if [ -n "${FAKE_DROID_NO_MODEL:-}" ]; then
  printf '{"type":"message","message":{"text":"no model here"}}\n' > "$sess"
else
  {
    # FAKE_DROID_MODELS_FIRST: one extra line before the cycled models (a lone mismatch in a long session)
    [ -z "${FAKE_DROID_MODELS_FIRST:-}" ] || printf '{"type":"message","message":{"modelId":"%s","apiProvider":"fake-provider"}}\n' "$FAKE_DROID_MODELS_FIRST"
    r=0
    while [ "$r" -lt "${FAKE_DROID_REPEAT:-1}" ]; do
      for m in ${FAKE_DROID_MODELS:-claude-opus-5-5}; do
        printf '{"type":"message","message":{"modelId":"%s","apiProvider":"fake-provider"}}\n' "$m"
      done
      r=$((r+1))
    done
  } > "$sess"
fi
EOF
chmod +x "$T/bin/"*
# a second account that is never rate-limited, and the shim renamed so only the named bin can run
cp "$T/bin/devin" "$T/bin/devin-b"

PASS=0; FAIL=0
# run <name> <expected rc> <expected statuses "state|state|..."> <env...> -- <script args...>
# the base environment uses the ccz lane with the generic `lane` shim; a test that cares about another
# lane overrides AGENT_REVIEWER (env(1) takes the last assignment for a repeated name)
run(){
  local name=$1 want_rc=$2 want=$3; shift 3
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -f "$T/statuses" "$T/heads" "$T/failed-once" "$T/devin-runs" "$T/devin-bins" "$T/git-config" \
        "$T/clone-runs" "$T/clone-filters" "$T/fetch-runs" "$T/droid-args" "$T/grok-args" "$T/agy-args" \
        "$T/checkout-runs" "$T/alternates" "$T/droid-runs" "$T/fetch-args"
  rm -rf "$T/factory" "$T/out"   # each run gets its own receipts, so the checks below read only its own
  # start from a clean environment so caller-exported AGENT_*/FAKE_* values cannot leak in
  env -i HOME="$HOME" PATH="$T/bin:$PATH" T="$T" FAKE_HEAD=aaaaaaa1111111111111111111111111111111111 \
      AGENT_REVIEW_OUT="$T/out" AGENT_REVIEWER=ccz AGENT_WRITER_FAMILY=gemini CCZ_BIN="$T/bin/lane" \
      AGENT_REVIEW_FACTORY_HOME="$T/factory" AGENT_REVIEW_CLONE_BACKOFF=0 \
      FAKE_REPLY='findings\nVERDICT: APPROVE' "${envs[@]}" \
      bash "$SCRIPT" "$@" > "$T/log" 2>&1
  local rc=$? got; got=$(cut -d'|' -f1 "$T/statuses" 2>/dev/null | paste -sd'|' -)
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name: rc=$rc (want $want_rc) statuses='$got' (want '$want')"; sed 's/^/     /' "$T/log"; fi
}
last_desc(){ tail -1 "$T/statuses" | cut -d'|' -f2-; }
# check <name> <grep -q pattern> <file glob>
check(){ if grep -qE -- "$2" $3 2>/dev/null; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 (no match for '$2' in $3)"; fi; }

run "usage without args" 64 "" --
run "approve posts pending then success" 0 "pending|success" -- o/r 1 --post
run "dry run posts nothing" 0 "" -- o/r 1
run "failed success post falls back to error, never stale pending" 1 "pending|error" FAKE_STATUS_FAIL=success -- o/r 1 --post
run "failed failure post falls back to error" 1 "pending|error" FAKE_STATUS_FAIL=failure FAKE_REPLY='VERDICT: REQUEST_CHANGES' -- o/r 1 --post
run "request changes posts failure" 1 "pending|failure" FAKE_REPLY='VERDICT: REQUEST_CHANGES' -- o/r 1 --post
run "crashed lane never counts, even with a verdict" 1 "pending|error" FAKE_RC=1 -- o/r 1 --post
run "no verdict posts error" 1 "pending|error" FAKE_REPLY='I could not finish' -- o/r 1 --post
run "same-family lane is refused" 1 "pending|error" AGENT_WRITER_FAMILY=zai -- o/r 1 --post
check "refused lane names the family in the receipt" "skip ccz: same family as a writer \(zai\)" "$T/out/*.md"
# no lane has an inline-prompt size cap any more (the gpt6pro lane, which had one, is gone), so a 130 KB
# diff still reaches the lane; a small diff and a large one must behave the same
run "a large diff still reaches the lane" 0 "pending|success" FAKE_DIFF_BYTES=130000 -- o/r 1 --post
run "clone failure after pending posts error" 128 "pending|error" FAKE_CLONE_FAIL=1 -- o/r 1 --post
run "hung clone hits the network timeout and posts error" 124 "pending|error" FAKE_CLONE_HANG=1 AGENT_REVIEW_NET_TIMEOUT=2 -- o/r 1 --post
run "hung fetch hits the network timeout and posts error" 124 "pending|error" FAKE_FETCH_HANG=1 AGENT_REVIEW_NET_TIMEOUT=2 -- o/r 1 --post
run "hung checkout hits the network timeout and posts error" 124 "pending|error" FAKE_CHECKOUT_HANG=1 AGENT_REVIEW_NET_TIMEOUT=2 -- o/r 1 --post
run "hung pending post is overwritten by error, never left pending" 124 "error" FAKE_GH_HANG='*state=pending*' AGENT_REVIEW_NET_TIMEOUT=2 -- o/r 1 --post
run "hung head lookup exits before any status" 124 "" FAKE_GH_HANG='*--json headRefOid*' AGENT_REVIEW_NET_TIMEOUT=2 -- o/r 1 --post
run "hung diff download hits the network timeout and posts error" 124 "pending|error" FAKE_GH_HANG='pr diff*' AGENT_REVIEW_NET_TIMEOUT=2 -- o/r 1 --post
run "hung error post in the cleanup trap still exits" 128 "pending" FAKE_CLONE_FAIL=1 FAKE_GH_HANG='*state=error*' AGENT_REVIEW_NET_TIMEOUT=2 -- o/r 1 --post
run "checkout mismatch posts one specific error" 4 "pending|error" FAKE_CHECKOUT=bbbbbbb -- o/r 1 --post
case "$(last_desc)" in "checkout mismatch") PASS=$((PASS+1)); echo "ok   checkout mismatch keeps its description" ;; *) FAIL=$((FAIL+1)); echo "FAIL checkout mismatch description: $(last_desc)" ;; esac
run "head moved during review posts error" 3 "pending|error" FAKE_NEW_HEAD=ccccccc2222222222222222222222222222222222 -- o/r 1 --post
case "$(last_desc)" in *"head moved"*) PASS=$((PASS+1)); echo "ok   head move names the reason" ;; *) FAIL=$((FAIL+1)); echo "FAIL head move description: $(last_desc)" ;; esac
# shellcheck disable=SC2016  # the backticks are literal reviewer output
run "downgraded model is labelled degraded" 0 "pending|success" FAKE_REPLY='VERDICT: APPROVE\nthe server resolved `mini-model`' -- o/r 1 --post
case "$(last_desc)" in *"degraded: mini-model"*) PASS=$((PASS+1)); echo "ok   degraded label on status" ;; *) FAIL=$((FAIL+1)); echo "FAIL degraded description: $(last_desc)" ;; esac

printf '#!/usr/bin/env bash\nsleep 5\necho "VERDICT: APPROVE"\n' > "$T/bin/slow5"; chmod +x "$T/bin/slow5"
run "lane over AGENT_REVIEW_TIMEOUT never counts" 1 "pending|error" AGENT_REVIEW_TIMEOUT=1 CCZ_BIN="$T/bin/slow5" -- o/r 1 --post
# a lane that ignores SIGTERM must still be killed, AGENT_REVIEW_KILL_AFTER seconds after the limit
printf '#!/usr/bin/env bash\ntrap "" TERM\nsleep 20\necho "VERDICT: APPROVE"\n' > "$T/bin/stubborn"; chmod +x "$T/bin/stubborn"
t0=$SECONDS
run "lane ignoring SIGTERM is killed and never counts" 1 "pending|error" AGENT_REVIEW_TIMEOUT=1 AGENT_REVIEW_KILL_AFTER=1 CCZ_BIN="$T/bin/stubborn" -- o/r 1 --post
if [ $((SECONDS - t0)) -lt 10 ]; then PASS=$((PASS+1)); echo "ok   stubborn lane killed in $((SECONDS - t0)) s, not after its 20 s run"; else FAIL=$((FAIL+1)); echo "FAIL stubborn lane held the gate $((SECONDS - t0)) s"; fi
echo "do not overwrite" > "$T/victim"
run "devin lane: pinned model, sandbox, staged inputs" 0 "pending|success" AGENT_REVIEWER=devin -- o/r 1 --post
run "devin lane: planted symlink is not written through" 0 "pending|success" AGENT_REVIEWER=devin FAKE_PLANT="$T/victim" -- o/r 1 --post
case "$(cat "$T/victim")" in "do not overwrite") PASS=$((PASS+1)); echo "ok   planted symlink target untouched" ;; *) FAIL=$((FAIL+1)); echo "FAIL planted symlink target was overwritten" ;; esac
run "devin rate limit is retried, then reviews" 0 "pending|success" AGENT_REVIEWER=devin FAKE_DEVIN_LIMITS=2 AGENT_REVIEW_BACKOFF=0 -- o/r 1 --post
run "devin rate limit on every try never counts" 1 "pending|error" AGENT_REVIEWER=devin FAKE_DEVIN_LIMITS=9 AGENT_REVIEW_BACKOFF=0 -- o/r 1 --post
if grep -q "rate limit" "$T/out/"*.md; then PASS=$((PASS+1)); echo "ok   receipt keeps the failed lane's error"; else FAIL=$((FAIL+1)); echo "FAIL receipt lacks the lane error"; fi
run "rate-limited account rotates to the next account" 0 "pending|success" AGENT_REVIEWER=devin AGENT_REVIEW_DEVIN_BINS="devin devin-b" FAKE_DEVIN_LIMITS=1 AGENT_REVIEW_BACKOFF=0 -- o/r 1 --post
case "$(paste -sd' ' "$T/devin-bins")" in "devin devin-b") PASS=$((PASS+1)); echo "ok   second account ran right after the limit" ;; *) FAIL=$((FAIL+1)); echo "FAIL account order: $(paste -sd' ' "$T/devin-bins")" ;; esac
run "account out of weekly quota rotates to the next account" 0 "pending|success" AGENT_REVIEWER=devin AGENT_REVIEW_DEVIN_BINS="devin devin-b" FAKE_DEVIN_LIMITS=1 FAKE_DEVIN_LIMIT_MSG="Your weekly usage quota has been exhausted." AGENT_REVIEW_BACKOFF=0 -- o/r 1 --post
run "devin-sol is no longer a lane" 64 "pending|error" AGENT_REVIEWER=devin-sol -- o/r 1 --post
if grep -q "unknown reviewer lane devin-sol" "$T/log"; then PASS=$((PASS+1)); echo "ok   unknown lane names itself in the log"; else FAIL=$((FAIL+1)); echo "FAIL log lacks the unknown-lane message"; fi
run "devin-sol fails closed for the writer family it used to accept" 64 "pending|error" AGENT_REVIEWER=devin-sol AGENT_WRITER_FAMILY=cognition -- o/r 1 --post
run "ccz stand-in: pinned model, inherited CCZ_TIER dropped" 0 "pending|success" CCZ_TIER=some-other-tier -- o/r 1 --post
case "$(last_desc)" in "ccz: approve") PASS=$((PASS+1)); echo "ok   ccz verdict is attributed to ccz" ;; *) FAIL=$((FAIL+1)); echo "FAIL ccz description: $(last_desc)" ;; esac
run "every family in a writer list is refused" 1 "pending|error" AGENT_REVIEWER="devin ccz" AGENT_WRITER_FAMILY=cognition,zai -- o/r 1 --post
if grep -q "skip devin: same family" "$T/out/"*.md; then PASS=$((PASS+1)); echo "ok   receipt records why a lane was skipped"; else FAIL=$((FAIL+1)); echo "FAIL receipt lacks the skip reason"; fi
run "writer list with spaces and capitals still refuses every family" 1 "pending|error" AGENT_REVIEWER="devin ccz" AGENT_WRITER_FAMILY="Anthropic, Cognition , ZAI" -- o/r 1 --post
run "model-name writer alias refuses its family's lane" 1 "pending|error" AGENT_WRITER_FAMILY=GLM -- o/r 1 --post
if grep -q "skip ccz: same family as a writer (zai)" "$T/out/"*.md; then PASS=$((PASS+1)); echo "ok   glm alias maps to zai"; else FAIL=$((FAIL+1)); echo "FAIL glm alias not mapped to zai"; fi
run "claude writer alias still lets other families review" 0 "pending|success" AGENT_WRITER_FAMILY=claude -- o/r 1 --post
run "misspelled writer family fails closed" 64 "pending|error" AGENT_WRITER_FAMILY=cognitoin -- o/r 1 --post
case "$(last_desc)" in "unknown writer family") PASS=$((PASS+1)); echo "ok   unknown family names the reason" ;; *) FAIL=$((FAIL+1)); echo "FAIL unknown family description: $(last_desc)" ;; esac
run "empty writer list fails closed" 64 "pending|error" AGENT_WRITER_FAMILY=", ," -- o/r 1 --post
case "$(last_desc)" in "empty writer family") PASS=$((PASS+1)); echo "ok   empty list names its own reason" ;; *) FAIL=$((FAIL+1)); echo "FAIL empty list description: $(last_desc)" ;; esac
# a glob in the list must not expand against the runner's cwd (here a file named like a family)
mkdir -p "$T/globcwd" && touch "$T/globcwd/anthropic" && cd "$T/globcwd" || exit 1
run "glob in writer list fails closed, never expands to file names" 64 "pending|error" AGENT_WRITER_FAMILY='*' -- o/r 1 --post
case "$(last_desc)" in "unknown writer family") PASS=$((PASS+1)); echo "ok   glob writer list names the reason" ;; *) FAIL=$((FAIL+1)); echo "FAIL glob writer list description: $(last_desc)" ;; esac
rm -f "$T/globcwd/anthropic"; touch "$T/globcwd/gpt6pro"
run "glob in reviewer list is an unknown lane, never a file name" 64 "pending|error" AGENT_REVIEWER='*' -- o/r 1 --post
rm -f "$T/globcwd/gpt6pro"; touch "$T/globcwd/devin-b"
run "glob in devin account list never runs a file-named binary" 1 "pending|error" AGENT_REVIEWER=devin AGENT_REVIEW_DEVIN_BINS='*' AGENT_REVIEW_BACKOFF=0 -- o/r 1 --post
cd - >/dev/null || exit 1
run "failed lane falls through to the next lane" 0 "pending|success" AGENT_REVIEWER="devin ccz" FAKE_DEVIN_FAIL=1 -- o/r 1 --post
case "$(last_desc)" in "ccz: approve") PASS=$((PASS+1)); echo "ok   fallback verdict comes from the next lane" ;; *) FAIL=$((FAIL+1)); echo "FAIL fallback description: $(last_desc)" ;; esac

echo "--- lane roster ---"
# criterion 2: gpt6pro is gone (owner 2026-10-14: never gpt-6), grok and agy stay callable but out of
# the default chain, and the default chain is exactly droid -> devin -> ccz
run "gpt6pro is no longer a lane" 64 "pending|error" AGENT_REVIEWER=gpt6pro -- o/r 1 --post
check "gpt6pro names itself as unknown" "unknown reviewer lane gpt6pro" "$T/log"
run "default chain falls from droid to devin to ccz" 0 "pending|success" AGENT_REVIEWER= FAKE_DROID_FAIL=1 FAKE_DEVIN_FAIL=1 -- o/r 1 --post
case "$(last_desc)" in "ccz: approve") PASS=$((PASS+1)); echo "ok   third default lane is ccz" ;; *) FAIL=$((FAIL+1)); echo "FAIL third default lane: $(last_desc)" ;; esac
check "default chain tried droid first" "reviewer droid not usable \(exit 1\)" "$T/out/*.md"
check "default chain then tried devin" "reviewer devin not usable \(exit 1\)" "$T/out/*.md"
run "grok stays callable outside the default chain" 0 "pending|success" AGENT_REVIEWER=grok AGENT_WRITER_FAMILY=claude -- o/r 1 --post
check "grok runs with its pinned flags" "--always-approve" "$T/grok-args"
run "agy stays callable outside the default chain" 0 "pending|success" AGENT_REVIEWER=agy AGENT_WRITER_FAMILY=claude -- o/r 1 --post
check "agy runs with its pinned flags" "--dangerously-skip-permissions" "$T/agy-args"

echo "--- droid lane and served-model audit ---"
# criterion 5: the verdict counts only if every modelId in the session file is the requested model.
# AGENT_WRITER_FAMILY=gemini keeps the anthropic droid lane eligible here (criterion 3 tests the skip).
run "droid approves with a served-model audit" 0 "pending|success" AGENT_REVIEWER=droid AGENT_REVIEW_DROID_BIN="$T/bin/droid" -- o/r 1 --post
case "$(last_desc)" in "droid: approve") PASS=$((PASS+1)); echo "ok   droid verdict is attributed to droid" ;; *) FAIL=$((FAIL+1)); echo "FAIL droid description: $(last_desc)" ;; esac
check "receipt header records the served model" "served: claude-opus-5-5 via fake-provider" "$T/out/*.md"
check "droid verdict counts, so the chain stops there" "verdict: APPROVE" "$T/out/*.md"
check "the receipt records the session id and file, so the audit can be re-checked" "session id: sess-0000000000000001" "$T/out/*.md"
check "receipt names the session file it audited" "session file: .*/sessions/-tmp-tmp\..*-src/sess-0000000000000001.jsonl" "$T/out/*.md"
if grep -qF '"type":"system","session_id":"sess-0000000000000001"' "$T/out/"*.events.jsonl 2>/dev/null && grep -qF '"type":"completion","finalText":"findings' "$T/out/"*.events.jsonl; then PASS=$((PASS+1)); echo "ok   the event stream is kept next to the receipt as <receipt>.events.jsonl"
else FAIL=$((FAIL+1)); echo "FAIL events.jsonl next to the receipt is not the lane's event stream"; fi
# the session file lives under the review cwd with every / replaced by - (/tmp/tmp.X/src -> -tmp-tmp.X-src)
case "$(ls "$T/factory/sessions" 2>/dev/null)" in -tmp-tmp.*-src) PASS=$((PASS+1)); echo "ok   session dir is the cwd slug" ;; *) FAIL=$((FAIL+1)); echo "FAIL session dir slug: $(ls "$T/factory/sessions" 2>/dev/null)" ;; esac
run "droid served-model mismatch falls through to the next lane" 0 "pending|success" AGENT_REVIEWER="droid devin" AGENT_REVIEW_DROID_BIN="$T/bin/droid" \
    FAKE_DROID_MODELS="claude-opus-5-5 kimi-k3 kimi-k3" -- o/r 1 --post
case "$(last_desc)" in "devin: approve") PASS=$((PASS+1)); echo "ok   mismatched droid verdict is discarded" ;; *) FAIL=$((FAIL+1)); echo "FAIL mismatch fallthrough: $(last_desc)" ;; esac
check "receipt records the mismatch counts" "served-model mismatch: claude-opus-5-5=1 kimi-k3=2" "$T/out/*.md"
check "the discarded droid verdict is not in the receipt" "reviewer: devin" "$T/out/*.md"
check "the discard line names the served-model reason" "reviewer droid not usable \(served-model mismatch: claude-opus-5-5=1 kimi-k3=2\) \(exit 0\)" "$T/out/*.md"
# review finding (blocker): a long session with ONE mismatched line must fail the audit every time.
# `jq | grep -q` under pipefail races (grep exits on the first hit, jq dies on SIGPIPE), so a long
# mismatched session could pass; this must be rejected 10 runs out of 10, not most of them
rejected=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  run "long session, one mismatched line, run $i of 10" 0 "pending|success" AGENT_REVIEWER="droid devin" \
      AGENT_REVIEW_DROID_BIN="$T/bin/droid" FAKE_DROID_MODELS_FIRST=kimi-k3 FAKE_DROID_MODELS=claude-opus-5-5 \
      FAKE_DROID_REPEAT=5000 -- o/r 1 --post
  grep -q "served-model mismatch" "$T/out/"*.md && rejected=$((rejected+1))
done
if [ "$rejected" -eq 10 ]; then PASS=$((PASS+1)); echo "ok   a 5001-line session with one mismatch is rejected 10/10"
else FAIL=$((FAIL+1)); echo "FAIL long mismatched session rejected only $rejected/10 times"; fi
run "droid with no session file falls through to the next lane" 0 "pending|success" AGENT_REVIEWER="droid devin" AGENT_REVIEW_DROID_BIN="$T/bin/droid" \
    FAKE_DROID_NO_SESSION=1 -- o/r 1 --post
case "$(last_desc)" in "devin: approve") PASS=$((PASS+1)); echo "ok   missing session file never counts" ;; *) FAIL=$((FAIL+1)); echo "FAIL missing-session fallthrough: $(last_desc)" ;; esac
check "receipt records the missing session file" "served-model mismatch: no session file" "$T/out/*.md"
run "droid session file without a modelId never counts" 1 "pending|error" AGENT_REVIEWER=droid AGENT_REVIEW_DROID_BIN="$T/bin/droid" \
    FAKE_DROID_NO_MODEL=1 -- o/r 1 --post
check "receipt records the missing modelId" "served-model mismatch: no modelId recorded" "$T/out/*.md"
run "droid run with no completion event has no verdict" 1 "pending|error" AGENT_REVIEWER=droid AGENT_REVIEW_DROID_BIN="$T/bin/droid" \
    FAKE_DROID_EVENTS=none -- o/r 1 --post
check "no completion event means no review text" "verdict: NONE" "$T/out/*.md"

echo "--- writer family vs the droid lane (criterion 3) ---"
# droid is a lane like any other: an anthropic writer skips it and the chain falls through to devin
run "anthropic writer skips the droid lane and devin reviews" 0 "pending|success" AGENT_REVIEWER="droid devin" AGENT_WRITER_FAMILY=claude \
    AGENT_REVIEW_DROID_BIN="$T/bin/droid" -- o/r 1 --post
case "$(last_desc)" in "devin: approve") PASS=$((PASS+1)); echo "ok   anthropic writer fell through to devin" ;; *) FAIL=$((FAIL+1)); echo "FAIL anthropic fallthrough: $(last_desc)" ;; esac
check "receipt says droid was skipped for its family" "skip droid: same family as a writer \(anthropic\)" "$T/out/*.md"
case "$(cat "$T/droid-args" 2>/dev/null)" in "") PASS=$((PASS+1)); echo "ok   the droid lane never ran" ;; *) FAIL=$((FAIL+1)); echo "FAIL droid ran for an anthropic writer: $(cat "$T/droid-args")" ;; esac
run "anthropic writer with only the droid lane leaves no verdict" 1 "pending|error" AGENT_REVIEWER=droid AGENT_WRITER_FAMILY=Anthropic,opus \
    AGENT_REVIEW_DROID_BIN="$T/bin/droid" -- o/r 1 --post
run "opus writer alias also skips the droid lane" 1 "pending|error" AGENT_REVIEWER=droid AGENT_WRITER_FAMILY=opus \
    AGENT_REVIEW_DROID_BIN="$T/bin/droid" -- o/r 1 --post
run "non-anthropic writer still gets the droid lane" 0 "pending|success" AGENT_REVIEWER=droid AGENT_WRITER_FAMILY=gemini \
    AGENT_REVIEW_DROID_BIN="$T/bin/droid" -- o/r 1 --post

echo "--- deployment writer aliases (AGENT_REVIEW_FAMILY_ALIASES, criterion 4) ---"
# The script hard-codes no pool ids: a deployment names its own ids through
# AGENT_REVIEW_FAMILY_ALIASES, and a pooled id must count as the family that pool actually serves
# (it can silently serve any member), so the matching reviewer lane is refused. Exact keys and
# pattern keys (trailing *) both work; the pattern matches the whole id.
ALIASES="pool-a=zai,pool-b=google,pool-*=zai,unmapped-*=google"
run "a named pool writer refuses that family's lane" 1 "pending|error" \
    AGENT_REVIEW_FAMILY_ALIASES="$ALIASES" AGENT_WRITER_FAMILY=pool-a -- o/r 1 --post
check "pool writer is recorded as its pool's family" "skip ccz: same family as a writer .zai." "$T/out/*.md"
run "a pattern alias refuses its family's lane" 1 "pending|error" \
    AGENT_REVIEW_FAMILY_ALIASES="$ALIASES" AGENT_WRITER_FAMILY=pool-anything-else -- o/r 1 --post
check "pattern writer is recorded as the pattern's family" "skip ccz: same family as a writer .zai." "$T/out/*.md"
# an exact key must win over a pattern that also matches it, whatever the hash order: pool-b is
# google, even though pool-* says zai. Without the precedence, a pooled id could refuse the wrong
# lane and let the pool's real family review its own PR.
run "an exact alias key wins over a matching pattern" 0 "pending|success" AGENT_REVIEWER="agy ccz" \
    AGENT_REVIEW_FAMILY_ALIASES="$ALIASES" AGENT_WRITER_FAMILY=pool-b -- o/r 1 --post
check "the exact key's family is the one refused" "skip agy: same family as a writer .google." "$T/out/*.md"
run "an id matching a later pattern still refuses its family's lane" 1 "pending|error" \
    AGENT_REVIEWER=agy AGENT_REVIEW_FAMILY_ALIASES="$ALIASES" AGENT_WRITER_FAMILY=unmapped-42 -- o/r 1 --post
check "later-pattern writer is recorded as its family" "skip agy: same family as a writer .google." "$T/out/*.md"
run "a pool writer list mixes aliases, patterns and families" 1 "pending|error" AGENT_REVIEWER="devin ccz" \
    AGENT_REVIEW_FAMILY_ALIASES="$ALIASES" AGENT_WRITER_FAMILY="pool-a, cognition" -- o/r 1 --post
run "a pool writer is not the anthropic family, so droid still reviews" 0 "pending|success" AGENT_REVIEWER=droid \
    AGENT_REVIEW_FAMILY_ALIASES="$ALIASES" AGENT_WRITER_FAMILY=pool-a AGENT_REVIEW_DROID_BIN="$T/bin/droid" -- o/r 1 --post
run "an alias entry without = fails closed" 64 "pending|error" \
    AGENT_REVIEW_FAMILY_ALIASES="pool-a" AGENT_WRITER_FAMILY=pool-a -- o/r 1 --post
run "an alias entry with an unknown family fails closed" 64 "pending|error" \
    AGENT_REVIEW_FAMILY_ALIASES="pool-a=notafamily" AGENT_WRITER_FAMILY=pool-a -- o/r 1 --post

echo "--- robust checkout (criterion 6) ---"
run "a flaky first clone is retried and recovers" 0 "pending|success" FAKE_CLONE_FAIL_TIMES=1 -- o/r 1 --post
check "the retry is logged" "clone failed .try 1/3, exit 128, [0-9]+ s left." "$T/log"
case "$(cat "$T/clone-runs" 2>/dev/null)" in 2) PASS=$((PASS+1)); echo "ok   exactly one retry was needed" ;; *) FAIL=$((FAIL+1)); echo "FAIL clone attempts: $(cat "$T/clone-runs" 2>/dev/null)" ;; esac
run "a flaky fetch is retried and recovers" 0 "pending|success" FAKE_FETCH_FAIL_TIMES=2 -- o/r 1 --post
check "the fetch retry is logged" "fetch failed .try 2/3, exit 128, [0-9]+ s left." "$T/log"
run "a partial clone that never succeeds falls back to a full clone" 0 "pending|success" FAKE_PARTIAL_FAIL=1 -- o/r 1 --post
check "the fallback is logged" "falling back to a full clone without a filter" "$T/log"
case "$(paste -sd' ' "$T/clone-filters" 2>/dev/null)" in "partial partial partial full") PASS=$((PASS+1)); echo "ok   three partial attempts, then one unfiltered clone" ;; *) FAIL=$((FAIL+1)); echo "FAIL clone filters: $(paste -sd' ' "$T/clone-filters" 2>/dev/null)" ;; esac
run "every clone attempt failing still posts error" 128 "pending|error" FAKE_PARTIAL_FAIL=1 FAKE_CLONE_FAIL=1 -- o/r 1 --post
case "$(cat "$T/clone-runs" 2>/dev/null)" in 6) PASS=$((PASS+1)); echo "ok   3 partial + 3 full attempts, then fail closed" ;; *) FAIL=$((FAIL+1)); echo "FAIL clone attempts before failing closed: $(cat "$T/clone-runs" 2>/dev/null)" ;; esac
# the checkout retries too: a lazy promisor blob fetch can fail like the clone did, and recovery
# must keep the clone (only a failed clone is thrown away) and succeed on a later attempt
run "a flaky first checkout is retried and recovers" 0 "pending|success" FAKE_CHECKOUT_FAIL_TIMES=1 -- o/r 1 --post
check "the checkout retry is logged" "checkout failed .try 1/3, exit 128, [0-9]+ s left." "$T/log"
case "$(cat "$T/checkout-runs" 2>/dev/null)" in 2) PASS=$((PASS+1)); echo "ok   the checkout needed exactly one retry" ;; *) FAIL=$((FAIL+1)); echo "FAIL checkout attempts: $(cat "$T/checkout-runs" 2>/dev/null)" ;; esac
case "$(cat "$T/clone-runs" 2>/dev/null)" in 1) PASS=$((PASS+1)); echo "ok   a failed checkout keeps the clone" ;; *) FAIL=$((FAIL+1)); echo "FAIL a failed checkout re-cloned: $(cat "$T/clone-runs" 2>/dev/null)" ;; esac
# a checkout that keeps failing falls back to refetching every object, then still fails closed
run "a checkout that never succeeds fails closed with exit 128" 128 "pending|error" FAKE_CHECKOUT_FAIL_TIMES=99 -- o/r 1 --post
check "the refetch fallback is logged in the git call" "\-\-refetch" "$T/fetch-args"
# one total network budget over every attempt: with every network step hanging, the run must end
# within roughly the budget (never 3 clone x 900 s), posting error instead of stalling the gate
t0=$SECONDS
run "a hung link exhausts the budget and fails closed" 124 "pending|error" FAKE_CLONE_HANG=1 \
    AGENT_REVIEW_NET_TIMEOUT=5 AGENT_REVIEW_NET_BUDGET=6 AGENT_REVIEW_CLONE_BACKOFF=0 -- o/r 1 --post
elapsed=$((SECONDS - t0))
if [ "$elapsed" -le 12 ]; then PASS=$((PASS+1)); echo "ok   total network time bounded: ${elapsed} s with a 6 s budget (no retry multiplication)"
else FAIL=$((FAIL+1)); echo "FAIL hung link held the gate ${elapsed} s with a 6 s budget"; fi
# AGENT_REVIEW_REFERENCE=<local clone>: its object store becomes an alternate, so the checkout's
# blobs can come from local disk instead of a stalling network
REFCLONE="$T/refclone"; mkdir -p "$REFCLONE/.git/objects"
run "a reference clone is appended to the checkout's alternates" 0 "pending|success" \
    AGENT_REVIEW_REFERENCE="$REFCLONE" -- o/r 1 --post
case "$(cat "$T/alternates" 2>/dev/null)" in "$REFCLONE/.git/objects") PASS=$((PASS+1)); echo "ok   the reference's objects are an alternate" ;; *) FAIL=$((FAIL+1)); echo "FAIL alternates: $(cat "$T/alternates" 2>/dev/null)" ;; esac
# a reference path that does not exist is ignored, not fatal
run "a missing reference clone is ignored" 0 "pending|success" \
    AGENT_REVIEW_REFERENCE="$T/no-such-reference" -- o/r 1 --post
# finding 10: a repeated droid lane whose second run has no session file must say so, not inherit
# the first run's tally (counts reset per lane)
run "a repeated droid lane cannot inherit the previous tally" 1 "pending|error" AGENT_REVIEWER="droid droid" \
    AGENT_REVIEW_DROID_BIN="$T/bin/droid" FAKE_DROID_MODELS_FIRST=kimi-k3 AGENT_REVIEW_DROID_REPEAT=0 \
    FAKE_DROID_SECOND_RUN_NO_SESSION=1 -- o/r 1 --post
check "the second droid run reports no session file, not the first run's tally" "served-model mismatch: no session file" "$T/out/*.md"

# SIGTERM (outer timeout, CI cancel) during the review must not leave pending behind
rm -f "$T/statuses" "$T/heads" "$T/git-config"
printf '#!/usr/bin/env bash\nsleep 3\necho "VERDICT: APPROVE"\n' > "$T/bin/slowlane"; chmod +x "$T/bin/slowlane"
env -i HOME="$HOME" PATH="$T/bin:$PATH" T="$T" FAKE_HEAD=aaaaaaa1111111111111111111111111111111111 AGENT_REVIEW_OUT="$T/out" \
    AGENT_REVIEWER=ccz CCZ_BIN="$T/bin/slowlane" bash "$SCRIPT" o/r 1 --post > "$T/log" 2>&1 &
pid=$!; sleep 1; kill -TERM "$pid"; wait "$pid"; rc=$?
got=$(cut -d'|' -f1 "$T/statuses" 2>/dev/null | paste -sd'|' -)
if [ "$rc" = 143 ] && [ "$got" = "pending|error" ]; then PASS=$((PASS+1)); echo "ok   SIGTERM posts error"
else FAIL=$((FAIL+1)); echo "FAIL SIGTERM: rc=$rc statuses='$got' (want 143, 'pending|error')"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
