# Project Research Summary

**Project:** AILockr
**Domain:** VM-based AI agent isolation CLI tool
**Researched:** 2026-03-24
**Confidence:** HIGH

## Executive Summary

AILockr is a shell-based CLI tool (`lr`) that runs AI coding agents (Claude Code, Codex) inside QEMU virtual machines with a strict security boundary: API keys never enter the guest VM. The established pattern for this class of tool is a reverse proxy on the host that injects Authorization headers into upstream API requests, while the guest connects via a custom base URL over QEMU's user-mode networking gateway (10.0.2.2). Code moves between host and guest exclusively through git over SSH -- no filesystem mounts, no shared directories. This proxy-plus-git-remote architecture is architecturally superior to every competitor surveyed, which either pass API keys as environment variables into the sandbox or rely on weaker container isolation.

The recommended approach is a Bash CLI script with modular `lib/` sourced libraries, wrapping the `aq` QEMU Alpine manager for VM lifecycle management and Caddy for the API proxy. The stack is deliberately minimal: Bash for the CLI, QEMU/aq for VMs, Caddy for proxying, SSH/tmux for session management, and git for code exchange. No compiled languages, no runtime dependencies beyond what ships with macOS/Linux. The key architectural insight -- using `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` to redirect agent traffic through a host-side Caddy proxy that injects auth headers -- eliminates the need for TLS interception, custom CA certificates, or any secrets inside the VM.

The primary risks are: (1) Caddy binding to all interfaces and exposing API keys to the local network (mitigate with `remote_ip` matchers restricting to 10.0.2.0/24 and 127.0.0.1), (2) the macOS firewall blocking QEMU guest-to-host connectivity (requires binding Caddy to 0.0.0.0 rather than 127.0.0.1, combined with IP restriction), (3) git push to a non-bare repo corrupting the host working tree (mitigate with a fetch-based workflow instead of push), and (4) shell portability issues between macOS BSD and Linux GNU utilities (mitigate with ShellCheck enforcement from day one). All critical pitfalls must be addressed in the first phase -- they concern the foundational networking and security layer.

## Key Findings

### Recommended Stack

The stack is pure shell and off-the-shelf binaries with zero build steps. Bash 5.x for the host CLI (`#!/usr/bin/env bash`), QEMU 10.x via the `aq` wrapper for Alpine VM management, and Caddy 2.11.x for API key injection via reverse proxy. Inside the guest: Alpine Linux 3.21, Node.js 22.x (for Claude Code), tmux 3.6, git, and openssh. Development tooling is ShellCheck, shfmt, and BATS for testing.

**Core technologies:**
- **Bash 5.x**: CLI scripting language -- arrays and `[[ ]]` conditionals justify the choice over POSIX sh for a non-trivial CLI tool
- **QEMU + aq**: VM engine and lifecycle wrapper -- user-mode networking (SLIRP) provides guest-to-host communication without root privileges; HVF on macOS, KVM on Linux
- **Caddy 2.11.x**: Reverse proxy for API key injection -- `header_up` directive injects Authorization headers in 3 lines of config, HTTP mode disables auto-TLS
- **Alpine Linux 3.21**: Guest OS -- minimal footprint (~5MB base), fast `apk` package installation, ships Node.js 22.x in main repos
- **SSH + tmux**: Session management -- Ed25519 per-VM key pairs, tmux for session persistence across disconnects
- **Git**: Code bridge -- the only data channel between host and guest; no filesystem mounts

**Critical version requirements:** macOS ships Bash 3.2 at `/bin/bash` -- must use `#!/usr/bin/env bash` and require Homebrew Bash. Alpine 3.18+ needed for Node.js 18+ (Claude Code requirement). Caddy 2.5+ needed for `{env.*}` placeholder syntax.

### Expected Features

**Must have (table stakes):**
- VM creation with agent pre-installed (`lr new`) -- single-command environment creation
- SSH into VM with tmux session persistence (`lr code`) -- interactive agent sessions
- Git-based code exchange -- host as git remote, push/pull through SSH tunnel
- Caddy API proxy with header injection -- API keys never enter the VM
- Default resource limits -- 1 vCPU, 1GB disk via aq defaults
- Internet access from VM -- QEMU user-mode networking provides this by default

