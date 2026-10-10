#!/usr/bin/env bash
# repo-baseline: audit each org repo against the "Repo baseline" section of AGENT-STANDARD.md
# (files on the default branch, GitHub settings, rulesets), print one row per repo with a
# per-check status (ok / MISSING / n/a / unknown), and exit 1 when a required item is missing
# or cannot be verified. Also: apply-settings (fixes only S3-S6; dry run unless --apply) and
# plan-rulesets (prints the ruleset JSON for R1-R4; never applies anything).
# usage: repo-baseline.sh audit [--org agent-next] [--repo NAME]... [--json]
#        repo-baseline.sh apply-settings --repo NAME [--apply]   (without --apply: prints calls only)
#        repo-baseline.sh plan-rulesets --repo NAME
# tests: bash tests/repo-baseline.test.sh (hermetic; gh is a shim)
# Trust: rulesets, classic branch protection, visibility and paid add-ons are owner-gated; this
# tool never writes them. An endpoint the token may not read (403) is reported "unknown", never
# ok, and an unknown required check fails the audit — the audit never passes on missing evidence.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 1 ] || { sed -n '3,5p' "$0" >&2; exit 64; }
CMD=$1; shift
ORG=agent-next; REPOS=(); JSON=no; APPLY=no
while [ $# -ge 1 ]; do case $1 in
  --org) ORG=$2; shift 2 ;;
  --repo) REPOS+=("$2"); shift 2 ;;
  --json) JSON=yes; shift ;;
  --apply) APPLY=yes; shift ;;
  *) echo "unknown flag: $1" >&2; exit 64 ;;
