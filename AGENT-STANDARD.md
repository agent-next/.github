# agent-next agent standard — v0.1.0

## Scope

This standard applies to every repository in github.com/agent-next, public and private.
Each repo keeps its own `AGENTS.md` for repo-specific facts (purpose, setup, boundaries);
that file links here and never copies the hard limits below. If a repo file conflicts with
this standard, this standard wins unless the owner says otherwise in writing.

## Hard limits

These apply even under elevated-permission modes:

- Never commit or print credentials, tokens, or .env files; secrets live in 1Password (op read).
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

## Merge policy

- Non-trivial diffs get independent review before merge.
- Checking CI and merging are separate steps: confirm every check is green, then merge.
  Merge only when every required check is green.
- Use `gh-safe-merge` from the owner's config repo when available; it enforces the
  green-checks gate before merging.
- The org is on the GitHub free plan: private repos have no server-side branch
  protection. This policy is enforced by agents and by a local pre-push hook that
  blocks direct pushes to main/master.

## Repo baseline (v0.1.0)

Every active repo carries the per-repo baseline defined in the agent-next baseline
standard v0.1.0 (2026-09-24). Summary of its sections:

1. **AGENTS.md** (required, <=90 lines): repo guide with Purpose, Orient, Setup,
   Check, Boundaries, Done sections; links to this file; only verified facts.
2. **CLAUDE.md**: one line `@AGENTS.md` (created if absent; never deletes content).
3. **Makefile**: `setup` and `check` targets using the repo's existing tooling;
   `check` is never a no-op — repos without tests run the cheapest real validation.
4. **CI**: a `ci.yml` on pull_request + push to default that runs `make setup` and
   `make check`, if no existing workflow tests PRs; existing CI is never rewritten;
   private repos get minimal jobs only (free Actions minutes).
5. **Dependabot**: monthly, grouped, limit 2, ecosystems actually present.
6. **Dev environment**: minimal `.devcontainer` with official image and
   `postCreateCommand: make setup`; skipped for docs-only repos.

## Keeping current

Org hygiene is reported, not improvised:

- `org-state-report` runs daily and reports: clone freshness, merged branches to
  prune, worktrees stale >7 days, and PRs open >14 days.
- Agents act on that report only within their authorization — pruning a merged
  branch you created is routine; deleting anything else needs owner confirmation
  per the hard limits.
- When this standard changes, bump its version and note the delta; repo AGENTS.md
  files link here, so they pick up changes automatically.
