# AILockr

## What This Is

A shell-based CLI tool (`rl`) that runs AI coding agents (Claude Code, Codex) inside QEMU virtual machines, completely isolated from the host filesystem. The VM communicates with the host only via git, and API keys never enter the VM — a Caddy reverse proxy on the host injects authorization headers. Built on top of pirj/aq for fast VM lifecycle management.

## Core Value

AI agents can run in full "danger mode" without risking the host machine — code stays isolated, secrets stay on the host, and the only bridge is git.

## Requirements

### Validated

- [x] User can create a new per-repo VM with `rl new` — Validated in Phase 1: cli-skeleton-and-vm-lifecycle
- [x] User can SSH into the VM and start/resume a coding session with `rl code` — Validated in Phase 1: cli-skeleton-and-vm-lifecycle
- [x] API keys stay on the host; Caddy proxy injects auth headers — Validated in Phase 2: security-boundary
- [x] Guest configured with proxy base URLs via mise — Validated in Phase 2: security-boundary
- [x] Caddy listens on host, guest reaches it via QEMU gateway (10.0.2.2) — Validated in Phase 2: security-boundary

### Active

- [x] User can create a new per-repo VM with `rl new` that has Claude Code, Codex, tmux, and git installed (Alpine Linux via aq) — Phase 1
- [x] User can SSH into the VM and start/resume a coding session with `rl code` — Phase 1
- [ ] Host adds guest as a git remote — guest has no GitHub access, only local git
- [x] API keys stay on the host; Caddy proxy injects Authorization headers for Anthropic and OpenAI APIs — Phase 2
- [x] Guest Claude Code/Codex configured to use host proxy via custom API base URL env vars (ANTHROPIC_BASE_URL, OPENAI_BASE_URL) — Phase 2
- [x] Caddy listens on host, guest reaches it via QEMU gateway (10.0.2.2) — Phase 2
- [ ] VM has internet access for documentation and package installation
- [ ] Config file copying from host is opt-in and explicit (e.g. `rl new --config claude --config git`)
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
- Caddy can reverse proxy with header injection in ~10 lines of config
- The "airlock" metaphor: controlled passage between host and guest, not total isolation
- Primary use case: running AI agents safely in full-permission mode
- Secondary use case: maintainers safely reviewing/running untrusted PRs

## Constraints

- **VM engine**: QEMU via pirj/aq — no Docker, no containers
- **Guest OS**: Alpine Linux (what aq uses)
- **Shell script**: The tool itself is a shell script (POSIX sh or bash), not a compiled binary
- **Dependencies**: Requires aq, Caddy, and git on the host machine

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| VM over Docker | Stronger isolation boundary — shared kernel in Docker is insufficient for "danger mode" | — Pending |
| Git remote instead of GitHub access from guest | Guest never needs credentials for external services; host controls all external communication | — Pending |
| Caddy reverse proxy for API keys | Avoids MITM/TLS complexity; custom API base URLs supported natively by both agents | — Pending |
| Opt-in config copying | Configs may contain tokens/secrets; blind copying creates exfiltration risk | — Pending |
| Per-repo VM lifecycle | Balance between ephemeral safety and practical reuse across coding sessions | — Pending |

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
*Last updated: 2026-03-29 after Phase 4 completion — git code bridge, milestone v1.0 complete*
