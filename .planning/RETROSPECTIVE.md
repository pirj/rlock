# Project Retrospective

## Milestone: v1.0 — MVP

**Shipped:** 2026-03-30
**Phases:** 4 | **Plans:** 6

### What Was Built
- CLI entry point with modular lib/ architecture (1,074 LOC bash)
- Caddy reverse proxy with OAuth token import from Claude Code keychain
- Claude Code auto-provisioned in QEMU VMs with bypassPermissions
- Git code bridge with `updateInstead` for transparent push/fetch

### What Worked
- Hands-on testing during discuss-phase caught real issues early (musl compat, auth prompts)
- Early `save_vm_name` pattern prevented orphaned VM state across all subsequent phases
- Single provisioning heredoc pattern kept guest setup atomic and debuggable
- Auto-detection of host agents (no --agent flag) simplified the UX

### What Was Inefficient
- Spinner `wait` exit code bug caused silent script exits — took multiple debug rounds to find
- Caddy `header_up` vs `request_header` — incorrect docs in CLAUDE.md led to broken proxy; had to debug with curl
- Caddy Host header matching (`127.0.0.1` vs `10.0.2.2`) — non-obvious SLIRP networking behavior
- Alpine `adduser -D` locks accounts — SSH pubkey auth silently rejected, extensive debugging needed
- Multiple provisioning issues discovered serially (mise shell type, ash vs bash, community repo ordering)

### Patterns Established
- `aq exec` with `su - ai` for unprivileged guest operations
- `spinner_start`/`spinner_stop` with `|| true` on wait for killed processes
- Credential store in `~/.config/rl/credentials` with keychain import
- `request_header` (server-level) for Caddy header injection, not `header_up` (proxy-level)
- `http://:PORT` with `bind 127.0.0.1` for Caddy to accept any Host header

### Key Lessons
- Test SSH as the actual user (not root) during provisioning verification
- Enable Alpine community repo BEFORE installing packages that need it
- QEMU SLIRP traffic appears as 127.0.0.1 on host but sends different Host header
- `set -euo pipefail` interacts badly with background process cleanup — always `|| true` on `wait`

### Cost Observations
- Model mix: ~80% opus, ~20% sonnet (checker/verifier)
- Sessions: 1 continuous session across all 4 phases
- Notable: Phase 1 took longest (establishing patterns), Phases 3-4 were fast (reusing patterns)

---

## Cross-Milestone Trends

| Metric | v1.0 |
|--------|------|
| Phases | 4 |
| Plans | 6 |
| LOC | 1,074 |
| Timeline | 7 days |
| Bugs found in verification | 12+ |
| Key pattern changes | 5 |
