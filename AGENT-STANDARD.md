# agent-next agent standard — v0.2.1

## Scope

This standard applies to every repository in github.com/agent-next, public and private.
Each repo keeps its own `AGENTS.md` for repo-specific facts (purpose, setup, boundaries);
that file links here and never copies the hard limits below. If a repo file conflicts with
this standard, this standard wins unless the owner says otherwise in writing.

## Operating model

- Agent-native first: agents discover, set up, change, verify, review, and merge the work end to end,
  headless. A step that needs a person to click or approve is a defect to remove, not a gate to keep.
- People are on the loop, not in it: they set direction, watch receipts and reports, give feedback,
  and decide the owner-gated actions listed under Hard limits. Nothing else waits for a person.
- Every PR, branch, worktree, and issue is handled as its own item with its own agent review.
  Never batch unrelated items into one review, merge, or cleanup.

## Hard limits

These apply even under elevated-permission modes:

- Never commit or print credentials, tokens, or .env files; secrets live in a secrets manager outside the repo and are read at runtime.
- Never delete data files, workspace directories, or agent session/chat history without the owner's confirmation; archive or move instead.
- Never force-push main/master; touch only branches and worktrees you created.
- Repo visibility, delete/archive/transfer, branch protection, secrets, releases, and publishing need explicit owner confirmation per action.

## Workflow

- One branch per change; small PRs; never commit directly to the default branch.
- Conventional commit messages (`feat:`, `fix:`, `docs:`, `chore:`, ...). No
  Co-Authored-By or tool-attribution trailers on commits or PRs.
- Every PR that adds production code includes at least one test with a real oracle.
- `make setup` installs dependencies with the repo's existing tool; `make check` runs
  the repo's lint + tests and is the same gate CI runs. Both must be non-interactive,
  need no secrets, no paid APIs, and no GPU.
- Receipts: claims in a PR body are backed by real commands and their real output,
  pasted in the PR body. A claim without a receipt is a draft.
- Clean your own work in time: temp files, scratch branches, clones, and stale worktrees you
  created are removed as soon as they stop being useful. Clean only what you created.

## Merge policy (agent-native gate)

- There is no human approval step. The gate on every default branch is: pull request, every
  required CI check green, and the commit status `agent-review` = success on the PR's current
  head commit.
- `agent-review` is posted by `scripts/agent-review.sh` after a reviewer lane of a different
  model family than the declared writer family reviews that exact head commit file by file.
  A new push creates a new head with no status, so a stale review never counts.
- Anyone with write access can post a commit status, so the merger counts the latest
  `agent-review` status only when its creator is a configured reviewer identity
  (`AGENT_REVIEW_POSTERS`); an unconfigured merger blocks. This is an identity allowlist, not
  proof of which agent reviewed. Reviewer lanes of the caller-declared writer model family
  (`AGENT_WRITER_FAMILY`) are refused, a lane that errors or gives no verdict never counts, and a
  lane that silently routes to a weaker model is marked degraded on the status.
- Writer, reviewer, and merger are separate roles. The merger checks the gate and merges that
  exact head (`scripts/agent-merge.sh`); it never reviews its own work.
- The gate is declared server-side, not by convention. The org is on a paid GitHub Team
  plan; default branches carry repo rulesets (or classic branch protection on older
  repos) that block deletion and non-fast-forward pushes and require a pull request.
  Approval counts differ per repo — 0 where the agent-native gate is wired (the
  `agent-review` status is the review), 1 where older protection still requires it.
  zagent's `agent-merge-gate` ruleset is the reference: `pull_request` plus required
  status checks including `agent-review`. Changing any of this is an owner-gated action.
- Agent-side enforcement: `scripts/agent-merge.sh` (this repo) merges only an exact head
  with `agent-review` = success and all required checks green. For repos not yet wired
  for `agent-review`, `gh-safe-merge` (robotlearning123/my-coding-agent-config, `bin/`)
  is the green-checks gate. Checking CI and merging are separate steps: confirm every
  required check green on the current head, then merge that head.

## Repo baseline (v0.1.0)

Every active repo carries this per-repo baseline (v0.1.0, 2026-09-24); this section is its
complete definition:

1. **AGENTS.md** (required, <=90 lines): repo guide with Purpose, Orient, Setup,
   Check, Boundaries, Done sections; links to this file; only verified facts.
2. **CLAUDE.md**: one line `@AGENTS.md` (created if absent; never deletes content).
3. **Makefile**: `setup` and `check` targets using the repo's existing tooling;
   `check` is never a no-op — repos without tests run the cheapest real validation.
4. **CI**: a `ci.yml` on pull_request + push to default that runs `make setup` and
   `make check`, if no existing workflow tests PRs; existing CI is never rewritten.
   Self-hosted jobs run on the ci-do1 ephemeral pool (runner label `agent-next-ci`);
   private repos get minimal jobs only.
5. **Dependabot**: monthly, grouped, limit 2, ecosystems actually present.
6. **Dev environment**: minimal `.devcontainer` with official image and
   `postCreateCommand: make setup`; skipped for docs-only repos.

## Keeping current

Org hygiene is reported, not improvised:

- `org-state-report` runs daily at 06:23 via a systemd user timer on robot-intel and
  reports: clone freshness, merged branches to prune, worktrees stale >7 days, and
  PRs open >14 days.
- Agents act on that report only within their authorization — pruning a merged
  branch you created is routine; deleting anything else needs owner confirmation
  per the hard limits.
- When this standard changes, bump its version and note the delta; repo AGENTS.md
  files link here, so they pick up changes automatically.
