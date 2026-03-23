# Requirements: AILockr

**Defined:** 2026-03-24
**Core Value:** AI agents can run in full "danger mode" without risking the host machine — code stays isolated, secrets stay on the host, and the only bridge is git.

## v1 Requirements

### VM Lifecycle

- [ ] **VM-01**: User can create a new per-repo VM with `rl new` (Alpine Linux via aq, with Claude Code, Codex, tmux, and git pre-installed)
- [ ] **VM-02**: User can destroy a VM and clean up resources with `rl rm`
- [ ] **VM-03**: User can check if current repo has an attached airlock with `rl status`

### Session Management

- [ ] **SESS-01**: User can SSH into VM and start or resume a tmux coding session with `rl code`

### Code Bridge

- [ ] **CODE-01**: Host adds guest as a git remote; code moves between host and guest exclusively via git (fetch-based workflow)

### Security

- [ ] **SEC-01**: Caddy reverse proxy on host injects Authorization headers for Anthropic and OpenAI APIs
- [ ] **SEC-02**: Guest Claude Code/Codex configured to use host proxy via ANTHROPIC_BASE_URL / OPENAI_BASE_URL env vars pointing to 10.0.2.2
- [ ] **SEC-03**: API keys never enter the VM in any form (not in env vars, config files, or process memory)

### Agent Setup

- [ ] **AGENT-01**: Claude Code is pre-installed and functional inside the VM
- [ ] **AGENT-02**: Codex is pre-installed and functional inside the VM

## v2 Requirements

### Usability

- **USE-01**: User can copy specific host configs into VM with opt-in flags (`rl new --config claude --config git`)
- **USE-02**: User can list all VMs with `rl list`
- **USE-03**: User can configure resource limits per VM (`rl new --disk 2G --cpus 2`)

### Multi-Agent

- **MULTI-01**: User can create multiple VMs per repo on different branches for parallel agent work
- **MULTI-02**: Port allocation handles multiple concurrent VMs without conflicts

### PR Review

- **PR-01**: User can safely review a PR in an isolated VM with `rl review <PR-URL>`

## Out of Scope

| Feature | Reason |
|---------|--------|
| Network egress filtering | Adds complexity; isolation model already prevents secret exfiltration since keys never enter VM |
| Pre-built VM images | aq installs packages fast enough on Alpine; avoids image distribution/versioning burden |
| GUI/browser access in VM | Contradicts lightweight CLI philosophy; agents output text (diffs, logs, code) |
| Docker-in-VM | Extra virtualization layer adds fragility and resource cost; agent can write Dockerfiles and push via git |
| Web dashboard | Contradicts CLI-first philosophy; `rl status/list` sufficient |
| Session recording/audit | Git history IS the audit trail; session recording adds storage overhead |
| Secret scanning | Prevention > detection; API keys never enter VM, config copying is opt-in |
| Agent orchestration | Isolation tool should sandbox, not orchestrate; leave task division to user |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| VM-01 | Pending | Pending |
| VM-02 | Pending | Pending |
| VM-03 | Pending | Pending |
| SESS-01 | Pending | Pending |
| CODE-01 | Pending | Pending |
| SEC-01 | Pending | Pending |
| SEC-02 | Pending | Pending |
| SEC-03 | Pending | Pending |
| AGENT-01 | Pending | Pending |
| AGENT-02 | Pending | Pending |

**Coverage:**
- v1 requirements: 10 total
- Mapped to phases: 0
- Unmapped: 10 ⚠️

---
*Requirements defined: 2026-03-24*
*Last updated: 2026-03-24 after initial definition*
