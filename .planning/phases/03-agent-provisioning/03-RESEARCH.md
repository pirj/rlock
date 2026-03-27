# Phase 3: Agent Provisioning - Research

**Researched:** 2026-03-28
**Domain:** AI agent installation and configuration inside Alpine Linux QEMU VMs
**Confidence:** HIGH

## Summary

This phase adds conditional installation of Claude Code and Codex CLI inside guest VMs during `rl new` provisioning. The user specifies which agents to install via `--agent claude` and/or `--agent codex` flags. Agent installation hooks into the existing provisioning heredoc in `lib/vm.sh:cmd_new()`, running after base packages and mise setup (Phase 2).

Claude Code installs via `npm install -g @anthropic-ai/claude-code` and is confirmed working on Alpine musl (v2.1.85 tested, v2.1.86 current). It accepts `ANTHROPIC_API_KEY=dummy` without auth prompts, and `--dangerously-skip-permissions` (equivalent to `--permission-mode bypassPermissions`) is the correct flag for VM-sandboxed environments. Codex CLI installs via `npm install -g @openai/codex` (v0.117.0 current) and ships musl-compatible Linux binaries, but the `codex` binary is not installed on the current host machine, so end-to-end proxy validation is deferred per CONTEXT.md D-08.

**Primary recommendation:** Add `--agent` flag parsing to `cmd_new()`, create a `lib/agent.sh` module with `install_claude_code()` and `install_codex()` functions, and call them conditionally from the provisioning heredoc. Validate host binary presence with `check_dependency` to warn users when the proxy lacks credentials for the requested agent.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** No agents installed by default. User specifies which agents to install with `rl new --agent claude` and/or `rl new --agent codex`. Multiple `--agent` flags allowed.
- **D-02:** Detect corresponding binaries on the host (`claude`, `codex`) to validate the user's choice. If the user requests an agent whose binary isn't on the host, warn (the proxy won't have credentials to inject) but don't block.
- **D-03:** Agent installation happens during the provisioning step of `rl new`, after base packages and mise setup.
- **D-04:** Install via `npm install -g @anthropic-ai/claude-code` inside the guest. Requires `nodejs` and `npm` from Alpine repos (already tested: Node.js 22, works on musl without glibc compat).
- **D-05:** Additional Alpine packages needed: `libgcc`, `libstdc++` (native deps for Claude Code's Node modules).
- **D-06:** Claude Code accepts `ANTHROPIC_API_KEY=dummy` without prompting for auth. No interactive setup needed -- it just works with the dummy key + proxy.
- **D-07:** Use `--dangerously-skip-permissions` flag when running Claude Code inside the VM. The VM IS the sandbox -- permission checks inside it are redundant.
- **D-08:** Codex installation is optional and deferred until a host with `codex` binary is available for testing. The proxy port (9111) and mise env vars (`OPENAI_BASE_URL`, `OPENAI_API_KEY=dummy`) are already configured by Phase 2.
- **D-09:** When implemented, install via npm or binary (TBD -- musl compatibility needs testing). Same pattern as Claude Code.

### Claude's Discretion
- Exact `npm install` flags and caching strategy
- Whether to pin Claude Code version or use latest
- Order of package installation within provisioning
- Whether `--dangerously-skip-permissions` is set via env var, config file, or CLI wrapper

### Deferred Ideas (OUT OF SCOPE)
- Codex installation and testing -- needs a host with `codex` binary for end-to-end validation
- Agent version pinning -- install latest for now, pin when stability matters
- `rl new --config claude` -- copying host Claude Code config into VM (USE-01, v2 requirement)
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AGENT-01 | Claude Code is pre-installed and functional inside the VM | Install via `npm install -g @anthropic-ai/claude-code` with `nodejs`, `npm`, `libgcc`, `libstdc++` packages. Uses `ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY=dummy` from mise.toml (Phase 2). Verified working on Alpine 3.22 musl. |
| AGENT-02 | Codex is pre-installed and functional inside the VM | Install via `npm install -g @openai/codex` -- musl binaries confirmed available. Uses `OPENAI_BASE_URL` + `OPENAI_API_KEY=dummy` from mise.toml (Phase 2). Deferred per D-08 until host `codex` binary available for testing. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Shell script**: The `rl` tool is a bash script, not a compiled binary. All new code must be Bash 5.x compatible.
- **ShellCheck**: All code must pass `shellcheck --severity=warning`. Use `# shellcheck shell=bash` directive in sourced files.
- **VM engine**: QEMU via pirj/aq -- no Docker, no containers.
- **Guest OS**: Alpine Linux (musl libc, apk package manager).
- **No keys in VM**: API keys never enter the VM. Guest uses dummy keys; Caddy proxy injects real credentials.
- **Dependencies**: aq, Caddy, and git required on host.
- **Argument parsing**: Use `while/case/shift` loop (no `getopts`).

## Standard Stack

### Core (Inside Guest VM)
| Package | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `@anthropic-ai/claude-code` | 2.1.86 (npm latest) | Claude Code CLI agent | Official Anthropic package. Confirmed working on Alpine musl with Node.js 22. |
| `@openai/codex` | 0.117.0 (npm latest) | Codex CLI agent | Official OpenAI package. Ships musl-compatible Linux binaries. |
| `nodejs` | 22.x (Alpine 3.22 repos) | Node.js runtime for both agents | Required by both Claude Code and Codex. Alpine main repos ship 22.x. |
| `npm` | (bundled with nodejs) | Package manager for agent installation | Standard npm global install for both agents. |

### Supporting (Alpine apk packages for Claude Code)
| Package | Purpose | When to Use |
|---------|---------|-------------|
| `libgcc` | GCC runtime library (native module deps) | Always, when installing Claude Code |
| `libstdc++` | C++ standard library (native module deps) | Always, when installing Claude Code |

### Host-Side (Validation Only)
| Binary | Purpose | When to Check |
|--------|---------|---------------|
| `claude` | Host Claude Code binary | During `rl new --agent claude` -- warn if missing |
| `codex` | Host Codex binary | During `rl new --agent codex` -- warn if missing |

**Installation (inside guest provisioning heredoc):**
```bash
# Claude Code agent packages
apk add --no-cache nodejs npm libgcc libstdc++
npm install -g @anthropic-ai/claude-code

# Codex agent packages (when implemented)
apk add --no-cache nodejs npm
npm install -g @openai/codex
```

**Version verification:** Versions confirmed against npm registry on 2026-03-28.
- `npm view @anthropic-ai/claude-code version` -> 2.1.86
- `npm view @openai/codex version` -> 0.117.0

## Architecture Patterns

### Recommended Module Structure
```
lib/
  agent.sh          # NEW: Agent installation functions
  vm.sh             # MODIFIED: --agent flag parsing in cmd_new()
  util.sh           # EXISTING: check_dependency() for host binary validation
  proxy.sh          # EXISTING: unchanged
  creds.sh          # EXISTING: unchanged
bin/
  rl                # MODIFIED: help text update for --agent flag
```

### Pattern 1: Conditional Agent Installation via Flag Accumulation
**What:** Parse `--agent <name>` flags into a bash array, then iterate to install each requested agent after base provisioning.
**When to use:** Every `rl new` invocation with agent flags.
**Example:**
```bash
# In cmd_new() -- argument parsing
local agents=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)
            [[ -z "${2:-}" ]] && die "--agent requires a value (claude, codex)"
            case "$2" in
                claude|codex) agents+=("$2") ;;
                *) die "Unknown agent '$2'. Use 'claude' or 'codex'." ;;
            esac
            shift 2
            ;;
        *)
            die "Unknown option '$1'."
            ;;
    esac
done
```

### Pattern 2: Host Binary Validation with Warning
**What:** Check if the corresponding agent binary exists on the host before installing in guest. Warn (not block) if missing, since the proxy won't have credentials.
**When to use:** Before each agent installation step.
**Example:**
```bash
# Source: CONTEXT.md D-02
validate_agent_host() {
    local agent="$1"
    case "$agent" in
        claude)
            if ! command -v claude >/dev/null 2>&1; then
                warn "claude not found on host. The proxy may lack Anthropic credentials."
                warn "Run 'rl auth anthropic' to configure credentials."
            fi
            ;;
        codex)
            if ! command -v codex >/dev/null 2>&1; then
                warn "codex not found on host. The proxy may lack OpenAI credentials."
                warn "Run 'rl auth openai' to configure credentials."
            fi
            ;;
    esac
}
```

### Pattern 3: Provisioning Heredoc with Conditional Blocks
**What:** Build the provisioning script dynamically based on requested agents, or use a two-phase approach: base provisioning (existing heredoc) then agent-specific provisioning (separate `aq exec` calls).
**When to use:** During `rl new` provisioning.
**Recommendation:** Use separate `aq exec` calls per agent rather than one monolithic heredoc. This keeps the base provisioning clean, makes agent installation independently testable, and allows better error reporting per agent.
**Example:**
```bash
# After base provisioning succeeds
for agent in "${agents[@]}"; do
    spinner_start "Installing $agent"
    local install_output
    install_output=$(install_agent_in_guest "$vm_name" "$agent")
    if ! echo "$install_output" | grep -q "AGENT_OK"; then
        spinner_stop "Failed"
        warn "Failed to install $agent. VM is usable without it."
    else
        spinner_stop "$agent installed"
    fi
done
```

### Pattern 4: --dangerously-skip-permissions via Settings File
**What:** Configure Claude Code to always bypass permissions by writing a `settings.json` file during provisioning, rather than requiring the flag on every invocation.
**When to use:** Inside the guest VM provisioning for Claude Code.
**Recommendation:** Use a settings.json file at `~/.claude/settings.json` so the setting persists across all Claude Code invocations inside the VM. This is cleaner than wrapping the `claude` binary or requiring users to remember the flag.
**Example:**
```bash
# During Claude Code provisioning inside guest
mkdir -p /root/.claude
cat > /root/.claude/settings.json <<'SETTINGS'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
SETTINGS
```
**Alternative:** A shell alias or wrapper script:
```bash
# Alternative: alias in .bashrc
echo 'alias claude="claude --dangerously-skip-permissions"' >> /root/.bashrc
```
The settings.json approach is preferred because it works for both interactive and non-interactive invocations without relying on alias expansion.

### Anti-Patterns to Avoid
- **Monolithic provisioning heredoc:** Don't stuff agent installation into the existing base provisioning heredoc. Separate concerns -- base packages are always installed, agents are conditional.
- **Blocking on missing host binary:** D-02 says warn but don't block. The user may have configured credentials via `rl auth` without having the agent binary locally.
- **Pinning to a specific npm version:** D-08 defers version pinning. Use `npm install -g @anthropic-ai/claude-code` (latest) for now.
- **Installing nodejs/npm unconditionally:** Only install these when an agent is requested. They're not needed for base VM functionality.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Permission bypass in VM | Custom permission shim or wrapper | `settings.json` with `"defaultMode": "bypassPermissions"` | Official Claude Code mechanism. Survives updates, works for all invocation styles. |
| Agent package management | Custom download/build from source | `npm install -g` | Both agents are npm packages. npm handles platform detection and musl binary selection automatically. |
| Environment variable injection | Custom env setup scripts | mise.toml (already configured by Phase 2) | `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, and dummy keys are already in `/root/mise.toml` from Phase 2 provisioning. |
| Config file for Codex | Custom config generation | `~/.codex/config.toml` with `openai_base_url` | Official Codex configuration mechanism. Supplements env vars for provider-specific settings. |

**Key insight:** Phase 2 already configured the environment variables (mise.toml) and proxy (Caddy). This phase only needs to install the agent binaries and set their permission modes. The infrastructure is already in place.

## Common Pitfalls

### Pitfall 1: Node.js Not Installed When No Agent Requested
**What goes wrong:** If `nodejs` and `npm` are installed unconditionally during base provisioning, every VM pays the ~30s npm install overhead even when no agent is requested.
**Why it happens:** Temptation to simplify provisioning by always installing Node.js.
**How to avoid:** Only install `nodejs`, `npm`, `libgcc`, `libstdc++` when at least one agent is requested. These are agent dependencies, not base VM dependencies.
**Warning signs:** Slow `rl new` times for users who don't need agents.

### Pitfall 2: npm Install Timeout Inside QEMU
**What goes wrong:** `npm install -g` inside QEMU with user-mode networking (SLIRP) can be slow due to NAT overhead. Default npm timeouts may not be sufficient.
**Why it happens:** SLIRP networking adds latency. npm registry DNS resolution goes through QEMU's DNS proxy (10.0.2.3).
**How to avoid:** Use `npm install -g --prefer-online` and consider `--maxsockets 3` to reduce connection overhead. If timeouts occur, the spinner gives users feedback that something is happening.
**Warning signs:** `npm ERR! network timeout` during provisioning.

### Pitfall 3: Claude Code Auth Prompt on First Run
**What goes wrong:** Without `ANTHROPIC_API_KEY` set, Claude Code prompts interactively for authentication on first run, which hangs in non-interactive provisioning.
**Why it happens:** Claude Code's default flow expects interactive login.
**How to avoid:** Phase 2 already sets `ANTHROPIC_API_KEY=dummy` in mise.toml. Verify that mise is activated in the shell before running Claude Code. The `eval "$(mise activate bash)"` in `.bashrc` handles this for interactive sessions; for provisioning validation, source mise explicitly.
**Warning signs:** Provisioning hangs at "Waiting for authentication..."

### Pitfall 4: --dangerously-skip-permissions Not Persisted
**What goes wrong:** Users SSH into the VM, run `claude`, and get permission prompts because the flag wasn't configured persistently.
**Why it happens:** `--dangerously-skip-permissions` is a CLI flag, not a persistent setting, so it must be passed every time unless configured in settings.json.
**How to avoid:** Write `~/.claude/settings.json` with `"defaultMode": "bypassPermissions"` during provisioning. This persists the setting for all future Claude Code invocations.
**Warning signs:** Users report being asked for permissions inside the VM.

### Pitfall 5: Codex config.toml vs Environment Variables
**What goes wrong:** `OPENAI_BASE_URL` from mise.toml might not be picked up by Codex if it prefers config.toml settings.
**Why it happens:** Codex has its own config hierarchy: CLI flags > env vars > config.toml. But `openai_base_url` in config.toml takes a different format than the env var.
**How to avoid:** Set both the env var (via mise.toml, already done) and optionally write `~/.codex/config.toml` with `openai_base_url`. The env var should work, but having config.toml as backup ensures coverage.
**Warning signs:** Codex tries to connect to `api.openai.com` directly instead of through the proxy.

### Pitfall 6: npm Cache Fills Disk in Constrained VM
**What goes wrong:** npm caches downloaded packages in `~/.npm/_cacache`. On a 1GB qcow2 disk, this wastes precious space.
**Why it happens:** npm caches by default and Claude Code is ~50MB+ installed.
**How to avoid:** Use `npm install -g --cache /tmp/npm-cache` during provisioning, then `rm -rf /tmp/npm-cache` afterward. The cache is useless in an ephemeral VM.
**Warning signs:** Disk space warnings during provisioning or later agent use.

## Code Examples

### Complete Claude Code Installation Function (for lib/agent.sh)
```bash
# Source: Claude Code docs, CONTEXT.md D-04/D-05/D-06/D-07
install_claude_code_in_guest() {
    local vm_name="$1"
    local output
    output=$(aq exec "$vm_name" <<'PROVISION_CLAUDE'
set -e

# Install Node.js, npm, and native deps (D-04, D-05)
apk add --no-cache nodejs npm libgcc libstdc++

# Install Claude Code globally, discard npm cache (Pitfall 6)
npm install -g @anthropic-ai/claude-code --cache /tmp/npm-cache
rm -rf /tmp/npm-cache

# Configure bypassPermissions mode persistently (D-07)
mkdir -p /root/.claude
cat > /root/.claude/settings.json <<'SETTINGS'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
SETTINGS

# Verify installation
claude --version >/dev/null 2>&1 || exit 1

echo "AGENT_OK"
PROVISION_CLAUDE
    )
    echo "$output"
}
```

### Complete Codex Installation Function (stub for future use)
```bash
# Source: Codex CLI docs, CONTEXT.md D-08/D-09
install_codex_in_guest() {
    local vm_name="$1"
    local output
    output=$(aq exec "$vm_name" <<'PROVISION_CODEX'
set -e

# Node.js may already be installed (if Claude Code was also requested)
apk add --no-cache nodejs npm

# Install Codex CLI globally (musl binary auto-selected by npm)
npm install -g @openai/codex --cache /tmp/npm-cache
rm -rf /tmp/npm-cache

# Optional: write config.toml for base URL (belt-and-suspenders with mise env var)
mkdir -p /root/.codex
cat > /root/.codex/config.toml <<'CODEXCFG'
openai_base_url = "http://10.0.2.2:9111/v1"
CODEXCFG

# Verify installation
codex --version >/dev/null 2>&1 || exit 1

echo "AGENT_OK"
PROVISION_CODEX
    )
    echo "$output"
}
```

### Argument Parsing for --agent flag in cmd_new()
```bash
# Source: CLAUDE.md argument parsing conventions (while/case/shift)
cmd_new() {
    local agents=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent)
                [[ -z "${2:-}" ]] && die "--agent requires a value (claude, codex)"
                case "$2" in
                    claude|codex) agents+=("$2") ;;
                    *) die "Unknown agent '$2'. Use 'claude' or 'codex'." ;;
                esac
                shift 2
                ;;
            --help|-h)
                cat <<'EOF'
