#!/usr/bin/env bash
# Hermetic tests for scripts/repo-baseline.sh: gh is a shim serving a fake org from $T/fx, so no
# GitHub call is made. Every served body is a real API response shape committed under
# tests/fixtures/ (regenerated read-only by tests/mkfixtures.sh, identifiers anonymized); only
# scenario values — repo name, security_and_analysis statuses, ruleset conditions — are
# overridden here with jq. Oracle: the per-check statuses the audit prints, its exit code, and
# the exact list of mutating gh calls (apply-settings); audit and plan-rulesets must make none.
# usage: bash tests/repo-baseline.test.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/repo-baseline.sh"
FIX="$ROOT/tests/fixtures"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fx"
FENCE=$(jq -r .id "$FIX/ruleset.agent-fence.json")
TAGS=$(jq -r .id "$FIX/ruleset.agent-fence-tags.json")
S6BODY='{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'

cat > "$T/bin/gh" <<'SHIM'
#!/usr/bin/env bash
args="$*"
# any mutating call is recorded, never executed: the oracle for apply-settings. A JSON body
# sent with --input - is recorded after the args, so the exact PATCH body is asserted too.
case "$args" in
  "api -X "*"--input -") echo "$args <<$(cat)" >> "$T/calls"; exit 0 ;;
  "api -X "*)           echo "$args" >> "$T/calls"; exit 0 ;;
esac
u=${args#api }; u=${u%% *}        # "api <path> [flags]" -> <path>
u=${u%%\?*}                       # drop the query string
serve(){ # serve <file>: a JSON body, or a file holding just an HTTP code (2xx = success, no body)
  [ -f "$1" ] || { echo "gh shim: no fixture for $u" >&2; echo "HTTP 404" >&2; exit 1; }
  if grep -qE '^[0-9]+$' "$1"; then code=$(cat "$1")
    case $code in 2*) exit 0 ;; *) echo "HTTP $code" >&2; exit 1 ;; esac; fi
  cat "$1"; }
repo_of(){ local p=$1; p=${p#repos/*/}; printf '%s' "${p%%/*}"; }
case "$u" in
  "orgs/"*"/repos") echo "[$(cat "$T/fx/org-repos")]" ;;   # --paginate --slurp wraps pages
  "repos/"*"/languages") serve "$T/fx/$(repo_of "$u")/languages" ;;
  "repos/"*"/contents/"*)
    R=$(repo_of "$u"); p=${u#*/contents/}; f="$T/fx/$R/files/$p"
    if [ -f "$f" ]; then printf '{"content":'; jq -Rs @base64 <"$f"; printf '}\n'
    elif [ -d "$f" ]; then ls -1 "$f" | jq -R -s 'split("\n") | map(select(length > 0) | {name: .})'
    else echo "HTTP 404" >&2; exit 1; fi ;;
  "repos/"*"/vulnerability-alerts")     serve "$T/fx/$(repo_of "$u")/ep.vulnerability-alerts" ;;
  "repos/"*"/automated-security-fixes") serve "$T/fx/$(repo_of "$u")/ep.automated-security-fixes" ;;
  "repos/"*"/rules/branches/"*)         serve "$T/fx/$(repo_of "$u")/ep.rules-branches" ;;
  "repos/"*"/rulesets/"*)               serve "$T/fx/$(repo_of "$u")/ep.ruleset-${u##*/}" ;;
  "repos/"*"/rulesets")                 serve "$T/fx/$(repo_of "$u")/ep.rulesets" ;;
  "repos/"*"/branches/"*"/protection")  serve "$T/fx/$(repo_of "$u")/ep.protection" ;;
  # not a GitHub endpoint: secret scanning settings live in the repo GET's
  # .security_and_analysis — a call here means the script regressed to the dead endpoints
  "repos/"*"/secret-scanning"*) echo "gh shim: $u is not a GitHub endpoint (use .security_and_analysis)" >&2; exit 99 ;;
  "repos/"*)                            serve "$T/fx/$(repo_of "$u")/repo" ;;
  *) echo "gh shim: unexpected: $args" >&2; exit 99 ;;
