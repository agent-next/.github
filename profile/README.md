# agent-next

**Infrastructure for deliverable AI agents.**

We build open-source tools that make codebases readable, testable, and actionable for autonomous AI agents. If an agent can't understand your repo, it can't ship for you.

## Core Projects

| Project | What it does | |
|---------|-------------|---|
| **[agent-ready](https://github.com/agent-next/agent-ready)** | CLI scanner that scores your repo on 9 Pillars / 5 Levels of agent readiness | [![npm](https://img.shields.io/npm/v/agent-ready)](https://www.npmjs.com/package/agent-ready) |
| **[agent-ready API](https://agent-ready.org/api)** | Hosted multi-agent analysis — 9 parallel agents, results in < 2s | [Live](https://agent-ready.org/api/health) |
| **[agent-ready.org](https://agent-ready.org)** | Interactive portal — paste a GitHub URL, get a readiness report | [Visit](https://agent-ready.org) |
| **[behavior-driven-testing](https://github.com/agent-next/behavior-driven-testing)** | BDD framework for validating AI agent behavior | [![Claude Code](https://img.shields.io/badge/Claude_Code-skill-blue)](https://skills.sh/agent-next/behavior-driven-testing/behavior-driven-testing) |

## The Agent-Ready Standard

The **9-Pillar / 5-Level** maturity model that defines what "agent-ready" means:

```
L1 Functional → L2 Documented → L3 Standardized → L4 Optimized → L5 Autonomous
```

**9 Pillars**: Documentation, Style, Build, Testing, Security, Observability, Environment, Task Discovery, Product

An agent needs structured entry points (AGENTS.md), predictable builds, automated tests, and clear task definitions to operate autonomously. The standard codifies this.

```bash
npx agent-ready scan .
```

## Get Involved

- [Contributing Guide](https://github.com/agent-next/.github/blob/main/CONTRIBUTING.md)
- [Security Policy](https://github.com/agent-next/.github/blob/main/SECURITY.md)
- [Discussions](https://github.com/agent-next/agent-ready/discussions)

## Maintainers

[@robotlearning123](https://github.com/robotlearning123)
