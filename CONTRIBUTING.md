# Contributing

Thanks for your interest in contributing to **agent-next** projects.

## Proof-First Principle

All contributions follow our proof-first approach: changes must include evidence that they work correctly. This means:

- **Tests before merge** — new behavior needs test coverage
- **No silent regressions** — existing tests must continue to pass
- **Evidence in the PR** — show what was tested and how

## Branch Naming

```
<type>/<description>

feat/add-docker-check
fix/path-glob-windows
docs/update-readme
refactor/simplify-engine
test/add-integration
ci/add-coverage
```

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add new check type for Docker support
fix: handle missing package.json gracefully
docs: update CONTRIBUTING guide
test: add fixtures for monorepo detection
```

## PR Process

1. Create a branch from `main` using the naming convention above
2. Make small, focused commits
3. Ensure tests pass and new behavior has coverage
4. Open a PR with a clear title (conventional commit format) and description
5. All automated checks must pass before merge

Direct pushes to `main` are blocked. All changes go through PRs.

## Repository-Specific Guides

Some repositories have additional rules in their own `CONTRIBUTING.md`. If present, follow the repo-local guide first.

## Code Of Conduct

By participating, you are expected to uphold the [Code of Conduct](./CODE_OF_CONDUCT.md).