esac
SHIM
chmod +x "$T/bin/gh"

# a fully compliant fake repo: every audit check ok except R5 (report only, none by default)
mkrepo(){
  local d=$T/fx/$1; mkdir -p "$d/files/.github/workflows" "$d/files/.devcontainer"
  { for s in Purpose Orient Setup Check Boundaries Done; do echo "## $s"; echo "text for $s"; done; } > "$d/files/AGENTS.md"
  echo "@AGENTS.md" > "$d/files/CLAUDE.md"
  printf 'setup:\n\t@echo setup\ncheck:\n\t@echo check\n' > "$d/files/Makefile"
  printf 'name: x\non:\n  - pull_request\njobs: {build: {runs-on: ubuntu-latest}}\n' > "$d/files/.github/workflows/ci.yml"
  echo "version: 2" > "$d/files/.github/dependabot.yml"
  echo '{"image": "mcr.microsoft.com/devcontainers/base"}' > "$d/files/.devcontainer/devcontainer.json"
  jq --arg n "$1" '.name=$n | .full_name=("agent-next/"+$n) | .topics=["t"] | .delete_branch_on_merge=true' \
    "$FIX/repo.get.json" > "$d/repo"
  cp "$FIX/languages.json" "$d/languages"
  echo 204 > "$d/ep.vulnerability-alerts"; echo 204 > "$d/ep.automated-security-fixes"
  cp "$FIX/rules.branches.json" "$d/ep.rules-branches"
  cp "$FIX/rulesets.list.json" "$d/ep.rulesets"
  cp "$FIX/ruleset.agent-fence.json" "$d/ep.ruleset-$FENCE"
  cp "$FIX/ruleset.agent-fence-tags.json" "$d/ep.ruleset-$TAGS"
  echo 404 > "$d/ep.protection"
}
mkrepo good
# org listing in the real per-repo item shape: "old" is archived and must be skipped
jq -s '[ .[0] | .name="good" | .full_name="agent-next/good" | .archived=false,
         .[0] | .name="old"  | .full_name="agent-next/old"  | .archived=true ]' \
  "$FIX/repo.get.json" > "$T/fx/org-repos"

PASS=0; FAIL=0
run_cli(){ # run_cli <expected rc> <args...>: output to $T/log, rc compared
  local want_rc=$1; shift
  rm -f "$T/calls"
  env -i HOME="$HOME" PATH="$T/bin:$PATH" T="$T" bash "$SCRIPT" "$@" > "$T/log" 2>&1
  local rc=$?
  if [ "$rc" = "$want_rc" ]; then PASS=$((PASS+1)); echo "ok   $*"
  else FAIL=$((FAIL+1)); echo "FAIL $*: rc=$rc (want $want_rc)"; sed 's/^/     /' "$T/log"; fi
}
# neg <name> <check> <mutation>: flips exactly one check to MISSING and nothing else
neg(){
  local name=$1 chk=$2 mut=$3
  rm -rf "$T/fx/neg"; cp -r "$T/fx/good" "$T/fx/neg"; ( cd "$T/fx/neg" && eval "$mut" ) || { FAIL=$((FAIL+1)); echo "FAIL $name: mutation failed"; return; }
  run_cli 1 audit --repo neg
  local n; n=$(grep -o ':MISSING' "$T/log" | wc -l)   # ":MISSING" only appears in the per-repo row
  if grep -q " $chk:MISSING" "$T/log" && [ "$n" -eq 1 ] && ! grep -q unknown "$T/log"; then PASS=$((PASS+1)); echo "ok   $name flips only $chk to MISSING"
  else FAIL=$((FAIL+1)); echo "FAIL $name: MISSING count=$n (want 1, at $chk)"; grep -E 'MISSING|unknown' "$T/log" | sed 's/^/     /'; fi
}

run_cli 0 audit --repo good
if [ "$(grep -oE ' (F[1-6]|S[1-6]|R[1-4]):ok' "$T/log" | wc -l)" -eq 16 ] && grep -q " R5:none" "$T/log"; then
  PASS=$((PASS+1)); echo "ok   compliant repo: F1-F6 S1-S6 R1-R4 ok, R5 report-only none"
