# Phase 3: Agent Provisioning - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-28
**Phase:** 03-agent-provisioning
**Areas discussed:** Agent selection, Claude Code installation, Codex installation, agent auth

---

## Agent Selection

| Option | Description | Selected |
|--------|-------------|----------|
| Always install both | Every VM gets Claude Code + Codex | |
| User-selectable, default both | --agent flag, both by default | |
| User-selectable, default none | --agent flag, nothing by default | ✓ |

**User's choice:** Default none. User specifies `--agent claude` and/or `--agent codex`. Detect host binaries to validate.
**Notes:** User said "Claude or Codex or both? User should decide. By default - none. Check the presence of corresponding binaries/packages on the host. We'll rely on them for the tokens anyway."

---

## Claude Code Installation

| Option | Description | Selected |
|--------|-------------|----------|
| npm global install | `npm install -g @anthropic-ai/claude-code` | ✓ |
| Binary download | Pre-built binary from Anthropic | |
| mise install | Use mise to manage Claude Code version | |

**User's choice:** npm global install. Tested in live VM — works on Alpine musl.
**Notes:** User asked to "experiment with installation and musl compatibility in a new vm." Tested: Node.js 22 + npm from Alpine repos, `npm install -g @anthropic-ai/claude-code` succeeds, `claude --version` returns 2.1.85, `claude -p "say hi"` routes through proxy successfully.

---

## Agent Auth Behavior

**User's request:** "Explore deeply if Claude Code would prompt to auth."

**Finding:** Claude Code does NOT prompt for auth. With `ANTHROPIC_API_KEY=dummy` and `ANTHROPIC_BASE_URL=http://10.0.2.2:9110`, it accepts the dummy key and makes API calls without interactive setup. The `--help` output confirms `--bare` mode exists for minimal operation.

---

## Codex Installation

**User's position:** Deferred. No `codex` binary on host. Proxy port and env vars already configured by Phase 2. Will test when Codex is available.

## Claude's Discretion

- npm install flags and caching
- Claude Code version pinning
- `--dangerously-skip-permissions` activation method

## Deferred Ideas

- Codex end-to-end testing (needs host binary)
- `rl new --config claude` for host config copying (v2 USE-01)