usage: rl new [--agent <name>]...

Create a new isolated VM for the current repo.

options:
  --agent <name>   Install an AI agent (claude, codex). Can be repeated.

examples:
  rl new --agent claude
  rl new --agent claude --agent codex
  rl new
EOF
                return 0
                ;;
            *)
                die "Unknown option '$1'. Run 'rl new --help' for usage."
                ;;
        esac
    done

    # ... existing cmd_new() body ...

    # After base provisioning, install requested agents
    for agent in "${agents[@]}"; do
        validate_agent_host "$agent"
        spinner_start "Installing $agent"
        local install_output
        case "$agent" in
            claude) install_output=$(install_claude_code_in_guest "$vm_name") ;;
            codex)  install_output=$(install_codex_in_guest "$vm_name") ;;
        esac
        if echo "$install_output" | grep -q "AGENT_OK"; then
            spinner_stop "$agent installed"
        else
            spinner_stop "Failed"
            warn "Failed to install $agent. VM is usable without it."
        fi
    done
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `--dangerously-skip-permissions` CLI flag only | `--permission-mode bypassPermissions` + settings.json `"defaultMode": "bypassPermissions"` | Claude Code ~2.1.x (2026) | Can now persist bypass via config file instead of requiring CLI flag every time |
| Claude Code interactive auth required | `ANTHROPIC_API_KEY` env var skips auth prompt | Stable since v1.x | Enables fully non-interactive installation and first-run |
| Codex required glibc | Codex ships musl-compatible Linux binaries | v0.100+ (2026) | Alpine Linux (musl) is now a supported platform for Codex CLI |
| `--dangerously-skip-permissions` was the only no-prompt mode | Auto mode (`--permission-mode auto`) added as middle ground | March 2026 | Auto mode uses classifier for safety -- but bypassPermissions remains correct for VM sandbox use case |

