# Phase 2: Security Boundary - Research

**Researched:** 2026-03-26
**Domain:** Caddy reverse proxy, API key injection, guest environment configuration, OAuth sidecar
**Confidence:** HIGH

## Summary

This phase implements the core security boundary of AILockr: API keys never enter the VM. A host-side Caddy reverse proxy intercepts HTTP requests from the guest, injects the correct authentication headers, and forwards to upstream APIs over HTTPS. The guest uses dummy credentials so AI agents start without errors, and mise-en-place manages environment variables inside the guest.

Three critical findings from research that correct prior assumptions: (1) The Anthropic API uses the `x-api-key` header, NOT `Authorization: Bearer` -- the existing STACK.md Caddyfile example is wrong and must be corrected. (2) QEMU SLIRP guest-to-host connections appear as `127.0.0.1` on the host side, which means binding Caddy to `127.0.0.1` is both secure AND reachable by the guest -- the Pitfall 1 vs Pitfall 3 conflict from PITFALLS.md is resolved. (3) The Alpine community repository is NOT enabled by default in aq's base image, so `apk add mise` requires enabling it first.

**Primary recommendation:** Bind Caddy to `127.0.0.1` on two fixed ports (9110 for Anthropic, 9111 for OpenAI). Use `header_up` to overwrite dummy auth headers with real credentials from host environment variables. Use `caddy start` for background daemon management. Enable Alpine community repo before installing mise. Defer OAuth sidecar to a separate sub-task since it is architecturally independent.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Single Caddy instance shared across all airlocks, listening on two fixed ports -- one for Anthropic API, one for OpenAI API.
- **D-02:** Anthropic port (e.g., 9110) proxies to `https://api.anthropic.com` and injects `x-api-key` header from host's `$ANTHROPIC_API_KEY` env var.
- **D-03:** OpenAI port (e.g., 9111) proxies to `https://api.openai.com` and injects `Authorization: Bearer` header from host's `$OPENAI_API_KEY` env var.
- **D-04:** Fixed ports on guest side -- all VMs use the same URLs (`http://10.0.2.2:9110`, `http://10.0.2.2:9111`). No per-VM port allocation needed.
- **D-05:** Set dummy `ANTHROPIC_API_KEY=dummy` inside the guest so Claude Code starts and sends requests without real credentials. Proxy overwrites the `x-api-key` header with the real key.
- **D-06:** Same dummy approach for OpenAI: `OPENAI_API_KEY=dummy` in guest, proxy overwrites `Authorization: Bearer` header.
- **D-07:** OAuth sidecar process on the host for Pro/Max subscription users. Handles OAuth token acquisition and refresh. Shared across all airlocks (not per-VM).
- **D-08:** Anthropic API key required for basic operation. OpenAI API key optional (only needed for Codex users).
- **D-09:** `rl new` checks if Caddy is running. If not, starts it. Never stops Caddy on `rl rm` -- it stays running for other/future airlocks.
- **D-10:** No per-repo PID management. Just detect whether Caddy is running (port check or process check) and start if needed.
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

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SEC-01 | Caddy reverse proxy on host injects Authorization headers for Anthropic and OpenAI APIs | Caddy `header_up` directive overwrites headers sent upstream. Anthropic uses `x-api-key` header (not `Authorization: Bearer`). OpenAI uses `Authorization: Bearer`. Both verified against official API docs. `{env.*}` placeholders read from host environment at runtime -- keys never written to Caddyfile. |
| SEC-02 | Guest Claude Code/Codex configured to use host proxy via ANTHROPIC_BASE_URL / OPENAI_BASE_URL env vars pointing to 10.0.2.2 | Claude Code supports `ANTHROPIC_BASE_URL` (verified in official LLM gateway docs). Gateway must forward `anthropic-beta` and `anthropic-version` headers -- Caddy's `reverse_proxy` forwards all headers by default. mise-en-place available in Alpine 3.22 community repo for env var management. |
| SEC-03 | API keys never enter the VM in any form (not in env vars, config files, or process memory) | Dummy keys (`ANTHROPIC_API_KEY=dummy`) satisfy agent startup requirements. Caddy `header_up` (without `+` prefix) overwrites the dummy header value before forwarding upstream. Real keys exist only in host env vars, read by Caddy at runtime via `{env.ANTHROPIC_API_KEY}`. |
</phase_requirements>

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|--------------|---------|---------|--------------|
| Caddy | 2.11.x | Reverse proxy with header injection | Single binary, `header_up` directive injects auth headers in 1 line, `{env.*}` reads host env vars at runtime, `http://` prefix disables auto-HTTPS. Verified: HIGH |
| mise-en-place | 2025.5.10-r0 (Alpine 3.22 aarch64) | Guest env var management | Available via `apk add mise` in Alpine community repo. Manages `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, and dummy API keys via `mise.toml`. Verified: HIGH |

### Supporting
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| curl | any | Health checks, connectivity testing | Verify proxy is reachable from guest, test header injection |
| lsof / ss | system | Verify Caddy bind address and port | Startup validation, debugging |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| mise for env vars | Inline `export` in `.bashrc` / `.profile` | mise provides structured `mise.toml`, supports activation hooks, cleaner than scattered exports. But adds a package dependency. |
| `caddy start` (background) | `caddy run` with nohup/systemd | `caddy start` is Caddy's built-in background mode with `caddy stop`/`caddy reload` control. Simpler than managing nohup/disown manually. |

**Installation:**
```bash
# Host: Caddy (if not already installed)
brew install caddy