**Should have (differentiators):**
- Opt-in config copying (`lr new --config claude --config git`) -- explicit, per-file, sanitized
- VM lifecycle management (`lr list`, `lr status`, `lr rm`) -- operational visibility
- Multi-agent support (multiple VMs per repo on different branches) -- parallel isolated agents
- Configurable resource limits (`--disk 2G --cpus 2`)

**Defer (v2+):**
- PR review mode (`lr review <PR-URL>`) -- high complexity, requires multiple subsystems to coordinate
- VM snapshots / checkpointing -- not needed when tmux provides session persistence
- Multi-provider proxy (Gemini, Mistral) -- add as demand emerges
- Homebrew formula / installer packaging

**Anti-features (explicitly avoid):**
- Network egress filtering -- adds complexity, unnecessary since VM has no secrets to exfiltrate
- GUI/browser access inside VM -- contradicts lightweight CLI philosophy
- Docker-inside-VM -- virtualization inception, fragile on Alpine
- Web dashboard -- contradicts CLI-first design
- Automatic secret scanning -- prevention (proxy architecture) beats detection

### Architecture Approach

The architecture follows a modular shell pattern: a single `lr` entry point with case-statement dispatch, sourcing `lib/` modules on demand per subcommand. Per-VM state lives in `~/.local/state/ailockr/vms/<name>/` (XDG-compliant), holding allocated ports, Caddy PID files, and generated Caddyfiles. The `lr new` command orchestrates a layered lifecycle: allocate ports, generate Caddy config, start proxy, create VM via aq, wait for SSH, provision guest, set up git remote -- with trap-based cleanup on failure at any step.

**Major components:**
1. **`lr` entry point** -- case-statement dispatch to subcommand handlers, sources only needed lib/ modules
2. **`lib/vm.sh`** -- wraps aq for VM create/start/stop/destroy, manages port allocation
3. **`lib/proxy.sh`** -- generates Caddyfile from template, manages Caddy lifecycle, ensures bind/IP restrictions
4. **`lib/git.sh`** -- initializes guest repo, sets up host-side git remote via SSH, handles fetch/merge workflow
5. **`lib/ssh.sh`** -- SSH connection with per-VM Ed25519 keys, tmux session attach-or-create
6. **`lib/setup.sh`** -- guest provisioning: package installation, env var configuration, agent setup
7. **`lib/config.sh`** -- per-VM state directory management, global settings, opt-in config copying with sanitization

### Critical Pitfalls

1. **Caddy binds to all interfaces, leaking API keys to LAN** -- Bind to 0.0.0.0 but restrict with `remote_ip` matcher to 10.0.2.0/24 and 127.0.0.1. This solves both reachability (Pitfall 3) and security simultaneously. Verify with `lsof -i :<port>`.

2. **Git push to non-bare host repo fails or corrupts working tree** -- Never push from guest to host's checked-out branch. Use a fetch-based workflow: guest commits, host runs `git fetch guest <branch>` then merges. The `lr` tool must handle this automatically.

3. **macOS firewall blocks guest-to-host Caddy connectivity** -- QEMU SLIRP traffic arrives at the host as non-loopback traffic. Caddy must bind to 0.0.0.0 (not 127.0.0.1), and macOS users may need to allow Caddy through the Application Layer Firewall. Document this in setup.

4. **Claude Code / Codex TLS errors through proxy** -- Caddy must serve HTTP (not HTTPS) on the internal proxy port. Use the `http://` scheme prefix in the Caddyfile to disable auto-TLS. Guest env vars must use `http://` URLs.

5. **Orphaned QEMU processes accumulate silently** -- Validate PID ownership before killing (check process name matches `qemu-system-*`), use trap for cleanup on EXIT/INT/TERM/HUP, implement `lr cleanup` for orphan detection.