**Deprecated/outdated:**
- `ANTHROPIC_SMALL_FAST_MODEL` env var: deprecated in favor of `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `--on-failure` approval policy in Codex: deprecated

## Open Questions

1. **Codex musl end-to-end validation**
   - What we know: Codex ships musl binaries (`codex-x86_64-unknown-linux-musl`), npm should auto-select the right binary.
   - What's unclear: Whether Codex fully functions on Alpine with QEMU SLIRP networking and the proxy setup. No host `codex` binary exists for testing.
   - Recommendation: Implement the installation function now (it's straightforward npm install), but mark AGENT-02 as partially complete until e2e testing is possible. Per D-08, this is explicitly deferred.

2. **Claude Code ANTHROPIC_BASE_URL path requirements**
   - What we know: Phase 2 sets `ANTHROPIC_BASE_URL=http://10.0.2.2:9110` in mise.toml. Claude Code docs say this overrides the API endpoint.
   - What's unclear: Whether Claude Code appends `/v1/messages` automatically or expects it in the base URL.
   - Recommendation: The CONTEXT.md notes that `claude -p "say hi"` was tested successfully with `http://10.0.2.2:9110` (no path suffix), confirming Claude Code appends the path automatically. HIGH confidence this is resolved.

3. **nodejs/npm conditional vs unconditional installation**
   - What we know: Currently `nodejs` and `npm` are listed as conditional packages (only when `--agent` is used).
   - What's unclear: Whether future phases (e.g., Code Bridge) might need Node.js for other tools.
   - Recommendation: Keep them conditional for now. If a future phase needs Node.js, it can add it to base provisioning then.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| `claude` (host) | Host binary validation (D-02) | Yes | 2.1.81 | Warn only -- not blocking |
