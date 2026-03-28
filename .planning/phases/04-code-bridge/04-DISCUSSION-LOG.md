# Phase 4: Code Bridge - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-29
**Phase:** 04-code-bridge
**Areas discussed:** Git remote setup, initial code transfer, fetch workflow, guest repo type

---

## Git Remote Setup

| Option | Description | Selected |
|--------|-------------|----------|
| `airlock` | Named after the project concept | |
| `vm` | Generic | |
| `rl` | Matches the CLI tool name | ✓ |

**User's choice:** Remote name `rl`, added automatically during `rl new`.

---

## Initial Code Transfer

| Option | Description | Selected |
|--------|-------------|----------|
| Manual push | User pushes after rl new | |
| Auto push all branches | Push everything | |
| Auto push current branch only | Push HEAD | ✓ |

**User's choice:** Push current branch automatically during `rl new`.

---

## Fetch Workflow

| Option | Description | Selected |
|--------|-------------|----------|
| `rl fetch` command | Custom wrapper | |
| `git fetch rl` | Standard git | ✓ |

**User's choice:** Standard `git fetch rl` — no custom command needed.

---

## Guest Repo Type

| Option | Description | Selected |
|--------|-------------|----------|
| Bare repo | No working tree, receive-pack only | |
| Working tree + updateInstead | Agents can work, pushes update working tree | ✓ |

**User's choice:** Working tree with `receive.denyCurrentBranch=updateInstead`. Same SSH for both directions.

## Claude's Discretion

- GIT_SSH_COMMAND wrapper
- Refspec configuration
- Push error handling
- Unfetched commit warnings on rm

## Deferred Ideas

None