else FAIL=$((FAIL+1)); echo "FAIL compliant repo row: $(grep '^agent-next/good' "$T/log")"; fi
if [ ! -e "$T/calls" ]; then PASS=$((PASS+1)); echo "ok   audit makes zero mutating calls"; else FAIL=$((FAIL+1)); echo "FAIL audit mutated: $(cat "$T/calls")"; fi

neg "F1 AGENTS.md over 90 lines"        F1 'for i in $(seq 95); do echo "filler $i"; done > files/AGENTS.md'
neg "F1 AGENTS.md missing a section"    F1 'grep -v "^## Done" files/AGENTS.md > a && mv a files/AGENTS.md'
neg "F2 CLAUDE.md wrong content"        F2 'echo "see AGENTS.md" > files/CLAUDE.md'
neg "F3 Makefile without check target"  F3 'printf "setup:\n\t@echo s\n" > files/Makefile'
neg "F4 no pull_request workflow"       F4 'printf "name: x\non: [push]\n" > files/.github/workflows/ci.yml'
neg "F5 no dependabot config"           F5 'rm files/.github/dependabot.yml'
neg "F6 code repo without devcontainer" F6 'rm files/.devcontainer/devcontainer.json'
neg "S1 empty description"              S1 'jq ".description=\"\"" repo > r && mv r repo'
neg "S2 no topics"                      S2 'jq ".topics=[]" repo > r && mv r repo'
neg "S3 delete_branch_on_merge off"     S3 'jq ".delete_branch_on_merge=false" repo > r && mv r repo'
neg "S4 wiki on"                        S4 'jq ".has_wiki=true" repo > r && mv r repo'
neg "S5 Dependabot alerts off"          S5 'echo 404 > ep.vulnerability-alerts'
neg "S6 secret scanning off (public)"   S6 'jq ".security_and_analysis.secret_scanning.status=\"disabled\"" repo > r && mv r repo'
neg "R1 default-branch rules incomplete" R1 'jq "map(select(.type != \"deletion\"))" ep.rules-branches > r && mv r ep.rules-branches'
neg "R2 no agent-review required check" R2 'jq "map(if .type == \"required_status_checks\" then .parameters.required_status_checks=[{context: \"ci\"}] else . end)" ep.rules-branches > r && mv r ep.rules-branches'
neg "R3 no agent-fence ruleset"         R3 "jq \"map(select(.name != \\\"agent-fence\\\"))\" ep.rulesets > r && mv r ep.rulesets"
neg "R4 no agent-fence-tags ruleset"    R4 "jq \"map(select(.name != \\\"agent-fence-tags\\\"))\" ep.rulesets > r && mv r ep.rulesets"

# R3: the org fence model is include ~ALL minus sbx/** — a ruleset that instead *includes*
# sbx/** only (the old, backwards model) must be reported MISSING, not accepted
neg "R3 fence only fences sbx/** (backwards)" R3 "jq '.conditions.ref_name={include:[\"refs/heads/sbx/**\"],exclude:[]}' ep.ruleset-$FENCE > r && mv r ep.ruleset-$FENCE"
neg "R3 fence excludes only one sbx pattern"  R3 "jq '.conditions.ref_name.exclude=[\"refs/heads/sbx/**\"]' ep.ruleset-$FENCE > r && mv r ep.ruleset-$FENCE"
neg "R3 fence includes refs/heads/* only"     R3 "jq '.conditions.ref_name.include=[\"refs/heads/*\"]' ep.ruleset-$FENCE > r && mv r ep.ruleset-$FENCE"
neg "R4 tag fence includes refs/tags/* only"  R4 "jq '.conditions.ref_name={include:[\"refs/tags/*\"],exclude:[]}' ep.ruleset-$TAGS > r && mv r ep.ruleset-$TAGS"