esac; done
case $CMD in audit|apply-settings|plan-rulesets) ;; *) echo "unknown command: $CMD" >&2; exit 64 ;; esac
if [ ${#REPOS[@]} -eq 0 ] && [ "$CMD" != audit ]; then echo "$CMD needs --repo NAME" >&2; exit 64; fi

NET_TIMEOUT=${AGENT_BASELINE_NET_TIMEOUT:-120}   # a stalled link must not hang an audit
GH=$(command -v gh); ghc(){ timeout -k 30 "$NET_TIMEOUT" "$GH" "$@"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ERR=
api(){ # api <path>: GET, body on stdout; on failure sets ERR (404|403|network) and returns 1
  ERR=; local out
  out=$(ghc api "$1" 2>"$TMP/err") || { ERR=$(grep -oE 'HTTP [0-9]+' "$TMP/err" | tail -1 | cut -d' ' -f2 || true); ERR=${ERR:-network}; return 1; }
  printf '%s\n' "$out"
}
api_flag(){ # api_flag <path>: an endpoint whose whole meaning is its status (204 on, 404 off)
  api "$1" >/dev/null || { if [ "$ERR" = 404 ]; then echo disabled; else echo "unknown ($ERR)"; fi; return 0; }
  echo enabled
}
api_opt(){ # api_opt <path>: an endpoint whose body carries {"status": "enabled"|"disabled"}
  if ! api "$1" > "$TMP/body"; then
    if [ "$ERR" = 404 ]; then echo disabled; else echo "unknown ($ERR)"; fi; return 0
  fi
  if [ "$(jq -r '.status // "unknown"' < "$TMP/body")" = enabled ]; then echo enabled; else echo disabled; fi
}
file_body(){ # file_body <path>: file content at the tip of the default branch, or absent | unknown (…)
  if ! api "repos/$ORG/$R/contents/$1?ref=$BRANCH" > "$TMP/body"; then
    if [ "$ERR" = 404 ]; then echo absent; else echo "unknown ($ERR)"; fi; return 0
  fi
  jq -r '.content // ""' < "$TMP/body" | base64 -d
}
dir_names(){ # dir_names <path>: entries of a directory on the default branch, or absent | unknown (…)
  if ! api "repos/$ORG/$R/contents/$1?ref=$BRANCH" > "$TMP/body"; then
    if [ "$ERR" = 404 ]; then echo absent; else echo "unknown ($ERR)"; fi; return 0
  fi
  jq -r 'if type=="array" then .[].name else empty end' < "$TMP/body"
}

RESULTS=; FAIL=no
res(){ # res <id> <status> <reason>: record one check; MISSING/unknown fail the audit unless report-only (R5)
  RESULTS+="$R|$1|$2|$3"$'\n'
  case $2 in MISSING|unknown) [ "$1" = R5 ] || FAIL=yes ;; esac
}

# ---- file checks (F1-F6) ----------------------------------------------------------------
file_checks(){
  local b d secs s gap w wb hit lines
  b=$(file_body AGENTS.md)
  case $b in
    absent)   res F1 MISSING "no AGENTS.md on $BRANCH" ;;
    unknown*) res F1 unknown "AGENTS.md read: $b" ;;
    *) secs=""; for s in Purpose Orient Setup Check Boundaries Done; do
         grep -qiE "^#{1,6}[[:space:]]*$s([[:space:]]|\$)" <<<"$b" || secs="$secs $s"; done
       lines=$(wc -l <<<"$b")
       if [ "$lines" -gt 90 ]; then res F1 MISSING "AGENTS.md is $lines lines (max 90)"
       elif [ -n "$secs" ]; then res F1 MISSING "AGENTS.md lacks sections:$secs"
       else res F1 ok ""; fi ;;
  esac
  b=$(file_body CLAUDE.md)
  case $b in
    "@AGENTS.md") res F2 ok "" ;;
    absent)       res F2 MISSING "no CLAUDE.md" ;;
    unknown*)     res F2 unknown "CLAUDE.md read: $b" ;;
    *)            res F2 MISSING "CLAUDE.md is not exactly \@AGENTS.md" ;;
  esac
  b=$(file_body Makefile)
  case $b in
    absent)   res F3 MISSING "no Makefile" ;;
    unknown*) res F3 unknown "Makefile read: $b" ;;
    *) if grep -qE '^setup:' <<<"$b" && grep -qE '^check:' <<<"$b"; then res F3 ok ""
       else res F3 MISSING "Makefile lacks a setup and/or check target"; fi ;;
  esac
  d=$(dir_names ".github/workflows"); hit=
  case $d in
    absent)   res F4 MISSING "no .github/workflows directory" ;;
    unknown*) res F4 unknown "workflow listing: $d" ;;
    "")       res F4 MISSING ".github/workflows is empty" ;;
    *) for w in $d; do wb=$(file_body ".github/workflows/$w"); { grep -q pull_request <<<"$wb" && hit=$w; } || true; done
       if [ -n "$hit" ]; then res F4 ok ""; else res F4 MISSING "no workflow runs on pull_request"; fi ;;
  esac
  b=$(file_body ".github/dependabot.yml")
  case $b in
    absent)   res F5 MISSING "no .github/dependabot.yml" ;;
    unknown*) res F5 unknown "dependabot.yml read: $b" ;;
    *)        res F5 ok "" ;;
  esac
  # F6: a devcontainer is only owed by repos that have code files; docs-only repos skip it
  if [ "$(jq -r 'to_entries | map(select(.key != "Markdown" and .key != "Text")) | length' <<<"$LANGS")" -eq 0 ]; then
    res F6 n/a "no code files (docs-only repo)"
  else
    b=$(file_body ".devcontainer/devcontainer.json")
    case $b in
      absent)   res F6 MISSING "code repo without .devcontainer/devcontainer.json" ;;
      unknown*) res F6 unknown "devcontainer.json read: $b" ;;
      *)        res F6 ok "" ;;
    esac
  fi
}

# ---- settings checks (S1-S6), shared by audit and apply-settings ------------------------
probe_settings(){ # prints one "S<n>|ok|reason", "|fix|reason", "|n/a|reason" or "|unknown|reason" line per setting
  local a f ss pp
  if [ "$(jq -r .delete_branch_on_merge <<<"$META")" = true ]; then echo "S3|ok|"; else echo "S3|fix|delete_branch_on_merge is not true"; fi
  if [ "$(jq -r .has_wiki <<<"$META")" = false ]; then echo "S4|ok|"; else echo "S4|fix|wiki is on"; fi
  a=$(api_flag "repos/$ORG/$R/vulnerability-alerts"); f=$(api_flag "repos/$ORG/$R/automated-security-fixes")
  case "$a $f" in
    "enabled enabled") echo "S5|ok|" ;;
    *unknown*)         echo "S5|unknown|alerts=$a, security updates=$f" ;;
    *)                 echo "S5|fix|alerts=$a, security updates=$f" ;;
  esac
  if [ "$(jq -r .private <<<"$META")" = true ]; then
    echo "S6|n/a|private repo: secret scanning is a paid add-on and an owner money gate"
  else
    ss=$(api_opt "repos/$ORG/$R/secret-scanning"); pp=$(api_opt "repos/$ORG/$R/secret-scanning/push-protection")
    case "$ss $pp" in
      "enabled enabled") echo "S6|ok|" ;;
      *unknown*)         echo "S6|unknown|secret scanning=$ss, push protection=$pp" ;;
      *)                 echo "S6|fix|secret scanning=$ss, push protection=$pp" ;;
    esac
  fi
}