6. **Shell portability breaks between macOS and Linux** -- Use `#!/usr/bin/env bash`, avoid `sed -i`, replace `readlink -f` with POSIX-compatible function, use `printf` instead of `echo -e`, enforce ShellCheck from first commit.

## Implications for Roadmap

Based on research, the suggested phase structure follows the architecture's dependency graph and the pitfall-to-phase mapping. Every critical pitfall maps to Phase 1 or Phase 2, meaning the foundation must be rock-solid before building higher-level features.

### Phase 1: CLI Skeleton and VM Lifecycle
**Rationale:** Nothing works without the CLI entry point and a running VM. This phase establishes the shell dialect, project structure, and aq integration -- the foundation everything else builds on.
**Delivers:** `lr new <name>` creates an Alpine VM via aq with SSH port forwarding; `lr code <name>` connects via SSH; `lr stop <name>` and `lr destroy <name>` manage lifecycle. Basic `lr` dispatch with modular lib/ structure.
**Addresses features:** VM creation, SSH access, session persistence (tmux), resource limits (aq defaults)
**Avoids pitfalls:** Shell portability (ShellCheck from day 1), orphaned processes (trap-based cleanup), SSH host key issues (per-VM known_hosts, `-o StrictHostKeyChecking=no` for local VMs)
**Stack elements:** Bash, aq, QEMU, SSH, tmux

### Phase 2: API Proxy (Security Boundary)
**Rationale:** The Caddy proxy is the core security differentiator and must be validated end-to-end before provisioning agents. Without a working proxy, the agents cannot call APIs, rendering the tool useless. This phase also resolves the Caddy bind address + macOS firewall conflict, which is the trickiest networking problem.
**Delivers:** Caddy reverse proxy running on host, accepting HTTP requests from the QEMU guest at 10.0.2.2, injecting Authorization headers, forwarding to upstream Anthropic/OpenAI APIs over HTTPS. Per-VM Caddyfile generation from template. Port allocation with lockfile to prevent collisions.
**Addresses features:** API key protection (the primary value proposition)
**Avoids pitfalls:** Caddy binding to all interfaces (remote_ip matcher), TLS/certificate errors (HTTP mode for internal hop), API keys in plaintext config (env var placeholders), macOS firewall blocking guest connections
**Stack elements:** Caddy, Caddyfile template

### Phase 3: Guest Provisioning and Agent Setup
**Rationale:** Depends on both VM lifecycle (Phase 1) and proxy configuration (Phase 2, for setting `*_BASE_URL` env vars). This phase installs the AI agents and configures them to route through the proxy.
**Delivers:** `lr new` provisions a complete guest: installs packages (nodejs, npm, git, tmux, openssh, Claude Code, Codex), configures `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL`, verifies end-to-end API connectivity from inside the guest.
**Addresses features:** Agent pre-installation, internet access from VM
**Avoids pitfalls:** Claude Code TLS errors (HTTP base URL), Alpine package compatibility (libgcc, libstdc++, ripgrep for Claude Code native installer), Codex musl compatibility (verify binary availability)
**Stack elements:** Alpine apk, Node.js, Claude Code, Codex

### Phase 4: Git Code Bridge
**Rationale:** Depends on SSH (Phase 1) and a provisioned guest with git (Phase 3). The git remote is the "airlock" -- the only passage for code between host and guest. The fetch-based workflow design must be correct to avoid the non-bare repo corruption pitfall.
**Delivers:** `lr push` sends code from host to guest, `lr pull` fetches code from guest to host. Guest has a working directory at `/workspace`, host adds guest as a git remote via SSH tunnel. Fetch-based workflow prevents host working tree corruption.
**Addresses features:** Git-based code exchange (table stakes), git-only bridge (differentiator)
**Avoids pitfalls:** Push to non-bare repo corruption (fetch-based workflow), SSH agent forwarding (never forward, use per-VM keys only)
**Stack elements:** Git, SSH