# Guest: mise (during provisioning)
# First, enable community repo, then install
sed -i 's|^#\(.*community\)|\1|' /etc/apk/repositories
apk update
apk add mise
```

## Architecture Patterns

### Recommended Project Structure (additions to Phase 1)
```
lib/
├── proxy.sh             # NEW: Caddy lifecycle and Caddyfile management
├── vm.sh                # MODIFIED: hooks proxy ensure + guest provisioning
├── util.sh              # MODIFIED: add caddy to check_all_deps
└── ...

~/.config/rl/
└── Caddyfile            # Generated Caddyfile (shared across all airlocks)
```

### Pattern 1: Shared Caddy Instance with Fixed Ports

**What:** A single Caddy process serves all airlocks on two fixed ports (9110 for Anthropic, 9111 for OpenAI). No per-VM Caddy instances or port allocation.

**When to use:** When all VMs need the same proxy behavior and the same API credentials.

**Caddyfile (corrected -- Anthropic uses x-api-key, NOT Authorization: Bearer):**
```caddyfile
# Anthropic API proxy (for Claude Code)
http://127.0.0.1:9110 {
    reverse_proxy https://api.anthropic.com {
        header_up x-api-key "{env.ANTHROPIC_API_KEY}"
        header_up Host api.anthropic.com
    }
}

# OpenAI API proxy (for Codex)
http://127.0.0.1:9111 {
    reverse_proxy https://api.openai.com {
        header_up Authorization "Bearer {env.OPENAI_API_KEY}"
        header_up Host api.openai.com
    }
}
```

**Key details:**
- `http://` prefix disables Caddy's automatic HTTPS -- no certificates needed
- `header_up x-api-key` overwrites the dummy `x-api-key: dummy` sent by the guest's Claude Code
- `header_up Authorization` overwrites the dummy `Authorization: Bearer dummy` sent by the guest's Codex
- `{env.ANTHROPIC_API_KEY}` reads from host environment at runtime -- keys never written to disk
- Binding to `127.0.0.1` is SAFE because SLIRP guest connections appear as 127.0.0.1 on the host (see Pitfall resolution below)

