# agent-next

**Infrastructure for deliverable AI agents.**

Today's AI agents can chat. Tomorrow's will ship. We're building the missing infrastructure layer — the standards, tools, and runtime that turn AI agents from demos into reliable delivery systems.

## The Problem

AI agents fail in production because codebases aren't built for them and there's no way to verify what agents actually deliver. agent-next closes both gaps.

## What We're Building

```
Prepare           →  Equip             →  Verify            →  Ship
Code ready         Agent has skills      Behavior validated    Reliable delivery
for agents         and context           before merge          at scale
```

| Layer | Project | Status |
|-------|---------|--------|
| **Prepare** | [agent-ready](https://github.com/agent-next/agent-ready) — Readiness scanner (9 Pillars / 5 Levels) | [![npm](https://img.shields.io/npm/v/agent-ready)](https://www.npmjs.com/package/agent-ready) |
| **Prepare** | [agent-ready.org](https://agent-ready.org) — Interactive portal & hosted API | Live |
| **Verify** | [behavior-driven-testing](https://github.com/agent-next/behavior-driven-testing) — BDD framework for agent behavior | [![skill](https://img.shields.io/badge/Claude_Code-skill-blue)](https://skills.sh/agent-next/behavior-driven-testing/behavior-driven-testing) |
| **Equip** | agent-skills — Composable skill library for coding agents | Coming soon |
| **Ship** | agent-contracts — Delivery verification & certification | Planned |

## Why It Matters

- **For developers**: Know exactly what to fix so agents can work in your repo
- **For teams**: Validate agent output with the same rigor as human PRs
- **For the ecosystem**: A shared standard for what "agent-ready" means

## Get Started

```bash
# Check if your repo is ready for AI agents
npx agent-ready scan .
```

## Get Involved

- [Contributing](https://github.com/agent-next/.github/blob/main/CONTRIBUTING.md) · [Security](https://github.com/agent-next/.github/blob/main/SECURITY.md) · [Discussions](https://github.com/agent-next/agent-ready/discussions)

**Maintainer**: [@robotlearning123](https://github.com/robotlearning123)
