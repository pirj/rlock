## Project

**rlock** — plugin-driven framework for ephemeral VM-isolated workspaces.

A shell-based CLI tool (`rl`) on top of pirj/aq. Provides the plugin protocol, layered qcow2 snapshot orchestration, and two generic plugins (`git`, `branch`). Use-case-specific behavior (AI agents, CI runners, ...) lives in plugin-pack repos that depend on this one:

- **ai.rlock** — AI coding-agent sandbox (Claude Code, Codex, auth-proxy). Caddy reverse proxy injects API keys host-side, no secrets in VM.
- **\<bake\>** (TBD name) — CI / pre-baked-environment distribution (docker-engine, docker-compose, ruby-bundler, npm, ...). Sub-second warm boot via cached layers.

### Constraints

- **VM engine**: QEMU via pirj/aq — no Docker, no containers (firecracker support planned in aq, Phase 2)
- **Guest OS**: Alpine Linux (what aq uses)
- **Shell script**: The tool itself is a shell script (Bash), not a compiled binary
- **Dependencies**: Requires aq, git, qemu-img on the host. Plugin packs may add more (Caddy, jq, ...)

## Technology Stack

## Recommended Stack
### Core Technologies
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Bash | 5.x | CLI tool scripting language (`lr` command) | Bash over POSIX sh because: arrays are needed for managing VM lists and argument parsing, `[[ ]]` conditionals simplify string comparisons, local variables prevent function side effects, and both macOS (via Homebrew) and Linux ship Bash 5+. The tradeoff vs POSIX sh portability is worth it for readability and maintainability of a non-trivial CLI tool. Alpine's ash (BusyBox) is irrelevant since `lr` runs on the host, not the guest. Confidence: HIGH |
| QEMU | 10.x (current: 10.2) | VM engine for guest isolation | Required by design constraint. User-mode networking (SLIRP) provides 10.0.2.2 gateway for guest-to-host communication without root privileges. qcow2 images grow on demand (1GB cap won't waste disk). On macOS uses HVF acceleration, on Linux uses KVM. Confidence: HIGH |
| pirj/aq | latest | QEMU wrapper for Alpine VM lifecycle | Project dependency. Handles VM creation, boot, shutdown, package installation. The `lr` CLI wraps `aq` rather than invoking QEMU directly. Note: this appears to be a private/unpublished repo at time of research -- the `lr` tool must gracefully handle `aq` not being installed. Confidence: MEDIUM (repo not publicly indexed) |
| Caddy | 2.11.x | Reverse proxy for API key injection | Caddy because: (1) `header_up` directive injects Authorization headers into upstream requests in 3 lines of config, (2) runs as a single static binary with zero dependencies, (3) no TLS/MITM complexity since guest connects to host proxy over plain HTTP while Caddy handles HTTPS upstream, (4) can bind to localhost-only to prevent external access. Nginx could work but requires more config and lacks Caddy's simplicity for this exact use case. Confidence: HIGH |
| Alpine Linux | 3.21.x (in guest) | Guest OS inside QEMU VM | Required by `aq`. Minimal footprint (~5MB base), fast `apk` package installation, musl libc. The 3.21 series is the current stable with support through 2026-11. Confidence: HIGH |
| OpenSSH | 10.x (host), 9.x+ (guest) | SSH tunnel from host into guest VM | Standard for remote session access. QEMU hostfwd maps a host port to guest port 22. Ed25519 keys for passwordless auth. The guest gets whatever version Alpine ships; the host uses whatever the OS provides. Confidence: HIGH |
| tmux | 3.6.x | Session persistence inside guest VM | Enables `lr code` to attach/detach from coding sessions without losing state. Named sessions (`tmux new -s ailockr`) allow scripted attach. `tmux has-session` checks if session exists before creating. Confidence: HIGH |
| Git | 2.x | Code bridge between host and guest | The only data channel between host and guest. Host adds guest repo as a git remote via SSH over the forwarded port. No GitHub credentials enter the guest. Confidence: HIGH |
### Guest Packages (Alpine apk)
| Package | Purpose | When Installed |
|---------|---------|----------------|
| `openssh` | SSH daemon for host-to-guest access | During `lr new` VM provisioning |
| `tmux` | Session multiplexing | During `lr new` VM provisioning |
| `git` | Repository management inside guest | During `lr new` VM provisioning |
| `nodejs` + `npm` | Required for Claude Code (npm package) | During `lr new` when `--agent claude` |
| `curl` | General utility, health checks | During `lr new` VM provisioning |
| `bash` | Required by some agent tooling inside guest | During `lr new` VM provisioning |
### Host Dependencies
| Dependency | Purpose | Installation |
|------------|---------|-------------|
| `aq` | QEMU VM lifecycle management | `git clone` from pirj/aq (or script install) |
| `caddy` | Reverse proxy for API key injection | `brew install caddy` (macOS) / distro package (Linux) |
| `qemu` | VM hypervisor | `brew install qemu` (macOS) / distro package (Linux) |
| `git` | Repository management, host-guest bridge | Pre-installed on most systems |
| `ssh` | Connecting to guest VM | Pre-installed on macOS/Linux |
| `ssh-keygen` | Generating per-VM key pairs | Part of OpenSSH, pre-installed |
### AI Agent Configuration
| Agent | Base URL Env Var | Config Mechanism | Proxy Path |
|-------|-----------------|------------------|------------|
| Claude Code | `ANTHROPIC_BASE_URL` | Environment variable in guest | `http://10.0.2.2:PORT/v1/messages` |
| OpenAI Codex | `OPENAI_BASE_URL` | Environment variable or `config.toml` | `http://10.0.2.2:PORT/v1/` |
### Development Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| ShellCheck | Static analysis for shell scripts | Catches bashisms if targeting portability, catches quoting bugs, uninitialized variables. Run as `shellcheck lr`. Install: `brew install shellcheck` |
| shfmt | Shell script formatting | Consistent style across the codebase. Pair with ShellCheck. Install: `brew install shfmt` |
| BATS (bats-core) | Bash testing framework | Test CLI commands, argument parsing, error handling. `bats test/` runs test suite. Install: `brew install bats-core` |
## Caddy Configuration Pattern
# Anthropic API proxy (for Claude Code)
# OpenAI API proxy (for Codex)
- `http://` prefix disables Caddy's automatic HTTPS (no certificates needed for local proxy)
- `header_up` injects the Authorization header into upstream requests
- `{env.ANTHROPIC_API_KEY}` reads from host environment (keys never written to disk in Caddy config)
- Guest sets `ANTHROPIC_BASE_URL=http://10.0.2.2:9110` to route through proxy
- Guest sets `OPENAI_BASE_URL=http://10.0.2.2:9111` to route through proxy
## QEMU Networking Pattern
# Typical QEMU invocation (handled by aq, shown for reference)
- Guest IP: 10.0.2.15 (DHCP from QEMU)
- Host gateway: 10.0.2.2 (where Caddy is reachable)
- DNS server: 10.0.2.3
- SSH: forwarded via `hostfwd=tcp::${SSH_PORT}-:22`
- ICMP (ping) does not work in user-mode networking (except to 10.0.2.2)
- IPv6 port forwarding not supported
- No incoming connections except via explicit hostfwd rules
## SSH/tmux Session Pattern
# Generate per-VM SSH key pair (during lr new)
# Copy public key to guest authorized_keys (during provisioning)
# Via aq's file copy mechanism or ssh-copy-id after first boot
# Connect and attach tmux session (lr code)
- These are local QEMU VMs on localhost, not remote hosts
- VM host keys change on every `lr new` (ephemeral VMs)
- The SSH key pair itself provides authentication
## Installation
# Host prerequisites (macOS)
# Host prerequisites (Linux - Debian/Ubuntu)
# Development tools
# aq (QEMU Alpine wrapper)
# Add to PATH or symlink
# Claude Code (inside guest, during provisioning)
# Codex (inside guest, during provisioning)
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Caddy (reverse proxy) | Nginx | Only if you need more granular HTTP control (rate limiting per endpoint, complex routing). Caddy wins on simplicity: single binary, zero-config TLS, `header_up` in 1 line vs Nginx's `proxy_set_header` with more boilerplate |
| Caddy (reverse proxy) | mitmproxy | Never for this use case. MITM requires installing a custom CA cert in the guest, adds fragility, and is unnecessary since Claude Code/Codex support custom base URLs |
| Caddy (reverse proxy) | Node.js/Go shim | Only if Caddy cannot handle a specific API quirk (unlikely). A custom proxy adds a build step and maintenance burden |
| Bash | POSIX sh | Only if the tool must run on systems without Bash (e.g., BusyBox-only environments). Since `lr` runs on the host (macOS/Linux), Bash is universally available and the readability gains justify the choice |
| Bash | Python/Go | Only if the CLI grows significantly complex (100+ commands, complex state management, plugin system). For the current scope (~5 commands), shell is the right layer -- no compile step, no runtime dependency, matches the Unix tool philosophy |
| QEMU user-mode networking | TAP/bridge networking | Only if you need guest-to-guest communication or incoming connections beyond SSH. TAP requires root privileges, which undermines the "just works" UX of the tool |
| Ed25519 SSH keys | RSA keys | Never. Ed25519 is faster, shorter keys, more secure. RSA is legacy |
| Per-VM SSH key pairs | Shared SSH key | Never. Per-VM keys ensure destroying a VM destroys its credentials. Shared keys create lingering access risk |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Docker / containers | Shared kernel with host. "Danger mode" AI agents can escape container boundaries. The entire project rationale is VM-level isolation | QEMU VMs via aq |
| MITM proxy (mitmproxy, Charles) | Requires installing custom CA certificates in guest, breaks when TLS pinning changes, adds debugging complexity | Caddy reverse proxy with `header_up` + custom `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` |
| HTTP_PROXY / HTTPS_PROXY env vars | These configure a forward proxy (CONNECT tunnel), which cannot inject headers into HTTPS traffic. The whole point is header injection | `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` pointing to Caddy |
| `ssh-agent` forwarding | Exposes host SSH credentials to guest. An agent in "danger mode" could use these to access GitHub, other servers, etc. | Per-VM Ed25519 key pairs with no forwarding |
| Hardcoded API keys in Caddyfile | Keys on disk in config files are a leak risk | `{env.ANTHROPIC_API_KEY}` in Caddyfile reads from host environment at runtime |
| `getopts` for argument parsing | Limited to short options only, no `--long-option` support. CLI tools in 2026 are expected to have long options | Manual `while/case/shift` loop for argument parsing, or consider `getoptions` library for POSIX-compatible long option support |
| `screen` | Legacy terminal multiplexer, less actively maintained, worse scripting API | tmux -- better session management, scriptable, actively developed (3.6a released Nov 2025) |
| Pre-built VM images | Adds distribution complexity (hosting, versioning, architecture variants). Alpine package installation via `apk` is fast enough (~10-15 seconds) for the startup flow | Install packages on first boot during `lr new` |
## Stack Patterns by Variant
- Use `brew install qemu caddy` for all host dependencies
- QEMU uses HVF (Hypervisor.framework) for near-native performance
- Bash 5.x comes from Homebrew (macOS ships ancient Bash 3.2 at `/bin/bash`)
- Shebang should be `#!/usr/bin/env bash` (finds Homebrew bash)
- Use distro packages for QEMU and Caddy
- QEMU uses KVM for near-native performance
- Bash 5.x is the system default on modern distros
- Consider `--enable-kvm` flag for QEMU acceleration
- Abstract QEMU acceleration flags: detect `kvm` availability on Linux, HVF on macOS
- Use `#!/usr/bin/env bash` shebang for portability
- Test `sed` behavior differences (BSD vs GNU) -- use `sed -i ''` on macOS vs `sed -i` on Linux, or avoid in-place sed entirely
- Caddy binary is identical across platforms (Go cross-compilation)
## Version Compatibility
| Component | Minimum Version | Tested With | Notes |
|-----------|-----------------|-------------|-------|
| Bash | 4.0+ (arrays, local) | 5.2 | macOS default `/bin/bash` is 3.2 -- require Homebrew Bash or document requirement |
| QEMU | 8.0+ (stable user-mode networking) | 10.2 | User-mode networking is stable across versions. HVF support added in QEMU 6.2+ for Apple Silicon |
| Caddy | 2.7+ (header_up, env vars) | 2.11.x | `{env.*}` placeholders available since Caddy 2.5. `header_up` since Caddy 2.0 |
| Alpine Linux | 3.18+ | 3.21.x | Need `nodejs` 18+ in repos for Claude Code. Alpine 3.18+ ships Node 18+ |
| Node.js (in guest) | 18+ | 22.x (Alpine 3.21 repos) | Required by Claude Code. Alpine 3.21 ships Node 22.x in main repos |
| tmux | 3.0+ | 3.6a | Named sessions and `has-session` command stable across 3.x series |
| OpenSSH | 8.0+ | 10.x | Ed25519 keys supported since OpenSSH 6.5. No version concerns |
| Git | 2.20+ | 2.x | Remote management stable across all 2.x versions |
## Sources
- [QEMU Official Networking Docs](https://www.qemu.org/docs/master/system/devices/net.html) -- user-mode networking, hostfwd syntax, SLIRP details. HIGH confidence
- [QEMU 10.2 Release](https://www.qemu.org/2025/12/24/qemu-10-2-0/) -- current stable version verification. HIGH confidence
- [Caddy reverse_proxy Directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) -- header_up syntax, upstream configuration. HIGH confidence
- [Caddy Global Options](https://caddyserver.com/docs/caddyfile/options) -- auto_https off, http:// prefix behavior. HIGH confidence
- [Claude Code LLM Gateway Docs](https://code.claude.com/docs/en/llm-gateway) -- ANTHROPIC_BASE_URL, gateway requirements. HIGH confidence
- [Codex Advanced Configuration](https://developers.openai.com/codex/config-advanced) -- OPENAI_BASE_URL, config.toml. HIGH confidence
- [Alpine Linux Releases](https://alpinelinux.org/releases/) -- version lifecycle, support dates. HIGH confidence
- [Alpine Package Keeper Wiki](https://wiki.alpinelinux.org/wiki/Alpine_Package_Keeper) -- apk usage, world file. HIGH confidence
- [ShellCheck GitHub](https://github.com/koalaman/shellcheck) -- shell linting tool. HIGH confidence
- [tmux 3.6 Release](https://github.com/tmux/tmux/releases) -- current version. HIGH confidence
- [QEMU ArchWiki](https://wiki.archlinux.org/title/QEMU) -- SSH port forwarding examples, user-mode networking. MEDIUM confidence (community wiki)
- [Writing POSIX-Compatible Shell Scripts](https://oneuptime.com/blog/post/2026-02-13-posix-shell-compatibility/view) -- sh vs bash tradeoffs. MEDIUM confidence

## Conventions

Conventions not yet established. Will populate as patterns emerge during development.

## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
