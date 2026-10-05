# agent-next/.github — agent entrypoint

Org rules: https://github.com/agent-next/.github/blob/main/AGENT-STANDARD.md (this repo hosts it;
`AGENT-STANDARD.md` here). This file holds only repo-specific facts and never copies its hard limits.

## Purpose

Public org-level repo for github.com/agent-next: the agent standard, the org profile,
community health files (issue/PR templates, security, conduct, contributing, funding,
code owners), and the merge-gate scripts that implement the standard's merge policy.
Default branch: `main`. Docs-only apart from the shell scripts.

## Orient

- `AGENT-STANDARD.md`: the org standard (version in its first line). Changing it is owner-gated.
- `profile/README.md`: org profile page. `ROADMAP.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, `CODEOWNERS`, `FUNDING.yml`, `ISSUE_TEMPLATE/`, `PULL_REQUEST_TEMPLATE.md`.
- `scripts/agent-review.sh`, `scripts/agent-merge.sh`: the `agent-review` status poster and the
  gate-checking merger. Tests are hermetic (gh, git and lanes are shims): `tests/*.test.sh`.
- `scripts/check-docs.py`: docs gate (version header, relative links, AGENTS.md length).

## Setup

None. `make setup` is a no-op echo. Needs `python3` and `bash` only.

## Check

`make check` runs the docs gate and both script test suites. Non-interactive, no secrets,
no network, no GPU. Run it before every PR.

## Boundaries

- This repo is PUBLIC: no internal plans, strategy, timelines, people names, or data paths
  in any file.
- Do not edit `AGENT-STANDARD.md` content without owner approval; a version bump accompanies
  any approved change.
- Files here apply to every org repo; keep edits minimal and re-check links.
- No workflows exist yet; adding CI or changing the gate scripts needs an independent review.

## Done

`make check` exits 0 with output pasted in the PR body, branch pushed, PR opened (never
self-merged), and your worktree and scratch removed.