### Phase 5: Polish and Lifecycle Management
**Rationale:** With the core flow working (create VM, connect, proxy API calls, exchange code), this phase adds operational features that make the tool usable day-to-day.
**Delivers:** `lr list` shows running VMs with status; `lr status <name>` shows detailed info (ports, disk usage, uptime); `lr cleanup` finds orphaned processes; opt-in config copying (`--config claude`, `--config git`) with sanitization (strip credentials from git config); configurable resource limits; progress indicators during `lr new`; helpful error messages with install instructions for missing dependencies.
**Addresses features:** VM lifecycle management, opt-in config copying, configurable resource limits
**Avoids pitfalls:** Orphaned process accumulation, config copy leaking secrets, silent failures

### Phase 6: Multi-VM and Advanced Features
**Rationale:** Only after single-VM workflow is solid. Multiple VMs introduce port allocation complexity, shared/per-VM Caddy instances, and branch management.
**Delivers:** Multiple VMs per repo on different branches for parallel agent workflows. Shared Caddy instance with per-VM route blocks. Shell completions (bash + zsh). Installer script.
**Addresses features:** Multi-agent support, shell completions
**Avoids pitfalls:** Port collisions (port range allocator with lockfile), resource exhaustion (memory warnings)

### Phase Ordering Rationale

- **Phases 1-2 must come first** because every subsequent phase depends on a running VM with SSH (Phase 1) and a working proxy (Phase 2). The architecture research confirms this dependency chain.
- **Phase 3 before Phase 4** because the git bridge requires git to be installed in the guest, and the `*_BASE_URL` configuration depends on proxy ports being known.
- **Phase 4 is separate from Phase 1** despite both using SSH, because the git workflow design (fetch-based vs push-based) is a significant design decision that benefits from an already-stable SSH layer.
- **Phase 5 is polish, not core** -- these features improve UX but do not affect the security model or core functionality.
- **Phase 6 is genuinely optional** for v1 launch. Single-VM workflow covers the primary use case.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2 (API Proxy):** The Caddy bind address vs macOS firewall conflict requires hands-on validation. The `remote_ip` matcher approach needs to be tested with actual QEMU SLIRP traffic to confirm source IP matching works as expected.
- **Phase 3 (Guest Provisioning):** Claude Code native installer on Alpine/musl needs testing. Codex CLI musl compatibility is unverified -- if no musl binary exists, this is a blocker requiring an alternative approach (glibc compat layer or npm install).
- **Phase 4 (Git Code Bridge):** The fetch-based workflow design has several open questions: branch naming conventions, handling merge conflicts, what happens when the host repo has uncommitted changes.

Phases with standard patterns (skip research-phase):
- **Phase 1 (CLI Skeleton + VM):** Well-documented shell patterns, aq handles QEMU complexity, SSH+tmux is straightforward.
- **Phase 5 (Polish):** Standard CLI UX patterns, no novel integration challenges.
- **Phase 6 (Multi-VM):** Extension of existing patterns, primarily port management.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All technologies verified against official docs. QEMU networking, Caddy header injection, Claude Code gateway, and Codex base URL configuration all confirmed from primary sources. Only gap: `aq` is a private/unpublished repo with no external documentation. |
| Features | HIGH | Comprehensive competitor analysis covering Docker Sandboxes, claudebox, sandbox-claude, Daytona, Fly.io Sprites, E2B, ExitBox. Feature prioritization is well-grounded in competitive landscape. Anti-features are well-reasoned. |
| Architecture | HIGH | Modular shell pattern is well-established. XDG directory layout follows standards. Data flows are clear and verified against QEMU/Caddy/SSH documentation. Build order aligns with dependency graph. |
| Pitfalls | HIGH | Most pitfalls verified via official docs and multiple community sources. The Caddy bind + macOS firewall interaction is the highest-risk area. Git push to non-bare repo is a well-known issue with a clear mitigation. |

**Overall confidence:** HIGH

### Gaps to Address

