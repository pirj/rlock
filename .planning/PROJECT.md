# AILockr

## What This Is

A shell-based CLI tool (`rl`) that runs AI coding agents (Claude Code, Codex) inside QEMU virtual machines, completely isolated from the host filesystem. The VM communicates with the host only via git, and API keys never enter the VM — a Caddy reverse proxy on the host injects authorization headers. Built on top of pirj/aq for fast VM lifecycle management.

## Core Value

AI agents can run in full "danger mode" without risking the host machine — code stays isolated, secrets stay on the host, and the only bridge is git.

## Current State

**Shipped:** v1.0 MVP (2026-03-30)
**Codebase:** 1,074 lines of bash across 8 files (bin/rl + 7 lib/ modules)
**Tech stack:** Bash 5.x, QEMU/aq, Caddy 2.x, Alpine Linux 3.22, mise-en-place

### What Works
- `rl new` — creates per-repo QEMU VM with Alpine, provisions bash/tmux/git/mise/sudo, creates unprivileged `ai` user, starts Caddy proxy, auto-installs Claude Code if available on host, initializes guest git repo, pushes current branch
- `rl code` — SSH+tmux session as `ai` user with mise env vars loaded (proxy URLs, dummy API keys), auto-start stopped VMs
- `rl status` — compact one-liner with running state, PID, SSH port
- `rl rm` — destroys VM, removes git remote `rl` and core.sshCommand config
- `rl auth` — imports OAuth tokens from Claude Code macOS Keychain, background refresh daemon, fallback to API key entry
- `git fetch rl` / `git push rl` — transparent code bridge over SSH

### Known Gaps
- **AGENT-02 (Codex):** Install function implemented but untested — no host `codex` binary available
- **Cross-platform:** `qemu-system-aarch64` hardcoded in dependency check (macOS-first)

## Requirements

### Validated (v1.0)

- ✓ User can create a new per-repo VM with `rl new` — v1.0
- ✓ User can SSH into the VM and start/resume a coding session with `rl code` — v1.0
- ✓ User can check airlock status with `rl status` — v1.0
- ✓ User can destroy VM with `rl rm` — v1.0
- ✓ Host adds guest as a git remote; code moves via git — v1.0
- ✓ API keys stay on the host; Caddy proxy injects auth headers — v1.0
- ✓ Guest configured with proxy base URLs via mise — v1.0
- ✓ No API keys in VM (dummy keys only) — v1.0
- ✓ Claude Code pre-installed and functional inside VM — v1.0

### Active

- [ ] Codex pre-installed and functional inside VM (deferred — no host binary)
- [ ] VM has internet access for documentation and package installation
- [ ] Config file copying from host is opt-in and explicit (`rl new --config claude --config git`)
- [ ] VM resource limits enforced (1GB disk, 1 vCPU — handled by aq defaults)
- [ ] Tool works as an installable open source project others can use

### Out of Scope

- Network egress filtering/monitoring — adds complexity, internet access is intentional
- Pre-built VM images — aq installs packages fast enough on Alpine, reproducibility isn't critical yet
- Session recording/observability — useful later, not core to the isolation value
- GUI or web interface — this is a CLI tool
- Docker-based isolation — the whole point is VM-level isolation

## Context

- Built on pirj/aq (github.com/pirj/aq), a QEMU wrapper for fast Alpine VM lifecycle
- QEMU user-mode networking provides host gateway at 10.0.2.2 by default
- Claude Code supports ANTHROPIC_BASE_URL env var for custom API endpoint
- Codex supports OPENAI_BASE_URL env var for custom API endpoint
- Caddy uses `request_header` directive (not `header_up`) for reliable header injection
- OAuth tokens imported from Claude Code macOS Keychain with background refresh daemon
- Guest runs as unprivileged `ai` user (bypassPermissions blocked as root)
- The "airlock" metaphor: controlled passage between host and guest, not total isolation
- Primary use case: running AI agents safely in full-permission mode
- Secondary use case: maintainers safely reviewing/running untrusted PRs

## Constraints

- **VM engine**: QEMU via pirj/aq — no Docker, no containers
- **Guest OS**: Alpine Linux (what aq uses)
- **Shell script**: The tool itself is a shell script (bash), not a compiled binary
- **Dependencies**: Requires aq, Caddy, and git on the host machine

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| VM over Docker | Stronger isolation boundary — shared kernel in Docker is insufficient for "danger mode" | ✓ Good |
| Git remote instead of GitHub access from guest | Guest never needs credentials for external services; host controls all external communication | ✓ Good |
| Caddy reverse proxy for API keys | Avoids MITM/TLS complexity; custom API base URLs supported natively by both agents | ✓ Good |
| `request_header` over `header_up` | `header_up` inside reverse_proxy didn't reliably inject headers | ✓ Good |
| OAuth import from macOS Keychain | Piggybacking on Claude Code's auth avoids reimplementing OAuth | ✓ Good |
| Unprivileged `ai` user in guest | `bypassPermissions` blocked as root; non-root user also better security practice | ✓ Good |
| `receive.denyCurrentBranch=updateInstead` | Allows push to working tree — agent sees files immediately | ✓ Good |
| mise-en-place for guest env vars | Clean per-directory env var management without polluting shell profiles | ✓ Good |
| Auto-detect host agents (no --agent flag) | If claude/codex binary exists on host → install in guest. Simpler UX | ✓ Good |
| Per-repo VM lifecycle | Balance between ephemeral safety and practical reuse across coding sessions | ✓ Good |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-30 after v1.0 milestone*