# ---- ruleset checks (R1-R5) --------------------------------------------------------------
ruleset_checks(){
  local rb rberr ctx pb ctx2 others gap t id r target inc det
  if api "repos/$ORG/$R/rules/branches/$BRANCH" > "$TMP/rules"; then rb=$(cat "$TMP/rules"); rberr=; else rb=; rberr=$ERR; fi
  if [ "$rberr" = 403 ] || [ "$rberr" = network ]; then
    res R1 unknown "effective rules read: $rberr"
  else
    rb=${rb:-[]}; gap=""
    for t in deletion non_fast_forward pull_request; do
      jq -e --arg t "$t" 'map(.type) | index($t) != null' <<<"$rb" >/dev/null || gap="$gap $t"
    done
    if [ -n "$gap" ]; then res R1 MISSING "default-branch ruleset lacks:$gap"; else res R1 ok ""; fi
  fi
  ctx=$(jq -r '[.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | join(",")' <<<"${rb:-[]}")
  if api "repos/$ORG/$R/branches/$BRANCH/protection" > "$TMP/prot"; then
    ctx2=$(jq -r '(.required_status_checks.contexts // []) | join(",")' < "$TMP/prot"); pb=1
  else
    ctx2=; pb=
  fi
  # R2: agent-review plus at least one CI context, from the ruleset or classic protection
  others=$(printf '%s\n%s\n' "$ctx" "$ctx2" | tr ',' '\n' | grep -v '^[[:space:]]*$' | grep -vw agent-review | head -1 || true)
  if grep -qw agent-review <<<"$ctx $ctx2" && [ -n "$others" ]; then res R2 ok ""
  elif [ "$rberr" = 403 ] || [ "$ERR" = 403 ]; then res R2 unknown "required checks read: 403"
  else res R2 MISSING "required checks must list agent-review plus a CI context (got: '${ctx:-none}'${ctx2:+ plus classic: '$ctx2'})"; fi
  # R5 is report only: classic protection is legacy here, so its presence or absence never gates
  if [ -n "$pb" ]; then res R5 ok "classic branch protection also present (report only)"
  elif [ "$ERR" = 403 ]; then res R5 unknown "classic protection read: 403 (report only)"
  else res R5 none "no classic branch protection (report only)"; fi
  for id in agent-fence agent-fence-tags; do
    [ "$id" = agent-fence ] && r=R3 || r=R4
    if [ "$RS_ERR" = 403 ] || [ "$RS_ERR" = network ]; then res "$r" unknown "ruleset list read: $RS_ERR"; continue; fi
    [ "$id" = agent-fence ] && { target=branch; inc="refs/heads/sbx/**"; } || { target=tag; inc="refs/tags/*"; }
    det=$(jq -r --arg n "$id" 'map(select(.name==$n)) | .[0].id // empty' <<<"$RS" 2>/dev/null || true)
    if [ -z "$det" ]; then res "$r" MISSING "no $id ruleset"; continue; fi
    if ! api "repos/$ORG/$R/rulesets/$det" > "$TMP/rs"; then res "$r" unknown "$id ruleset read: $ERR"; continue; fi
    det=$(cat "$TMP/rs")
    if [ "$(jq -r .enforcement <<<"$det")" = active ] \
       && jq -e --arg t "$target" --arg i "$inc" '.target==$t and (.conditions.ref_name.include | index($i) != null)' <<<"$det" >/dev/null \
       && [ "$(jq -r '.bypass_actors | length' <<<"$det")" -ge 1 ]; then
      res "$r" ok ""
    else
      res "$r" MISSING "$id: enforcement=$(jq -r .enforcement <<<"$det") target=$(jq -r .target <<<"$det") include=$(jq -r '.conditions.ref_name.include | join(",")' <<<"$det") bypass_actors=$(jq -r '.bypass_actors | length' <<<"$det")$([ "$id" = agent-fence ] && echo ' — sbx/** must stay writable by bots (bypass_actors)')"
    fi
  done
}