| `codex` (host) | Host binary validation (D-02) | No | -- | Warn only -- not blocking. Codex installation deferred (D-08) |
| `npm` (host) | Version checks during research | Yes | (via node) | -- |
| `shellcheck` (host) | Code quality enforcement | Yes | 0.11.0 | -- |
| `shfmt` (host) | Code formatting | No | -- | Not blocking -- optional tool |
| `bats` (host) | Test framework | No | -- | Not blocking -- no tests required by nyquist_validation=false |

**Missing dependencies with no fallback:**
- None -- all missing items are non-blocking.

**Missing dependencies with fallback:**
- `codex` on host: Installation function can be written and tested structurally, but e2e validation deferred per D-08.
- `shfmt`: Not required. Code style can be maintained manually.
- `bats`: Not required. nyquist_validation is disabled.

## Sources

### Primary (HIGH confidence)
- [Claude Code Permission Modes](https://code.claude.com/docs/en/permission-modes) - `--dangerously-skip-permissions` equals `--permission-mode bypassPermissions`, settings.json configuration for persistent bypass
- [Claude Code Environment Variables](https://code.claude.com/docs/en/env-vars) - Full env var reference including `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY` behavior
- [Claude Code Network Configuration](https://code.claude.com/docs/en/network-config) - `ANTHROPIC_BASE_URL` proxy setup, custom CA, mTLS
- [Codex Advanced Configuration](https://developers.openai.com/codex/config-advanced) - `openai_base_url` in config.toml, model providers, sandbox modes
- [Codex CLI Reference](https://developers.openai.com/codex/cli/reference) - `--dangerously-bypass-approvals-and-sandbox` (alias `--yolo`), `--ask-for-approval`, `--sandbox` flags
- npm registry: `@anthropic-ai/claude-code` v2.1.86, `@openai/codex` v0.117.0 (verified 2026-03-28)

### Secondary (MEDIUM confidence)
- [Codex CLI Installation](https://developers.openai.com/codex/cli) - macOS and Linux support confirmed, Node.js 18+ required
- [Codex Quickstart](https://developers.openai.com/codex/quickstart) - Installation via npm, authentication flow
- WebSearch: Codex ships musl-compatible Linux binaries (`codex-x86_64-unknown-linux-musl`) -- multiple sources confirm

### Tertiary (LOW confidence)
- None -- all findings verified against official documentation.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Versions verified against npm registry, Alpine package repos confirmed in prior phase testing
- Architecture: HIGH - Extends well-understood existing patterns (aq exec heredoc, while/case/shift parsing, check_dependency)
- Pitfalls: HIGH - Key pitfalls (auth prompt, disk cache, permissions persistence) identified from official docs and experimental validation noted in CONTEXT.md
- Codex musl compatibility: MEDIUM - Multiple sources confirm musl binaries exist, but no hands-on testing done (deferred per D-08)

**Research date:** 2026-03-28
**Valid until:** 2026-04-28 (30 days -- both agents update frequently but core installation patterns are stable)