- **`aq` capabilities and API:** The aq tool is referenced as a project dependency but is not publicly documented. The exact CLI interface (`aq new`, `aq start`, `aq stop`), flag passthrough for QEMU hostfwd, and resource limit configuration need validation against the actual tool. If aq does not support the required flags, the `lr` tool may need to invoke QEMU directly.
- **Codex CLI on Alpine/musl:** No confirmation that the Codex binary has a musl-compatible build. If it does not, the options are: (1) install glibc compat layer on Alpine, (2) use npm install instead of native binary, or (3) drop Codex support from v1. This must be tested early in Phase 3.
- **Claude Code native installer on Alpine:** The STACK and PITFALLS research notes that `libgcc`, `libstdc++`, and `ripgrep` are required dependencies. This needs hands-on testing to confirm the full dependency chain.
- **Caddy `remote_ip` matcher with QEMU SLIRP:** The proposed solution to Pitfall 1+3 (bind 0.0.0.0 + restrict via `remote_ip 10.0.2.0/24 127.0.0.1`) needs validation. SLIRP may present guest traffic with a different source IP than expected.
- **Disk sizing:** 1GB may be insufficient for Claude Code + Codex + a real codebase. Actual disk usage of a fully provisioned VM needs measurement during Phase 3.

## Sources

### Primary (HIGH confidence)
- [QEMU Official Networking Docs](https://www.qemu.org/docs/master/system/devices/net.html) -- user-mode networking, hostfwd syntax, SLIRP details
- [Caddy reverse_proxy Directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) -- header_up, upstream config
- [Caddy bind Directive](https://caddyserver.com/docs/caddyfile/directives/bind) -- interface binding behavior
- [Claude Code LLM Gateway Docs](https://code.claude.com/docs/en/llm-gateway) -- ANTHROPIC_BASE_URL, gateway requirements
- [OpenAI Codex Advanced Configuration](https://developers.openai.com/codex/config-advanced) -- OPENAI_BASE_URL, config.toml
- [Alpine Linux Releases](https://alpinelinux.org/releases/) -- version lifecycle, package availability
- [XDG Base Directory Specification](https://wiki.archlinux.org/title/XDG_Base_Directory) -- state and config directory standards
- [Git on the Server (official docs)](https://git-scm.com/book/en/v2/Git-on-the-Server-Setting-Up-the-Server) -- bare repository setup
- [Command Line Interface Guidelines](https://clig.dev/) -- CLI design best practices

### Secondary (MEDIUM confidence)
- [QEMU ArchWiki](https://wiki.archlinux.org/title/QEMU) -- SSH port forwarding, user-mode networking examples
- [Shell portability guide (POSIX)](https://oneuptime.com/blog/post/2026-02-13-posix-shell-compatibility/view) -- sh vs bash tradeoffs
- [Cross-platform shell: Linux vs macOS differences](https://tech-champion.com/programming/write-cross-platform-shell-linux-vs-macos-differences-that-break-production/)
- [QEMU networking on macOS](https://dev.to/krjakbrjak/qemu-networking-on-macos-549k) -- macOS-specific QEMU networking issues
- [qcow2 disk space reclamation (Proxmox wiki)](https://pve.proxmox.com/wiki/Shrink_Qcow2_Disk_Files)

### Competitor Analysis (MEDIUM-HIGH confidence)
- [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/get-started/) -- microVM sandbox approach
- [claudebox (BoxLite)](https://github.com/boxlite-ai/claudebox) -- libkrun/Firecracker sandbox for Claude Code
- [sandbox-claude](https://perevillega.com/posts/2026-03-03-ai-sandbox-coding-agents/) -- Incus containers with egress filtering
- [Daytona](https://github.com/daytonaio/daytona) -- secure AI code execution infrastructure
- [Fly.io Sprites](https://sprites.dev/) -- persistent stateful VMs for AI agents
- [Anthropic Claude Code sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing) -- official Anthropic engineering post
- [Formal: Using proxies to hide secrets](https://www.formal.ai/blog/using-proxies-claude-code/) -- reverse proxy pattern for API key isolation

---
*Research completed: 2026-03-24*
*Ready for roadmap: yes*
