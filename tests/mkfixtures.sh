#!/usr/bin/env bash
# tests/mkfixtures.sh — regenerate tests/fixtures/*.json (the real GitHub API response shapes
# the hermetic suite is served from) with one read-only pass over the live org. Run it when an
# API shape changes, review the diff, commit. `make check` never runs it: the suite is hermetic.
#
# Real: every body written is a live response — the repo GET of the public repo clarity, a live
# ruleset detail, live effective branch rules, a live rulesets-list item, a live languages map —
# with identifiers anonymized (numeric ids -> 101, node_ids -> "ANON", avatar user ids -> 0).
# Not fetched, because the sandbox App token cannot read them (documented, not hidden):
#   - the live agent-fence rulesets sit on a repo this token cannot see (404); their conditions
#     below are the ones the lead's execution check quoted from the live bodies (include ~ALL,
#     exclude carves sbx/** out so sandbox pushes never hit the fence), carried on the fetched
#     live body skeleton (rules, parameters, metadata keys all as returned);
#   - security_and_analysis is only served to repo admins; the repo GET carries the admin view
#     the execution check read on clarity (secret scanning and push protection enabled).
# Fail-closed: any unreadable endpoint or any real identifier surviving anonymization aborts
# before a single fixture is replaced.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FX=$ROOT/tests/fixtures
ORG=${AGENT_BASELINE_ORG:-agent-next}
REPO_SRC=${AGENT_BASELINE_REPO_SRC:-clarity}             # repo GET shape (public repo)
RS_SRC=${AGENT_BASELINE_RS_SRC:-agent-ready/12092244}    # ruleset detail shape (body skeleton)
RB_SRC=${AGENT_BASELINE_RB_SRC:-agent-ready/main}        # effective branch rules shape
LANG_SRC=${AGENT_BASELINE_LANG_SRC:-agent-ready}         # languages shape
LIST_SRC=${AGENT_BASELINE_LIST_SRC:-agent-ready}         # rulesets-list item shape
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
OUT=$TMP/out; mkdir -p "$OUT"

gh api "repos/$ORG/$REPO_SRC"                             > "$TMP/raw.repo.json"
gh api "repos/$ORG/${RS_SRC%/*}/rulesets/${RS_SRC##*/}"  > "$TMP/raw.ruleset.json"
gh api "repos/$ORG/${RB_SRC%/*}/rules/branches/${RB_SRC##*/}" > "$TMP/raw.rules.json"
gh api "repos/$ORG/$LIST_SRC/rulesets"                    > "$TMP/raw.list.json"
gh api "repos/$ORG/$LANG_SRC/languages"                   > "$OUT/languages.json"

# the anonymizing filter, prepended to every jq program below ($ANON'<program>')
ANON='def anon: walk(if type == "object" then with_entries(
        if .key == "node_id" then .value = "ANON"
        elif (.key == "id" or .key == "actor_id" or .key == "ruleset_id") and (.value | type == "number")
        then .value = 101
        else . end)
      elif type == "string"
      then gsub("(?<pre>avatars[.]githubusercontent[.]com/u/)[0-9]+"; "\(.pre)0")
         | gsub("(?<pre>/rules(ets)?/)[0-9]+"; "\(.pre)101")
      else . end);'

# repo GET: real clarity body + the admin-only security_and_analysis (see header)
jq "$ANON"' anon
  | .security_and_analysis = {advanced_security:            {status: "enabled"},
                              secret_scanning:              {status: "enabled"},
                              secret_scanning_push_protection: {status: "enabled"}}' \
  "$TMP/raw.repo.json" > "$OUT/repo.get.json"

# agent-fence on the live body skeleton (see header): fence everything, carve out agent refs
jq "$ANON"' anon
  | .id = 101 | .name = "agent-fence" | .target = "branch"
  | .conditions.ref_name = {include: ["~ALL"],
      exclude: ["refs/heads/sbx/**", "refs/heads/sbx/**/*",
                "refs/heads/dependabot/**", "refs/heads/bot/**", "~DEFAULT_BRANCH"]}
  | .bypass_actors = [{actor_id: 7, actor_type: "Integration", bypass_mode: "always"}]' \
  "$TMP/raw.ruleset.json" > "$OUT/ruleset.agent-fence.json"

jq "$ANON"' anon
  | .id = 102 | .name = "agent-fence-tags" | .target = "tag"
  | .conditions.ref_name = {include: ["~ALL"], exclude: []}
  | .rules += [{type: "update"}]
  | .bypass_actors = [{actor_id: 7, actor_type: "Integration", bypass_mode: "always"}]' \
  "$TMP/raw.ruleset.json" > "$OUT/ruleset.agent-fence-tags.json"

# effective rules: as fetched, plus a required_status_checks rule whose parameter shape mirrors
# the live agent-merge-gate ruleset's (contexts are scenario values for R2)
jq "$ANON"' anon
  | . += [{type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false, do_not_enforce_on_create: false,
        required_status_checks: [{context: "agent-review"}, {context: "ci"}]}}]' \
  "$TMP/raw.rules.json" > "$OUT/rules.branches.json"

# rulesets list: two entries in the real list-item shape (id/name/target overridden)
jq "$ANON"' anon | .[0] | .id = 101 | .name = "agent-fence"'      "$TMP/raw.list.json" > "$TMP/l1"
jq "$ANON"' anon | .[0] | .id = 102 | .name = "agent-fence-tags" | .target = "tag"' "$TMP/raw.list.json" > "$TMP/l2"
jq -s '.' "$TMP/l1" "$TMP/l2" > "$OUT/rulesets.list.json"

# fail closed if any real identifier survived
while IFS= read -r v; do
  if grep -RF -e "$v" "$OUT"; then echo "mkfixtures: a real identifier survived: $v" >&2; exit 1; fi
done < <(jq -r '.. | objects | to_entries[]
             | select(.key == "id" or .key == "actor_id" or .key == "ruleset_id" or .key == "node_id")
             | .value | tostring' "$TMP"/raw.*.json | sort -u)

mkdir -p "$FX"
for f in repo.get.json ruleset.agent-fence.json ruleset.agent-fence-tags.json \
         rules.branches.json rulesets.list.json languages.json; do
  mv "$OUT/$f" "$FX/$f"
done
echo "mkfixtures: wrote tests/fixtures/{$(ls "$FX" | tr '\n' ' ')} from live shapes, ids anonymized"
