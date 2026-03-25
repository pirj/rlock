# Phase 2: Security Boundary - Context

**Gathered:** 2026-03-26
**Status:** Ready for planning

<domain>
## Phase Boundary

API keys never enter the VM. A host-side Caddy reverse proxy injects Authorization headers so AI agents inside the VM can call APIs without possessing secrets. An OAuth sidecar on the host manages token lifecycle for Pro/Max subscription users. Guest VMs use dummy credentials and mise-en-place for env var management.

</domain>

<decisions>
## Implementation Decisions

### Proxy Architecture
- **D-01:** Single Caddy instance shared across all airlocks, listening on two fixed ports — one for Anthropic API, one for OpenAI API.
- **D-02:** Anthropic port (e.g., 9110) proxies to `https://api.anthropic.com` and injects `x-api-key` header from host's `$ANTHROPIC_API_KEY` env var.
- **D-03:** OpenAI port (e.g., 9111) proxies to `https://api.openai.com` and injects `Authorization: Bearer` header from host's `$OPENAI_API_KEY` env var.
- **D-04:** Fixed ports on guest side — all VMs use the same URLs (`http://10.0.2.2:9110`, `http://10.0.2.2:9111`). No per-VM port allocation needed.

### Auth Strategy
- **D-05:** Set dummy `ANTHROPIC_API_KEY=dummy` inside the guest so Claude Code starts and sends requests without real credentials. Proxy overwrites the `x-api-key` header with the real key.
- **D-06:** Same dummy approach for OpenAI: `OPENAI_API_KEY=dummy` in guest, proxy overwrites `Authorization: Bearer` header.
- **D-07:** OAuth sidecar process on the host for Pro/Max subscription users. Handles OAuth token acquisition and refresh. Shared across all airlocks (not per-VM).
- **D-08:** Anthropic API key required for basic operation. OpenAI API key optional (only needed for Codex users).

### Caddy Lifecycle
- **D-09:** `rl new` checks if Caddy is running. If not, starts it. Never stops Caddy on `rl rm` — it stays running for other/future airlocks.
- **D-10:** No per-repo PID management. Just detect whether Caddy is running (port check or process check) and start if needed.

### Guest Environment Setup
- **D-11:** Install `mise-en-place` inside the guest during provisioning (alongside tmux, git, bash).
- **D-12:** Generate `mise.toml` in the guest with fixed proxy URLs: `ANTHROPIC_BASE_URL=http://10.0.2.2:9110` and `OPENAI_BASE_URL=http://10.0.2.2:9111`.
- **D-13:** Set dummy API keys in `mise.toml` so agents start without real credentials: `ANTHROPIC_API_KEY=dummy`, `OPENAI_API_KEY=dummy`.

### Claude's Discretion
- Exact fixed port numbers (9110/9111 suggested but flexible)
- Caddy "is running" detection method (port probe vs `pgrep` vs `caddy status`)
- Caddyfile location on host (e.g., `~/.config/rl/Caddyfile` or similar)
- OAuth sidecar implementation details (process management, token storage location)
- `mise.toml` placement in guest (`/root/` vs `/root/repo/` vs `/etc/`)
- Whether `check_all_deps` validates Caddy at CLI startup or only when needed

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Caddy Configuration
- `CLAUDE.md` §Caddy Configuration Pattern — `header_up` directive syntax, `{env.*}` placeholders, `http://` prefix behavior
- `CLAUDE.md` §QEMU Networking Pattern — Guest IP (10.0.2.15), host gateway (10.0.2.2), DNS (10.0.2.3), SLIRP limitations

### Stack & Architecture
- `.planning/research/STACK.md` — Caddy 2.11.x, reverse proxy rationale, `header_up` vs alternatives
- `.planning/research/ARCHITECTURE.md` — CLI dispatch pattern, per-VM state dirs, integration points
- `.planning/research/PITFALLS.md` — Caddy remote_ip matcher with SLIRP (needs validation), SSH key management

### Security Requirements
- `.planning/REQUIREMENTS.md` §Security — SEC-01 (Caddy proxy), SEC-02 (guest env vars), SEC-03 (no keys in VM)

### Prior Phase
- `.planning/phases/01-cli-skeleton-and-vm-lifecycle/01-CONTEXT.md` — D-02 (`.rl/` state dir), D-11 (dependency error hints)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/vm.sh:cmd_new()` — VM creation flow where Caddy start logic hooks in (after `aq new`, before or after provisioning)
- `lib/vm.sh:cmd_rm()` — VM destruction flow (no Caddy stop needed per D-09, but could log proxy status)
- `lib/util.sh:check_all_deps()` — Dependency checker where Caddy check should be added
- `lib/util.sh:ensure_rl_dir()` — `.rl/` directory setup, pattern for adding Caddy state if needed
- `lib/ui.sh:spinner_start/spinner_stop` — Progress indicators for Caddy startup

### Established Patterns
- Case-statement dispatch in `rl` — new Caddy-related logic integrates into existing `cmd_new`
- `aq exec "$vm_name" <<'HEREDOC'` — Pattern for running provisioning commands inside guest (used for installing mise, generating mise.toml)
- ShellCheck-clean Bash 5.x — all new code must pass `shellcheck --severity=warning`

### Integration Points
- `cmd_new()` provisioning block — add mise install and mise.toml generation
- `cmd_new()` before provisioning — add Caddy "ensure running" check
- `check_all_deps()` — add `check_dependency "caddy" "brew install caddy"`
- Guest provisioning — `apk add` needs mise package (or install via curl from mise.jdx.dev)

</code_context>

<specifics>
## Specific Ideas

- Anthropic API uses `x-api-key` header (not `Authorization: Bearer`) — Caddy config must use different header directives per port
- Claude Code Pro/Max subscriptions use OAuth tokens, not API keys. The OAuth sidecar handles this transparently — guest always sends dummy key, proxy/sidecar injects the real credential regardless of auth method
- STATE.md flagged: "Caddy remote_ip matcher with QEMU SLIRP: Source IP matching needs validation with actual SLIRP traffic" — research should verify whether `remote_ip` matcher works with SLIRP NAT

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-security-boundary*
*Context gathered: 2026-03-26*
