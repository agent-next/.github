# agent-next/.github — agent entrypoint

Org rules: https://github.com/agent-next/.github/blob/main/AGENT-STANDARD.md (this repo hosts it;
`AGENT-STANDARD.md` here). This file holds only repo-specific facts and never copies its hard limits.

## Purpose

Public org-level repo for github.com/agent-next: the agent standard, the org profile, and
the community health files (issue/PR templates, security, conduct, contributing, funding,
code owners). Default branch: `main`. Docs-only.

## Orient

- `AGENT-STANDARD.md`: the org standard (version in its first line). Changing it is owner-gated.
- `profile/README.md`: org profile page. `ROADMAP.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, `CODEOWNERS`, `FUNDING.yml`, `ISSUE_TEMPLATE/`, `PULL_REQUEST_TEMPLATE.md`.

## Setup

None. `make setup` is a no-op echo.

## Check

`make check` verifies the baseline files are present and non-empty (the merge-gate scripts
were removed from the public tree; see `AGENT-STANDARD.md` for the merge policy itself).
Non-interactive, no secrets, no network, no GPU. Run it before every PR.

## Boundaries

- This repo is PUBLIC: no internal plans, strategy, timelines, people names, or data paths
  in any file.
- Do not edit `AGENT-STANDARD.md` content without owner approval; a version bump accompanies
  any approved change.
- Root `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md` and `PULL_REQUEST_TEMPLATE.md`
  are org-wide defaults for repos without their own. Issue templates and `FUNDING.yml` only
  propagate from a `.github/` folder, so the root copies here do not. Other files never do.
- No workflows exist yet; adding CI needs an independent review.

## Done

`make check` exits 0 with output pasted in the PR body, branch pushed, PR opened (never
self-merged), and your worktree and scratch removed.
