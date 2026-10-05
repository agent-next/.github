#!/usr/bin/env bash
# Hermetic tests for scripts/check-docs.py: each case builds a throwaway tree.
# Oracle: the script's exit code (and the reported problem text where stated).
# usage: bash tests/check-docs.test.sh   (CHECK_DOCS=<path> to test another copy of the script)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=${CHECK_DOCS:-$ROOT/scripts/check-docs.py}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
# case <name> <expected rc> <expected stderr substring or ""> ; the tree is built by the caller in $T/t
check(){
  local name=$1 want_rc=$2 want_msg=$3
  mkdir -p "$T/t/scripts"; cp "$SCRIPT" "$T/t/scripts/check-docs.py"
  python3 "$T/t/scripts/check-docs.py" > "$T/out" 2> "$T/err"; local rc=$?
  if [ "$rc" = "$want_rc" ] && { [ -z "$want_msg" ] || grep -qF -- "$want_msg" "$T/err"; }; then
    PASS=$((PASS+1)); echo "ok   $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL $name (rc=$rc want=$want_rc msg=$want_msg)"; cat "$T/err"
  fi
  rm -rf "$T/t"
}
tree(){ rm -rf "$T/t"; mkdir -p "$T/t"; printf '# Standard — v0.1.0\n' > "$T/t/AGENT-STANDARD.md"; printf '# A\n' > "$T/t/AGENTS.md"; printf '# B\n' > "$T/t/B.md"; }

tree; printf '[b](./B.md#x) [w](https://x.io/a) [a](#top)\n' > "$T/t/DOC.md"
check "good tree passes" 0 ""

tree; printf 'see [b](./nope.md)\n' > "$T/t/DOC.md"
check "broken inline link fails" 1 "broken link ./nope.md"

tree; printf '````\n```\n````\n[hidden](./nope.md)\n' > "$T/t/DOC.md"
check "4-backtick fence with inner 3-backtick line, broken link after fence" 1 "DOC.md:4: broken link"

tree; printf '~~~\n[inside](./nope.md)\n~~~\n' > "$T/t/DOC.md"
check "link inside ~~~ fence is ignored" 0 ""

tree; printf '~~~\n```\n[inside](./nope.md)\n```\n~~~\n' > "$T/t/DOC.md"
check "backtick line does not close a ~~~ fence" 0 ""

tree; printf 'a [x][id]\n\n[id]: ./nope.md\n' > "$T/t/DOC.md"
check "reference-style link to missing file fails" 1 "broken link ./nope.md"

tree; printf 'a [x][id]\n\n[id]: ./B.md\n' > "$T/t/DOC.md"
check "reference-style link to existing file passes" 0 ""

tree; printf '[p](/etc/passwd)\n' > "$T/t/DOC.md"
check "absolute path link is a problem" 1 "absolute link /etc/passwd"

tree; python3 -c "print('\n'.join(['x']*91), end='')" > "$T/t/AGENTS.md"
check "91-line AGENTS.md without trailing newline fails" 1 "exceeds 90 lines"

tree; python3 -c "print('\n'.join(['x']*90))" > "$T/t/AGENTS.md"
check "90-line AGENTS.md passes" 0 ""

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