rm -rf "$T/fx/neg"; cp -r "$T/fx/good" "$T/fx/neg"
( cd "$T/fx/neg" && jq '.bypass_actors=null' "ep.ruleset-$FENCE" > r && mv r "ep.ruleset-$FENCE" )
run_cli 1 audit --repo neg
if grep -q " R3:MISSING" "$T/log" && grep -q "bypass_actors=0" "$T/log"; then PASS=$((PASS+1)); echo "ok   R3 flags a fence no bot can bypass"
else FAIL=$((FAIL+1)); echo "FAIL R3 no-bypass case: $(grep '^agent-next/neg' "$T/log")"; fi

# a token without admin read gets no security_and_analysis at all: S6 must fail closed as
# unknown (never ok), the audit must fail, and the dead secret-scanning endpoints stay uncalled
rm -rf "$T/fx/neg"; cp -r "$T/fx/good" "$T/fx/neg"
( cd "$T/fx/neg" && jq 'del(.security_and_analysis)' repo > r && mv r repo )
run_cli 1 audit --repo neg
if grep -q " S6:unknown" "$T/log" && grep -q "admin" "$T/log" && ! grep -q "secret-scanning" "$T/log"; then PASS=$((PASS+1)); echo "ok   S6 without admin read: unknown, fails closed, no dead endpoints"
else FAIL=$((FAIL+1)); echo "FAIL S6 no-admin-read case:"; grep -E 'S6|secret' "$T/log" | sed 's/^/     /'; fi

# R5 is report only: classic protection present flips R5 to ok but never gates the audit
rm -rf "$T/fx/neg"; cp -r "$T/fx/good" "$T/fx/neg"
echo '{"required_status_checks": {"contexts": ["ci"]}, "enabled": true}' > "$T/fx/neg/ep.protection"
run_cli 0 audit --repo neg
if grep -q " R5:ok" "$T/log"; then PASS=$((PASS+1)); echo "ok   R5 reports classic protection without gating"
else FAIL=$((FAIL+1)); echo "FAIL R5 report-only: $(grep '^agent-next/neg' "$T/log")"; fi

# a token without admin read: every gated endpoint reports unknown (403), never ok, and fails closed
rm -rf "$T/fx/neg"; cp -r "$T/fx/good" "$T/fx/neg"
( cd "$T/fx/neg" && for f in ep.rules-branches ep.rulesets ep.protection; do echo 403 > "$f"; done )
run_cli 1 audit --repo neg
if [ "$(grep -c 'unknown' "$T/log")" -ge 4 ] && ! grep -qE ' (R[1-4]):ok' "$T/log"; then PASS=$((PASS+1)); echo "ok   admin-blind token: R1-R4 unknown (403), never ok, audit fails closed"
else FAIL=$((FAIL+1)); echo "FAIL 403 case:"; grep -E 'unknown|R[1-5]' "$T/log" | sed 's/^/     /'; fi

rm -rf "$T/fx/priv"; cp -r "$T/fx/good" "$T/fx/priv"; jq '.private=true' "$T/fx/priv/repo" > "$T/fx/priv/r" && mv "$T/fx/priv/r" "$T/fx/priv/repo"
run_cli 0 audit --repo priv
if grep -q " S6:n/a" "$T/log" && grep -q "paid add-on" "$T/log"; then PASS=$((PASS+1)); echo "ok   private repo: S6 n/a (owner money gate)"
else FAIL=$((FAIL+1)); echo "FAIL private S6: $(grep '^agent-next/priv' "$T/log")"; fi

rm -rf "$T/fx/docs"; cp -r "$T/fx/good" "$T/fx/docs"; rm "$T/fx/docs/files/.devcontainer/devcontainer.json"
echo '{"Markdown": 100}' > "$T/fx/docs/languages"
run_cli 0 audit --repo docs
if grep -q " F6:n/a" "$T/log"; then PASS=$((PASS+1)); echo "ok   docs-only repo: F6 n/a"
else FAIL=$((FAIL+1)); echo "FAIL docs-only F6: $(grep '^agent-next/docs' "$T/log")"; fi

run_cli 0 audit --repo good --json
if jq -e '.[0].checks | .F1.status=="ok" and .S6.status=="ok" and .R5.status=="none"' "$T/log" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   --json carries per-check status"
else FAIL=$((FAIL+1)); echo "FAIL --json: $(head -3 "$T/log")"; fi