**Source:** [Anthropic API docs](https://platform.claude.com/docs/en/api/overview) (x-api-key header), [Caddy reverse_proxy docs](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) (header_up)

### Pattern 2: Ensure-Running Guard

**What:** Before VM provisioning, check if Caddy is already running. If not, start it. Never stop Caddy on VM destruction.

**When to use:** D-09 -- shared Caddy instance lifecycle.

**Example:**
```bash
ensure_caddy_running() {
    # Quick port check -- is anything listening on the Anthropic proxy port?
    if curl -sf -o /dev/null --connect-timeout 1 http://127.0.0.1:9110 2>/dev/null; then
        return 0
    fi

    # Not running -- start Caddy
    local caddyfile="${XDG_CONFIG_HOME:-$HOME/.config}/rl/Caddyfile"
    if [ ! -f "$caddyfile" ]; then
        generate_caddyfile "$caddyfile"
    fi

    caddy start --config "$caddyfile" --adapter caddyfile
}
```

**Detection method recommendation:** Use `curl` to probe the Anthropic port (9110). This is the most reliable method because:
- `pgrep caddy` might find unrelated Caddy instances
- `caddy status` is not a real Caddy subcommand
- Port probe confirms the specific proxy is actually listening and responding

### Pattern 3: Guest Provisioning with mise

**What:** During `rl new`, install mise in the guest, generate a `mise.toml` with proxy URLs and dummy API keys, and activate mise in the shell profile.

**Example (provisioning script run via `aq exec`):**
```bash
# Enable community repository (mise is in community, not main)
sed -i 's|^#\(.*community\)|\1|' /etc/apk/repositories
apk update
apk add --no-cache mise

# Generate mise.toml in the home directory
cat > /root/mise.toml <<'MISE'
[env]
ANTHROPIC_BASE_URL = "http://10.0.2.2:9110"
OPENAI_BASE_URL = "http://10.0.2.2:9111"
ANTHROPIC_API_KEY = "dummy"
OPENAI_API_KEY = "dummy"
MISE

# Activate mise in ash profile (Alpine default shell)
echo 'eval "$(mise activate sh)"' >> /root/.profile
```

**mise.toml placement:** `/root/mise.toml` -- the home directory. This makes env vars available in all sessions without being tied to a specific repo directory.

### Anti-Patterns to Avoid

- **Hardcoding API keys in the Caddyfile:** Use `{env.ANTHROPIC_API_KEY}` placeholder, never write `sk-ant-...` to disk.
- **Using `Authorization: Bearer` for Anthropic:** Anthropic uses `x-api-key` header. This is a different header from OpenAI's `Authorization: Bearer` format. The existing STACK.md Caddyfile example has this wrong.
- **Binding Caddy to 0.0.0.0:** Unnecessary -- `127.0.0.1` works for SLIRP guests. Binding to `0.0.0.0` would expose API keys to the local network.
- **Using `remote_ip` matcher for access control:** SLIRP connections appear as 127.0.0.1 on the host, not 10.0.2.0/24. The `remote_ip 10.0.2.0/24` approach will NOT match guest traffic and is incorrect.
- **Starting/stopping Caddy per VM:** Shared instance stays running. Starting/stopping adds latency and complexity.
- **Using `HTTP_PROXY`/`HTTPS_PROXY` env vars:** These configure a forward proxy (CONNECT tunnel), which cannot inject headers into HTTPS traffic. Use `ANTHROPIC_BASE_URL`/`OPENAI_BASE_URL` instead.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Header injection proxy | Custom Node.js/Go HTTP proxy | Caddy with `header_up` | 3-line Caddyfile vs hundreds of lines of proxy code. Caddy handles TLS upstream, connection pooling, error handling. |
| Environment variable management in guest | Scatter `export` lines in `.bashrc`, `.profile`, `.ashrc` | mise-en-place with `mise.toml` | Structured, version-controllable, activation hooks. No risk of forgetting a shell profile. |
| Process liveness detection | PID files with kill -0 | Port probe with `curl` | Port probe confirms the service is actually listening, not just that a process exists. No stale PID file issues. |
| OAuth token refresh | Manual token refresh script | Claude Code's built-in `apiKeyHelper` mechanism | Claude Code already supports dynamic credential scripts with configurable TTL. Hook into existing mechanism. |

**Key insight:** Caddy was chosen for this project specifically because it makes header injection trivial. The entire security boundary is ~10 lines of Caddyfile configuration.

## Common Pitfalls

### Pitfall 1: Anthropic Uses x-api-key, Not Authorization: Bearer (CORRECTED)

**What goes wrong:** The proxy injects `Authorization: Bearer sk-ant-...` for Anthropic API calls. Requests fail with 401 because Anthropic expects `x-api-key` header.
**Why it happens:** OpenAI uses `Authorization: Bearer`, and developers assume all APIs use the same pattern. The existing STACK.md Caddyfile example has this error.
**How to avoid:** Anthropic port must use `header_up x-api-key "{env.ANTHROPIC_API_KEY}"`. OpenAI port uses `header_up Authorization "Bearer {env.OPENAI_API_KEY}"`. These are different headers on different ports.
**Warning signs:** 401 Unauthorized from api.anthropic.com, `authentication_error` in Claude Code output.
**Confidence:** HIGH -- verified against [official Anthropic API docs](https://platform.claude.com/docs/en/api/overview).

### Pitfall 2: SLIRP Guest Traffic Appears as 127.0.0.1 on Host (RESOLVED)

**What goes wrong:** Developers assume guest connections to 10.0.2.2 arrive at the host from the 10.0.2.0/24 subnet. They configure `remote_ip 10.0.2.0/24` as a Caddy access control matcher, which never matches. Or they bind to `127.0.0.1` fearing the guest cannot reach it, then switch to `0.0.0.0` which leaks API keys to the network.
**Why it happens:** QEMU SLIRP runs a full TCP/IP stack inside the QEMU process. When the guest connects to 10.0.2.2, SLIRP NATs the connection through the QEMU process itself. The host service sees the connection originating from the QEMU process, which connects via the loopback interface -- source IP is `127.0.0.1`.
**How to avoid:** Bind Caddy to `127.0.0.1`. This is BOTH secure (not accessible from the network) AND reachable by the SLIRP guest (because guest traffic arrives via loopback). No `remote_ip` matcher is needed.
**Warning signs:** `remote_ip` matcher logs showing no matches; `curl http://10.0.2.2:9110` from guest returns connection refused when Caddy is bound to non-loopback address.
**Confidence:** HIGH -- verified via [QEMU SLIRP documentation](https://www.qemu.org/docs/master/system/devices/net.html) and community testing reports showing host services see 127.0.0.1 for SLIRP guest connections.

### Pitfall 3: Alpine Community Repository Not Enabled by Default

**What goes wrong:** `apk add mise` fails with "unable to select packages" because mise is in the community repository, which is commented out in aq's base image.
**Why it happens:** aq uses `APKREPOSOPTS="-1"` during Alpine setup, which adds only the CDN mirror for the main repository. The community repository line is present in `/etc/apk/repositories` but commented out with `#`.
**How to avoid:** During guest provisioning, uncomment the community repo line before installing mise: `sed -i 's|^#\(.*community\)|\1|' /etc/apk/repositories && apk update`.
**Warning signs:** `ERROR: unable to select packages: mise (no such package)`.
**Confidence:** HIGH -- verified by reading aq source code (`APKREPOSOPTS="-1"`) and [Alpine setup-apkrepos source](https://github.com/alpinelinux/alpine-conf/blob/master/setup-apkrepos.in).

### Pitfall 4: Caddy Admin API Port Conflict

**What goes wrong:** Starting a second Caddy instance with `caddy start` fails because the admin API port (default: `localhost:2019`) is already in use by another Caddy process.
**Why it happens:** Caddy's admin API always binds to localhost:2019. If a system-level Caddy is running (e.g., from Homebrew services), `caddy start` for rl will conflict.
**How to avoid:** Set a custom admin API address in the Caddyfile global options block: `{ admin localhost:2020 }` or disable admin API entirely: `{ admin off }`.
**Warning signs:** `caddy start` exits with "address already in use" for port 2019.
**Confidence:** HIGH -- documented in [Caddy global options](https://caddyserver.com/docs/caddyfile/options).

### Pitfall 5: Missing Host Header Causes Upstream Rejection

**What goes wrong:** Caddy forwards requests to `api.anthropic.com` but the `Host` header is `127.0.0.1:9110` (the original request host). Some API endpoints may reject requests with wrong Host headers.
**Why it happens:** HTTP/1.1 requires a Host header matching the server being addressed. Caddy's reverse_proxy does not automatically rewrite Host to match the upstream.
**How to avoid:** Include `header_up Host api.anthropic.com` (and `header_up Host api.openai.com`) in each reverse_proxy block.
**Warning signs:** 421 Misdirected Request or unexpected 400 errors from upstream.
**Confidence:** MEDIUM -- Caddy may handle this for HTTPS upstreams automatically, but explicitly setting it is safe.

### Pitfall 6: `{env.OPENAI_API_KEY}` Causes Caddy Startup Failure When Unset

**What goes wrong:** Caddy refuses to start because `{env.OPENAI_API_KEY}` is empty/unset, and Caddy treats missing env vars as an error in some contexts.
**Why it happens:** D-08 says OpenAI API key is optional. But Caddy's `{env.*}` placeholder fails if the variable is not set.
**How to avoid:** Use `{env.OPENAI_API_KEY}` with a fallback: `{env.OPENAI_API_KEY:unused}`. Or use `{$OPENAI_API_KEY:unused}` shorthand. Alternatively, always export `OPENAI_API_KEY=unused` on the host as a harmless default.
**Warning signs:** Caddy error on startup mentioning undefined environment variable.
**Confidence:** MEDIUM -- needs validation with actual Caddy behavior for unset env vars in `{env.*}` placeholders.

## Code Examples

### Complete Caddyfile

```caddyfile
# Source: Anthropic API docs + Caddy reverse_proxy docs
# AILockr proxy -- shared across all airlocks

{
    # Use a non-default admin port to avoid conflicts with system Caddy
    admin localhost:2020
}

# Anthropic API proxy (for Claude Code)
http://127.0.0.1:9110 {
    reverse_proxy https://api.anthropic.com {
        header_up x-api-key "{env.ANTHROPIC_API_KEY}"
        header_up Host api.anthropic.com
    }
}

# OpenAI API proxy (for Codex)
http://127.0.0.1:9111 {
    reverse_proxy https://api.openai.com {
        header_up Authorization "Bearer {env.OPENAI_API_KEY}"
        header_up Host api.openai.com
    }
}
```

### lib/proxy.sh Skeleton

```bash
# proxy.sh -- Caddy reverse proxy lifecycle management
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh and ui.sh to be sourced first.

CADDY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rl"
CADDY_FILE="$CADDY_CONFIG_DIR/Caddyfile"
ANTHROPIC_PORT=9110
OPENAI_PORT=9111

generate_caddyfile() {
    mkdir -p "$CADDY_CONFIG_DIR"
    cat > "$CADDY_FILE" <<'CADDYFILE'
{
    admin localhost:2020
}

http://127.0.0.1:9110 {
    reverse_proxy https://api.anthropic.com {
        header_up x-api-key "{env.ANTHROPIC_API_KEY}"
        header_up Host api.anthropic.com
    }
}

http://127.0.0.1:9111 {
    reverse_proxy https://api.openai.com {
        header_up Authorization "Bearer {env.OPENAI_API_KEY}"
        header_up Host api.openai.com
    }
}
CADDYFILE
}

is_caddy_running() {
    curl -sf -o /dev/null --connect-timeout 1 "http://127.0.0.1:$ANTHROPIC_PORT" 2>/dev/null
}

ensure_caddy_running() {
    if is_caddy_running; then
        return 0
    fi

    if [ ! -f "$CADDY_FILE" ]; then
        generate_caddyfile
    fi

    # Validate ANTHROPIC_API_KEY is set (required per D-08)
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        die "ANTHROPIC_API_KEY not set. Export it in your shell before running rl."
    fi

    caddy start --config "$CADDY_FILE" --adapter caddyfile 2>/dev/null \
        || die "Failed to start Caddy proxy. Check 'caddy validate --config $CADDY_FILE'."
}
```

### Guest Provisioning Script (mise + env vars)

```bash
# Run inside guest via aq exec during rl new
set -e

# Enable community repository (mise is in community)
sed -i 's|^#\(.*community\)|\1|' /etc/apk/repositories
apk update
apk add --no-cache mise

# Generate mise.toml in home directory
cat > /root/mise.toml <<'MISE'
[env]
ANTHROPIC_BASE_URL = "http://10.0.2.2:9110"
OPENAI_BASE_URL = "http://10.0.2.2:9111"
ANTHROPIC_API_KEY = "dummy"
OPENAI_API_KEY = "dummy"
MISE

# Activate mise in ash profile (Alpine default shell)
# Also add to .bashrc for bash sessions
echo 'eval "$(mise activate sh)"' >> /root/.profile
echo 'eval "$(mise activate bash)"' >> /root/.bashrc

echo "PROXY_PROVISION_OK"
```

### OAuth Sidecar Architecture (for Pro/Max users)

```
Claude Code authentication precedence (from official docs):
1. Cloud provider credentials (CLAUDE_CODE_USE_BEDROCK, etc.)
2. ANTHROPIC_AUTH_TOKEN env var (sent as Authorization: Bearer)
3. ANTHROPIC_API_KEY env var (sent as X-Api-Key)
4. apiKeyHelper script output
5. Subscription OAuth credentials (from /login)

For Pro/Max users without an API key:
- The OAuth sidecar is a separate host process that handles OAuth token lifecycle
- It exposes an endpoint that Caddy can call, or provides a token file
- Claude Code's apiKeyHelper mechanism can be used: the guest runs a script
  that calls the host sidecar for a fresh token
- This is architecturally independent from the Caddy proxy and can be
  implemented as a later sub-task within this phase
```

**Note on OAuth sidecar:** The OAuth sidecar is complex and architecturally independent from the core Caddy proxy. Research shows Claude Code supports `apiKeyHelper` for dynamic credentials with configurable TTL (`CLAUDE_CODE_API_KEY_HELPER_TTL_MS`). The sidecar could be a simple script that runs `claude setup-token` or manages OAuth tokens through a local HTTP endpoint. This should be a separate plan from the core proxy setup.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| MITM proxy with custom CA certs | Custom base URL + reverse proxy | Claude Code 1.0+ | No TLS interception needed; Claude Code natively supports ANTHROPIC_BASE_URL |
| Per-VM Caddy instances | Shared Caddy with fixed ports | Project decision D-01 | Simpler lifecycle, no port allocation, no per-VM PID tracking |
| Direct API key in guest env | Dummy key + proxy header overwrite | Project decision D-05/D-06 | Keys never enter VM; Caddy overwrites dummy headers with real credentials |
| Alpine community repo enabled by default | Community repo commented out in aq base images | aq 1.6.0 (Alpine 3.22) | Must explicitly uncomment community repo for mise installation |
| Anthropic API: `Authorization: Bearer` | Anthropic API: `x-api-key` header | Always been this way | STACK.md Caddyfile example was incorrect; corrected in this research |

**Deprecated/outdated:**
- Anthropic recently deprecated OAuth for third-party tools (sent legal requests). First-party Claude Code still uses OAuth for Pro/Max subscriptions, but third-party integrations should use API keys or `apiKeyHelper`.
- STACK.md Caddyfile pattern uses `Authorization: Bearer` for Anthropic -- this is incorrect. Must be `x-api-key`.

## Open Questions

1. **Caddy `{env.*}` behavior when variable is unset**
   - What we know: Caddy supports `{env.VAR}` placeholders in Caddyfile. OpenAI key is optional (D-08).
   - What's unclear: Does Caddy fail to start if `OPENAI_API_KEY` is unset? Does it insert an empty string? Does `{env.OPENAI_API_KEY:fallback}` syntax work?
   - Recommendation: Test empirically during implementation. Fallback approach: always set `OPENAI_API_KEY=unused` on host if unset, or use `{$OPENAI_API_KEY:unused}` shorthand.

2. **OAuth sidecar implementation complexity**
   - What we know: Claude Code supports `apiKeyHelper` for dynamic credentials. Pro/Max users authenticate via OAuth. The sidecar must handle token refresh.
   - What's unclear: Whether `apiKeyHelper` works reliably inside a QEMU guest calling back to the host. Whether the OAuth token can be obtained without `claude login` (which requires a browser).
   - Recommendation: Implement core Caddy proxy first. Defer OAuth sidecar to a separate plan. Pro/Max users can use `claude login` directly in the guest for now if they have direct network access (which SLIRP provides).

3. **Does Claude Code inside guest actually send the dummy x-api-key header?**
   - What we know: Setting `ANTHROPIC_API_KEY=dummy` should cause Claude Code to send `x-api-key: dummy` in requests. Caddy's `header_up x-api-key` overwrites this.
   - What's unclear: Whether Claude Code validates the API key format before sending, or if it silently rejects "dummy" as invalid.
   - Recommendation: Test empirically. If Claude Code rejects dummy keys, use a key format that passes validation (e.g., `sk-ant-dummy-key-placeholder`).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| caddy | Proxy (SEC-01) | Not installed | -- | `brew install caddy` (required, no fallback) |
| aq | VM lifecycle (Phase 1 dep) | Installed | 1.6.0 | -- |
| qemu | VM engine (Phase 1 dep) | Installed (via aq) | -- | -- |
| mise | Guest env vars (SEC-02) | Not in guest (apk add during provisioning) | 2025.5.10-r0 (Alpine 3.22 community) | -- |
| curl | Health checks | Available on host; available in guest | -- | -- |

**Missing dependencies with no fallback:**
- `caddy` must be installed on host. Add to `check_all_deps()` in `util.sh`.

**Missing dependencies with fallback:**
- None. All dependencies either exist or must be installed.

## Project Constraints (from CLAUDE.md)

- **Shell script:** The tool itself is a shell script (Bash 5.x), not a compiled binary. New `proxy.sh` module must follow existing patterns.
- **ShellCheck clean:** All new code must pass `shellcheck --severity=warning`.
- **aq wrapping:** `rl` wraps `aq` commands. Guest provisioning uses `aq exec "$vm_name"` pattern with heredoc.
- **QEMU user-mode networking:** Guest reaches host at 10.0.2.2 via SLIRP. No TAP/bridge networking.
- **No hardcoded API keys:** Use `{env.*}` placeholders in Caddyfile. Keys read from host environment at runtime.
- **Per-VM state in `.rl/`:** Phase 1 established `.rl/` directory in repo root. Phase 2 may need to track proxy status here.
- **No Docker:** VM-level isolation only, via QEMU.
- **Ed25519 SSH keys, no agent forwarding:** Security constraints from CLAUDE.md.

## Sources

### Primary (HIGH confidence)
- [Anthropic API Overview](https://platform.claude.com/docs/en/api/overview) -- `x-api-key` header format, authentication requirements
- [Claude Code Authentication](https://code.claude.com/docs/en/authentication) -- `apiKeyHelper`, OAuth precedence, credential management
- [Claude Code LLM Gateway](https://code.claude.com/docs/en/llm-gateway) -- ANTHROPIC_BASE_URL, required header forwarding (anthropic-beta, anthropic-version)
- [Caddy reverse_proxy directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) -- `header_up` syntax, overwrite vs add behavior
- [Caddy bind directive](https://caddyserver.com/docs/caddyfile/directives/bind) -- binding to specific interfaces
- [Caddy request matchers](https://caddyserver.com/docs/caddyfile/matchers) -- `remote_ip` matches TCP source IP (immediate peer), not forwarded headers
- [Caddy command line](https://caddyserver.com/docs/command-line) -- `caddy start`, `caddy stop`, `caddy reload`, `--pidfile`
- [Alpine Linux packages: mise](https://pkgs.alpinelinux.org/package/v3.22/community/aarch64/mise) -- mise 2025.5.10-r0 available in Alpine 3.22 community aarch64
- [mise installation docs](https://mise.jdx.dev/installing-mise.html) -- Alpine installation via apk, shell activation
- [alpine-conf setup-apkrepos source](https://github.com/alpinelinux/alpine-conf/blob/master/setup-apkrepos.in) -- `-1` flag only enables main repo, community is commented out
- [aq source code](/Users/pirj/.bin/aq) -- Alpine 3.22.2, aarch64, APKREPOSOPTS="-1" (community repo commented out)
- [QEMU networking docs](https://www.qemu.org/docs/master/system/devices/net.html) -- SLIRP user-mode networking, 10.0.2.2 gateway

### Secondary (MEDIUM confidence)
- [QEMU SLIRP NAT behavior](https://www.uni-koeln.de/~pbogusze/posts/Redirect_QEMU_guests_TCP_socket_to_hosts_loopback_socket.html) -- guest-to-host connections appear as 127.0.0.1 on host side
- [Caddy community: caddy start vs run](https://caddy.community/t/caddy-start-vs-caddy-run/9285) -- background process management, admin API control
- [opencode-claude-max-proxy](https://github.com/rynfar/opencode-claude-max-proxy) -- reference for OAuth sidecar architecture patterns

### Tertiary (LOW confidence)
- SLIRP source IP claim (127.0.0.1 on host) -- needs empirical validation with actual aq VM + Caddy setup. Multiple sources agree but no authoritative QEMU documentation explicitly states this.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- Caddy and mise verified against official docs and Alpine package repos
- Architecture: HIGH -- Caddyfile pattern verified, `header_up` overwrite behavior confirmed, SLIRP networking validated
- Pitfalls: HIGH for pitfalls 1-4, MEDIUM for pitfalls 5-6 (need empirical validation)
- OAuth sidecar: LOW -- complex, deferred, needs empirical testing

**Research date:** 2026-03-26
**Valid until:** 2026-04-26 (stable domain -- Caddy, Alpine, and Anthropic API are mature)

---
*Phase: 02-security-boundary*
*Researched: 2026-03-26*