load_repo(){ # load_repo: META, BRANCH, LANGS, RS (+RS_ERR) for $R; an unreadable repo stops the run
  api "repos/$ORG/$R" > "$TMP/meta" || { echo "cannot read $ORG/$R: $ERR" >&2; exit 1; }
  META=$(cat "$TMP/meta"); BRANCH=$(jq -r .default_branch <<<"$META")
  api "repos/$ORG/$R/languages" > "$TMP/langs" || true
  if [ -s "$TMP/langs" ]; then LANGS=$(cat "$TMP/langs"); else LANGS='{}'; fi
  if api "repos/$ORG/$R/rulesets?per_page=100" > "$TMP/rslist"; then RS=$(cat "$TMP/rslist"); RS_ERR=; else RS=[]; RS_ERR=$ERR; fi
}

audit_repo(){
  local s
  load_repo; file_checks
  if [ -n "$(jq -r .description <<<"$META")" ]; then res S1 ok ""; else res S1 MISSING "description is empty"; fi
  if [ "$(jq -r '.topics | length' <<<"$META")" -ge 1 ]; then res S2 ok ""; else res S2 MISSING "no topics"; fi
  # probe_settings speaks fix/ok for apply-settings; for the audit a fix is simply a MISSING item
  while IFS='|' read -r s st why; do [ "$st" = fix ] && st=MISSING; res "$s" "$st" "$why"; done < <(probe_settings)
  ruleset_checks
}

render(){
  local r rows line id st why
  if [ "$JSON" = yes ]; then
    printf '%s' "$RESULTS" | jq -Rs 'split("\n") | map(select(length>0) | split("|"))
      | group_by(.[0]) | map({repo: .[0][0], checks: (map({key: .[1], value: {status: .[2], reason: (.[3] // "")}}) | from_entries)})'
    return
  fi
  for r in "${AUDITED[@]}"; do
    rows=$(grep "^$r|" <<<"$RESULTS" || true); line="$ORG/$r"
    while IFS='|' read -r _ id st _; do line+=" $id:$st"; done <<<"$rows"
    echo "$line"
    while IFS='|' read -r _ id st why; do case $st in ok) ;; *) echo "    $id $st: $why" ;; esac; done <<<"$rows"
  done
}

AUDITED=()
case $CMD in
audit)
  if [ ${#REPOS[@]} -eq 0 ]; then
    while read -r R; do AUDITED+=("$R"); done < <(ghc api "orgs/$ORG/repos?per_page=100" --paginate --slurp 2>/dev/null |
      jq -r '.[][] | select(.archived != true) | .name' 2>/dev/null ||
      api "orgs/$ORG/repos?per_page=100" | jq -r '.[] | select(.archived!=true) | .name')
  else AUDITED=("${REPOS[@]}"); fi
  for R in "${AUDITED[@]}"; do audit_repo; done
  render
  if [ "$FAIL" = no ]; then exit 0; fi
  echo "audit: required baseline items missing or unverifiable in $ORG (see above)" >&2; exit 1 ;;
apply-settings)
  R=${REPOS[0]}; load_repo
  call(){ if [ "$APPLY" = yes ]; then
            ghc api -X "$1" "$2" "${@:3}" >/dev/null && echo "applied $1 $2 ${*:3}" || echo "FAILED  $1 $2 ${*:3}"
          else echo "would  $1 $2 ${*:3}"; fi; }
  while IFS='|' read -r s st why; do case "$s:$st" in
    S3:fix) call PATCH "repos/$ORG/$R" -F delete_branch_on_merge=true ;;
    S4:fix) call PATCH "repos/$ORG/$R" -F has_wiki=false ;;
    S5:fix) call PUT "repos/$ORG/$R/vulnerability-alerts"; call PUT "repos/$ORG/$R/automated-security-fixes" ;;
    S6:fix) call PATCH "repos/$ORG/$R/secret-scanning" -F state=enabled
             call PATCH "repos/$ORG/$R/secret-scanning/push-protection" -F status=enabled ;;
  esac
  { [ "$st" != fix ] && echo "skip   $s: $st${why:+ ($why)}"; } || true
  done < <(probe_settings)
  echo "rulesets, classic branch protection, visibility and paid features are owner-gated: never changed here" ;;
plan-rulesets)
  R=${REPOS[0]}; load_repo
  for t in "$ROOT"/templates/rulesets/*.json; do
    echo "# ${t##*/} — review, fill the bypass actor ids, then apply as an owner-gated action:"
    echo "#   gh api -X POST repos/$ORG/$R/rulesets --input ${t#"$ROOT"/}"
    jq --arg branch "$BRANCH" 'walk(if type=="string" then gsub("__DEFAULT_BRANCH__"; $branch) else . end)' "$t"
  done ;;
esac
