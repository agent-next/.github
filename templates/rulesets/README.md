# Ruleset templates (R1-R4 of the repo baseline)

Generic starting points for the rulesets `repo-baseline.sh audit` checks for. No secrets; nothing
here is applied by any script — `scripts/repo-baseline.sh plan-rulesets --repo NAME` only prints
them with the repo's default branch filled in. Creating or changing rulesets is an owner-gated
action (AGENT-STANDARD.md, Hard limits).

Both fences target `~ALL` and carve agent refs out of the exclude list — they fence everything
except `sbx/**` (sandbox pushes never hit the fence) and the bot/dependabot branches, so the
default branch is left to `agent-default-branch` alone.

Before using one, the operator fills in:

- `bypass_actors`: the placeholder `actor_id: 0` must become the bot App's real actor id (or a
  team id with `actor_type: Team`) so agent branches stay bot-writable (`agent-fence`) or
  releases stay owner-gated (`agent-default-branch`, `agent-fence-tags`).
- `__CI_CONTEXT__`: the context name of the repo's CI check (e.g. `ci`) in
  `agent-default-branch.json`, next to `agent-review`.
- `__DEFAULT_BRANCH__` is substituted automatically by `plan-rulesets`.
