# Phase 3: Agent Provisioning - Context

**Gathered:** 2026-03-28
**Status:** Ready for planning

<domain>
## Phase Boundary

Claude Code and Codex are installed and functional inside the VM, routing API calls through the host Caddy proxy. Agent selection is user-controlled — only requested agents are installed. ANTHROPIC_BASE_URL and OPENAI_BASE_URL are already configured by Phase 2 (mise.toml with proxy URLs and dummy keys).

</domain>

<decisions>
## Implementation Decisions

### Agent Selection
- **D-01:** No agents installed by default. User specifies which agents to install with `rl new --agent claude` and/or `rl new --agent codex`. Multiple `--agent` flags allowed.
- **D-02:** Detect corresponding binaries on the host (`claude`, `codex`) to validate the user's choice. If the user requests an agent whose binary isn't on the host, warn (the proxy won't have credentials to inject) but don't block.
- **D-03:** Agent installation happens during the provisioning step of `rl new`, after base packages and mise setup.

### Claude Code Installation
- **D-04:** Install via `npm install -g @anthropic-ai/claude-code` inside the guest. Requires `nodejs` and `npm` from Alpine repos (already tested: Node.js 22, works on musl without glibc compat).
- **D-05:** Additional Alpine packages needed: `libgcc`, `libstdc++` (native deps for Claude Code's Node modules).
- **D-06:** Claude Code accepts `ANTHROPIC_API_KEY=dummy` without prompting for auth. No interactive setup needed — it just works with the dummy key + proxy.
- **D-07:** Use `--dangerously-skip-permissions` flag when running Claude Code inside the VM. The VM IS the sandbox — permission checks inside it are redundant.

### Codex Installation
- **D-08:** Codex installation is optional and deferred until a host with `codex` binary is available for testing. The proxy port (9111) and mise env vars (`OPENAI_BASE_URL`, `OPENAI_API_KEY=dummy`) are already configured by Phase 2.
- **D-09:** When implemented, install via npm or binary (TBD — musl compatibility needs testing). Same pattern as Claude Code.

### Claude's Discretion
- Exact `npm install` flags and caching strategy
- Whether to pin Claude Code version or use latest
- Order of package installation within provisioning
- Whether `--dangerously-skip-permissions` is set via env var, config file, or CLI wrapper

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 2 artifacts (proxy + env already configured)
- `.planning/phases/02-security-boundary/02-CONTEXT.md` — D-12 (mise.toml with proxy URLs), D-13 (dummy API keys)
- `lib/proxy.sh` — Caddy proxy module, `request_header` directive for key injection
- `lib/creds.sh` — Credential store, OAuth import from keychain

### Agent requirements
- `.planning/REQUIREMENTS.md` §Agent Setup — AGENT-01 (Claude Code functional), AGENT-02 (Codex functional)

### Stack
- `CLAUDE.md` §Guest Packages — nodejs, npm, curl, bash required for Claude Code
- `CLAUDE.md` §AI Agent Configuration — ANTHROPIC_BASE_URL, OPENAI_BASE_URL env var names
- `.planning/research/STACK.md` — Alpine 3.22, Node.js 22.x from main repos

### Existing provisioning
- `lib/vm.sh` — Current provisioning heredoc in `cmd_new()` (line 104-137)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/vm.sh:cmd_new()` — Provisioning heredoc where agent installation hooks in (after base packages + mise)
- `lib/util.sh:check_dependency()` — Pattern for dependency validation (can check for host binaries)
- `lib/creds.sh:creds_resolve()` — Already provides credentials; proxy already configured

### Established Patterns
- Provisioning via `aq exec "$vm_name" <<'HEREDOC'` — single-shot script execution inside guest
- `spinner_start`/`spinner_stop` — Progress indication during slow operations
- `apk add --no-cache` — Alpine package installation pattern
- `npm install -g` — Global npm package installation (tested: works on Alpine musl)

### Integration Points
- `cmd_new()` argument parsing — needs `--agent` flag handling
- Provisioning heredoc — needs conditional agent installation blocks
- `cmd_help()` — needs updated help text showing `--agent` flag
- `bin/rl` dispatch — `new` case already sources all needed modules

</code_context>

<specifics>
## Specific Ideas

- Claude Code v2.1.85 confirmed working on Alpine 3.22 with musl (no glibc compat needed)
- `claude -p "say hi"` successfully routes through the Caddy proxy with dummy key + real key injection
- `--dangerously-skip-permissions` is specifically designed for sandboxed environments — the VM is exactly this use case
- The `--bare` flag on Claude Code skips hooks, LSP, auto-memory — might be useful for lightweight VM usage

</specifics>

<deferred>
## Deferred Ideas

- Codex installation and testing — needs a host with `codex` binary for end-to-end validation
- Agent version pinning — install latest for now, pin when stability matters
- `rl new --config claude` — copying host Claude Code config into VM (USE-01, v2 requirement)

</deferred>

---

*Phase: 03-agent-provisioning*
*Context gathered: 2026-03-28*