# org-wide audit skips archived repos (fixture "old" would explode if audited)
run_cli 0 audit
if grep -q '^agent-next/good ' "$T/log" && ! grep -q "old" "$T/log"; then PASS=$((PASS+1)); echo "ok   org-wide audit covers active repos only"
else FAIL=$((FAIL+1)); echo "FAIL org-wide audit: $(grep '^agent-next/' "$T/log")"; fi

# apply-settings: dry run prints the calls and mutates nothing
rm -rf "$T/fx/fixme"; cp -r "$T/fx/good" "$T/fx/fixme"
( cd "$T/fx/fixme" && jq '.delete_branch_on_merge=false | .has_wiki=true | .security_and_analysis.secret_scanning.status="disabled"' repo > r && mv r repo &&
  echo 404 > ep.vulnerability-alerts )
run_cli 0 apply-settings --repo fixme
if [ ! -e "$T/calls" ] && grep -q "^would  PATCH repos/agent-next/fixme -F delete_branch_on_merge=true" "$T/log" \
   && grep -q "^would  PUT repos/agent-next/fixme/vulnerability-alerts" "$T/log" \
   && grep -qF "would  PATCH repos/agent-next/fixme $S6BODY" "$T/log"; then PASS=$((PASS+1)); echo "ok   apply-settings dry run: zero mutating calls, calls printed"
else FAIL=$((FAIL+1)); echo "FAIL dry run:"; sed 's/^/     /' "$T/log"; [ -e "$T/calls" ] && cat "$T/calls"; fi

run_cli 0 apply-settings --repo fixme --apply
if [ -s "$T/calls" ] && [ "$(grep -c 'api -X' "$T/calls")" -ge 5 ] && grep -qF "api -X PATCH repos/agent-next/fixme --input - <<$S6BODY" "$T/calls" \
   && ! grep -q "rulesets" "$T/calls" && ! grep -qE "branches/[^ ]+/protection" "$T/calls" && ! grep -q " -X POST" "$T/calls"; then
  PASS=$((PASS+1)); echo "ok   apply-settings --apply: only S3-S6 settings, S6 one repo PATCH with the security_and_analysis body"
else FAIL=$((FAIL+1)); echo "FAIL apply calls:"; sed 's/^/     /' "$T/calls" 2>/dev/null; fi

run_cli 0 apply-settings --repo good --apply
if [ ! -s "$T/calls" ] && grep -q "^skip" "$T/log"; then PASS=$((PASS+1)); echo "ok   compliant repo: --apply still sends nothing"
else FAIL=$((FAIL+1)); echo "FAIL compliant apply:"; sed 's/^/     /' "$T/log"; [ -e "$T/calls" ] && cat "$T/calls"; fi

run_cli 0 plan-rulesets --repo good
if grep -q '"~ALL"' "$T/log" && grep -q '"refs/heads/sbx/\*\*"' "$T/log" && grep -q '"refs/heads/sbx/\*\*/\*"' "$T/log" \
   && grep -q '"agent-review"' "$T/log" && ! grep -q "__DEFAULT_BRANCH__" "$T/log"; then PASS=$((PASS+1)); echo "ok   plan-rulesets prints filled templates for R1-R4"
else FAIL=$((FAIL+1)); echo "FAIL plan-rulesets:"; sed 's/^/     /' "$T/log"; fi
if [ ! -e "$T/calls" ]; then PASS=$((PASS+1)); echo "ok   plan-rulesets mutates nothing"
else FAIL=$((FAIL+1)); echo "FAIL plan-rulesets mutated: $(cat "$T/calls")"; fi
if grep -q '"actor_id": 0' "$T/log"; then PASS=$((PASS+1)); echo "ok   bypass actors stay a placeholder the operator fills"
else FAIL=$((FAIL+1)); echo "FAIL plan-rulesets placeholder actor"; fi

run_cli 64 plan-rulesets
run_cli 64 audit --repo good --bogus

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
