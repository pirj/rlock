# Architecture Research

**Domain:** Shell-based CLI tool managing QEMU VMs for AI agent isolation
**Researched:** 2026-03-24
**Confidence:** HIGH

## Standard Architecture

### System Overview

```
HOST MACHINE
=============================================================================
  User
    |
    v
  ┌─────────────────────────────────────────────────────────────────────┐
  │  lr (CLI entry point)                                               │
  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │
  │  │ cmd_new  │ │ cmd_code │ │ cmd_stop │ │cmd_destroy│ │cmd_push/ │ │
  │  │          │ │          │ │          │ │           │ │ cmd_pull │ │
  │  └─────┬────┘ └─────┬────┘ └────┬─────┘ └─────┬─────┘ └────┬─────┘ │
  │        │            │           │              │            │       │
  ├────────┴────────────┴───────────┴──────────────┴────────────┴───────┤
  │  Internal Libraries (sourced shell modules)                         │
  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │
  │  │ vm.sh    │ │ proxy.sh │ │ git.sh   │ │ ssh.sh   │ │ config.sh│ │
  │  │(aq wrap) │ │(Caddy)   │ │(remotes) │ │(tmux/SSH)│ │(settings)│ │
  │  └─────┬────┘ └─────┬────┘ └────┬─────┘ └────┬─────┘ └──────────┘ │
  └────────┼────────────┼───────────┼─────────────┼────────────────────┘
           │            │           │             │
           v            v           v             v
  ┌─────────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
  │ aq (QEMU)   │ │ Caddy    │ │ git      │ │ ssh      │
  │ (ext tool)  │ │ (ext svc)│ │ (ext cmd)│ │ (ext cmd)│
  └──────┬──────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
         │             │            │             │
=========│=============│============│=============│=========================
         │             │            │             │
         v             v            v             v
  QEMU VM (Alpine Linux guest)
  ┌─────────────────────────────────────────────────────────────────────┐
  │  10.0.2.15 (guest IP, DHCP-assigned)                                │
  │                                                                     │
  │  ┌───────────┐  ┌───────────┐  ┌────────────┐  ┌────────────────┐  │
  │  │ claude    │  │ codex     │  │ git repo   │  │ tmux session   │  │
  │  │ code      │  │ CLI       │  │ (working)  │  │ (persistent)   │  │
  │  └─────┬─────┘  └─────┬─────┘  └────────────┘  └────────────────┘  │
  │        │              │                                             │
  │        │  ANTHROPIC_BASE_URL=http://10.0.2.2:PORT_A                 │
  │        │  OPENAI_BASE_URL=http://10.0.2.2:PORT_O                    │
  │        │              │                                             │
  └────────┼──────────────┼─────────────────────────────────────────────┘
           │              │
           v              v
     10.0.2.2 (QEMU host gateway)
           │              │
           v              v
     Caddy reverse proxy (on host)
           │              │
           v              v
     api.anthropic.com   api.openai.com
     (with injected       (with injected
      Authorization)       Authorization)
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| `lr` (entry point) | Parse subcommand and flags, dispatch to handler, validate prerequisites | Single shell script with case-statement dispatch |
| `lib/vm.sh` | VM lifecycle: create, start, stop, destroy; wraps `aq` commands; manages port allocation | Shell functions calling `aq` and tracking VM state |
| `lib/proxy.sh` | Caddy lifecycle: generate Caddyfile, start/stop Caddy, ensure proxy is running before VM connects | Shell functions managing Caddy process and config |
| `lib/git.sh` | Initialize bare repo on guest, add guest as git remote on host, push/pull operations | Shell functions using `git` and `ssh` |
| `lib/ssh.sh` | SSH connection management, tmux session attach/create, remote command execution | Shell functions wrapping `ssh` with correct port/key |
| `lib/config.sh` | Read/write per-VM config, manage global settings, opt-in host config copying | Shell functions reading/writing config files |
| `lib/setup.sh` | Guest provisioning: install packages, configure env vars, set up agent tools | Shell functions executing remote commands via SSH |
| `aq` (external) | QEMU VM lifecycle primitives: image creation, boot, networking, resource limits | External shell tool (dependency) |
| Caddy (external) | Reverse proxy with header injection, TLS termination to upstream APIs | External binary, managed via Caddyfile and CLI |

## Recommended Project Structure

```
ailockr/
├── lr                        # Main entry point (executable shell script)
├── lib/                      # Internal shell libraries (sourced by lr)
│   ├── vm.sh                 # VM lifecycle (wraps aq)
│   ├── proxy.sh              # Caddy proxy lifecycle
│   ├── git.sh                # Git remote setup and sync
│   ├── ssh.sh                # SSH + tmux session management
│   ├── config.sh             # Configuration reading/writing
│   ├── setup.sh              # Guest provisioning logic
│   └── util.sh               # Shared utilities (logging, colors, error handling)
├── templates/                # Template files copied/generated at runtime
│   ├── Caddyfile.template    # Per-VM Caddy config template
│   └── guest-setup.sh        # Script run inside guest on first boot
├── completions/              # Shell completions
│   ├── lr.bash               # Bash completions
│   └── lr.zsh                # Zsh completions
├── install.sh                # Installer script
├── Makefile                  # install/uninstall targets
└── README.md                 # Usage documentation
```

### Structure Rationale

- **`lr` (single entry point):** Follows the Git/Docker convention of a single binary with subcommands. Keeps discoverability simple. Sources `lib/` modules on demand rather than loading everything upfront.
- **`lib/` (sourced modules):** Each file owns one concern. Functions are prefixed with the module name (e.g., `vm_create`, `proxy_start`, `git_setup_remote`) to avoid namespace collisions. Modules are sourced lazily -- only the ones needed for the current subcommand.
- **`templates/`:** Separates generated configuration from logic. The Caddyfile template uses variable substitution at runtime rather than hardcoded values.
- **No `src/` directory:** This is a shell project, not a compiled language. Flat `lib/` is the Bash convention.

### State and Data Directory Layout

Per the XDG Base Directory Specification, runtime state lives under `XDG_STATE_HOME` (defaults to `~/.local/state`), and configuration lives under `XDG_CONFIG_HOME` (defaults to `~/.config`):

```
~/.config/ailockr/              # Global configuration
├── config                      # Global settings (default resource limits, API proxy ports)
└── hosts/                      # Per-host-config configs (if needed)

~/.local/state/ailockr/         # Runtime state
├── vms/                        # Per-VM state directories
│   └── <project-name>/        # Named after the repo/project
│       ├── vm.conf             # VM-specific config (ports, paths)
│       ├── caddy.pid           # Caddy process ID for this VM
│       ├── ssh_port            # Allocated SSH port number
│       ├── anthropic_port      # Allocated Anthropic proxy port
│       ├── openai_port         # Allocated OpenAI proxy port
│       └── Caddyfile           # Generated Caddyfile for this VM
└── ports.lock                  # Port allocation tracking (avoid collisions)
```

## Architectural Patterns

### Pattern 1: Case-Statement Command Dispatch

**What:** The main `lr` script uses a top-level `case "$1" in` block to dispatch to subcommand handlers. Each handler is a function defined in a sourced module.

**When to use:** Shell CLI tools with fewer than ~15 subcommands. Beyond that, consider auto-discovery of command scripts in a `commands/` directory.

**Trade-offs:** Simple and readable for a small command set. No framework dependency. But no automatic help generation or flag parsing -- those must be hand-coded or handled with `getopts`.

**Example:**
```sh
#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Only source what's needed per subcommand
cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
  new)
    . "$LIB_DIR/config.sh"
    . "$LIB_DIR/vm.sh"
    . "$LIB_DIR/proxy.sh"
    . "$LIB_DIR/git.sh"
    . "$LIB_DIR/setup.sh"
    cmd_new "$@"
    ;;
  code)
    . "$LIB_DIR/config.sh"
    . "$LIB_DIR/ssh.sh"
    cmd_code "$@"
    ;;
  stop)
    . "$LIB_DIR/config.sh"
    . "$LIB_DIR/vm.sh"
    . "$LIB_DIR/proxy.sh"
    cmd_stop "$@"
    ;;
  destroy)
    . "$LIB_DIR/config.sh"
    . "$LIB_DIR/vm.sh"
    . "$LIB_DIR/proxy.sh"
    . "$LIB_DIR/git.sh"
    cmd_destroy "$@"
    ;;
  push|pull)
    . "$LIB_DIR/config.sh"
    . "$LIB_DIR/git.sh"
    cmd_git_sync "$cmd" "$@"
    ;;
  help|--help|-h)
    cmd_help
    ;;
  *)
    echo "lr: unknown command '$cmd'" >&2
    cmd_help >&2
    exit 1
    ;;
esac
```

### Pattern 2: Per-VM State Directory

**What:** Each VM gets a named directory under `~/.local/state/ailockr/vms/<name>/` that holds all state for that VM: allocated ports, Caddy PID, generated configs. The directory name is derived from the project/repo name.

**When to use:** Any tool managing multiple long-lived resources that need independent lifecycle control.

**Trade-offs:** Clear isolation between VMs. Easy to enumerate active VMs (`ls` the directory). But requires cleanup on destroy and orphan detection on startup. Simpler than a database or JSON state file for shell scripts.

**Example:**
```sh
vm_state_dir() {
  local name="$1"
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ailockr/vms/$name"
  mkdir -p "$dir"
  echo "$dir"
}

vm_is_running() {
  local name="$1"
  local state_dir
  state_dir="$(vm_state_dir "$name")"
  # Check if aq reports the VM as running
  aq status "$name" 2>/dev/null | grep -q "running"
}
```

### Pattern 3: Layered Lifecycle Orchestration

**What:** The `lr new` command orchestrates multiple subsystems in sequence: allocate ports, generate Caddy config, start Caddy, create VM via aq, wait for SSH, provision guest, set up git remote. Each step is idempotent where possible, and failure at any step triggers cleanup of prior steps.

**When to use:** Any multi-service orchestration in shell scripts.

**Trade-offs:** Explicit ordering makes dependencies visible. Cleanup on failure prevents orphaned resources. But shell error handling is limited -- `trap` for cleanup is the standard approach, though it can get messy with partial failures.

**Example:**
```sh
cmd_new() {
  local name="${1:?Usage: lr new <project-name>}"

  # Allocate resources
  local state_dir ssh_port anthropic_port openai_port
  state_dir="$(vm_state_dir "$name")"
  ssh_port="$(port_allocate)"
  anthropic_port="$(port_allocate)"
  openai_port="$(port_allocate)"

  # Save allocated state
  echo "$ssh_port" > "$state_dir/ssh_port"
  echo "$anthropic_port" > "$state_dir/anthropic_port"
  echo "$openai_port" > "$state_dir/openai_port"

  # Set trap for cleanup on failure
  trap 'cmd_destroy "$name" 2>/dev/null' EXIT

  # Orchestrate: each step depends on the previous
  proxy_generate_config "$name" "$anthropic_port" "$openai_port"
  proxy_start "$name"
  vm_create "$name" "$ssh_port"
  ssh_wait_ready "$name"
  setup_provision_guest "$name"
  git_setup_remote "$name"

  # Success -- remove cleanup trap
  trap - EXIT

  echo "VM '$name' ready. Run: lr code $name"
}
```

## Data Flow

### Flow 1: `lr new` -- VM Creation

```
User: lr new myproject
    |
    v
[lr dispatch] --> case "new"
    |
    v
[port_allocate] --> find unused ports for SSH, Anthropic proxy, OpenAI proxy
    |                 (check ~/.local/state/ailockr/ports.lock)
    v
[proxy_generate_config] --> render Caddyfile.template with ports and API keys
    |                         (read API keys from env: ANTHROPIC_API_KEY, OPENAI_API_KEY)
    v
[proxy_start] --> caddy start --config <generated-Caddyfile>
    |               (write PID to state dir)
    v
[vm_create] --> aq new myproject
    |             aq start myproject (with hostfwd for SSH port + proxy ports)
    |             QEMU launches with: -netdev user,hostfwd=tcp::$ssh_port-:22
    v
[ssh_wait_ready] --> retry loop: ssh -p $ssh_port localhost "echo ready"
    |                  (timeout after N seconds)
    v
[setup_provision_guest] --> ssh into guest, run:
    |                         apk add claude-code codex tmux git openssh
    |                         configure ANTHROPIC_BASE_URL=http://10.0.2.2:$anthropic_port
    |                         configure OPENAI_BASE_URL=http://10.0.2.2:$openai_port
    v
[git_setup_remote] --> ssh into guest: git init /workspace
    |                    on host: git remote add guest ssh://root@localhost:$ssh_port/workspace
    |                    host: git push guest HEAD
    v
[done] --> "VM 'myproject' ready. Run: lr code myproject"
```

### Flow 2: `lr code` -- Attach to Coding Session

```
User: lr code myproject
    |
    v
[lr dispatch] --> case "code"
    |
    v
[config_load] --> read state from ~/.local/state/ailockr/vms/myproject/
    |               (ssh_port, verify VM is running)
    v
[vm_ensure_running] --> check aq status; if stopped, start VM + Caddy
    |
    v
[ssh_attach_tmux] --> ssh -t -p $ssh_port localhost "tmux new-session -A -s code"
    |                   (-A flag: attach if exists, create if not)
    |                   (-t flag: force pseudo-terminal allocation)
    v
[user in tmux session inside guest VM]
    |
    v
[user runs claude code or codex in "danger mode"]
    |
    v
[agent API calls] --> guest: curl http://10.0.2.2:$anthropic_port/v1/messages
    |                   --> host: Caddy receives, injects Authorization header
    |                   --> upstream: api.anthropic.com (HTTPS)
    v
[agent response] <-- flows back through Caddy to guest
```

### Flow 3: API Request Proxying (Caddy)

```
Guest (Claude Code)                Host (Caddy)                    Upstream
==================                 ============                    ========
POST http://10.0.2.2:PORT          Receive on :PORT
  /v1/messages                       |
  Body: {model, messages}            v
  No Authorization header          Match route /v1/*
                                     |
                                     v
                                   header_up Authorization
                                     "Bearer sk-ant-xxx..."
                                     |
                                     v
                                   reverse_proxy https://api.anthropic.com
                                     |                    |
                                     v                    v
                                   Response <--------  API response
                                     |
                                     v
                                   Forward back to guest
```

### Flow 4: Git Sync Between Host and Guest

```
Host working tree              Guest working tree
================               ==================
myproject/                     /workspace/
  .git/                          .git/
    remotes/guest                  (no remotes to host)

Host pushes code to guest:
  host$ git push guest main    --> SSH tunnel --> guest receives push

Host pulls code from guest:
  host$ git pull guest main    --> SSH tunnel --> guest serves objects

Guest has no outbound git access to GitHub or any remote.
All external git operations happen on the host side.
```

### Key Data Flows

1. **API key flow:** Keys never enter the VM. They stay in the host environment (or host-side config). Caddy reads them from environment variables or the Caddyfile and injects them into upstream requests. The guest only knows the proxy URL (http://10.0.2.2:PORT), not the API key.

2. **Code flow:** Code enters the guest via `git push guest` from the host. Code exits the guest via `git pull guest` on the host. No other file transfer mechanism exists. This is the "airlock" -- git is the only passage.

3. **SSH flow:** SSH traffic is port-forwarded through QEMU user-mode networking (`hostfwd`). The host connects to `localhost:$ssh_port`, which QEMU forwards to guest port 22. No SSH keys for external services exist in the guest.

4. **Config flow (opt-in):** When `lr new --config claude` is specified, specific config files are `scp`-ed into the guest during provisioning. This is explicit, per-file, and one-directional (host to guest). The user decides what leaks through the airlock.

## Scaling Considerations

This is a single-user, local-machine tool. Traditional scaling concerns (users, requests, databases) do not apply. The relevant scaling dimensions are:

| Scale | Architecture Adjustments |
|-------|--------------------------|
| 1 VM | Default case. Single port set, single Caddy instance. No contention. |
| 2-5 concurrent VMs | Port allocation must avoid collisions (the `ports.lock` file). Each VM gets its own Caddy config block or separate Caddy instance. Memory pressure from multiple QEMU instances is the real limit. |
| 5+ concurrent VMs | Consider a single shared Caddy instance with per-VM route blocks instead of per-VM Caddy processes. Port range allocation becomes important. Host memory and CPU become the bottleneck (1 vCPU + RAM per VM). |

### Scaling Priorities

1. **First bottleneck -- host memory:** Each QEMU VM consumes RAM (default 256MB-512MB via aq). With 5+ VMs, an 8GB host starts to feel it. Mitigation: make RAM configurable, warn users.
2. **Second bottleneck -- port exhaustion/collision:** Multiple VMs each need 3 ports (SSH, Anthropic proxy, OpenAI proxy). A port allocator that tracks in-use ports is essential even at 2 VMs. Use a port range (e.g., 10000-10999) and a lockfile.

## Anti-Patterns

### Anti-Pattern 1: Monolithic Entry Script

**What people do:** Put all logic in a single 500+ line shell script.
**Why it's wrong:** Impossible to test individual functions, difficult to read, merge conflicts in collaborative development, slow to source when only one command is needed.
**Do this instead:** Split into `lib/` modules sourced on demand. Keep the entry script under 50 lines -- just dispatch logic.

### Anti-Pattern 2: Putting API Keys in the Guest

**What people do:** Copy `.env` files or set `ANTHROPIC_API_KEY` inside the VM for convenience.
**Why it's wrong:** Defeats the entire security model. An agent in "danger mode" with internet access can trivially exfiltrate the key via `curl`.
**Do this instead:** Use the Caddy reverse proxy pattern. Guest agents use `ANTHROPIC_BASE_URL`/`OPENAI_BASE_URL` pointing to the host proxy. The key never crosses the airlock.

### Anti-Pattern 3: Shared Mutable State Without Locking

**What people do:** Multiple commands read/write the same state files (ports, PIDs) without coordination.
**Why it's wrong:** Race conditions when running `lr new` in parallel (e.g., from different terminals). Two VMs could get the same port.
**Do this instead:** Use a lockfile (`flock`) around port allocation and state file writes. Keep the critical section small.

### Anti-Pattern 4: SSH Agent Forwarding into the Guest

**What people do:** Enable SSH agent forwarding (`-A` flag) so the guest can use host SSH keys.
**Why it's wrong:** The guest can now authenticate as the user to GitHub, other servers, etc. This is a massive privilege escalation that bypasses the isolation model.
**Do this instead:** Never forward the SSH agent. The guest communicates with the host only via the git remote over the port-forwarded SSH connection. The guest has no SSH identity for external services.

### Anti-Pattern 5: Blocking on VM Boot Without Timeout

**What people do:** Wait indefinitely for SSH to become available after VM creation.
**Why it's wrong:** If the VM fails to boot (disk corruption, package install failure, kernel panic), the script hangs forever.
**Do this instead:** Use a retry loop with a timeout (e.g., 60 seconds, 1-second intervals). On timeout, print diagnostics and clean up.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| Anthropic API | Caddy reverse proxy with `header_up Authorization "Bearer $KEY"` | Guest hits `http://10.0.2.2:PORT/v1/messages`. Caddy proxies to `https://api.anthropic.com`. |
| OpenAI API | Same Caddy pattern, separate port/route | Guest hits `http://10.0.2.2:PORT/v1/...`. Caddy proxies to `https://api.openai.com`. |
| `aq` (QEMU wrapper) | CLI invocation: `aq new`, `aq start`, `aq stop`, `aq destroy` | lr wraps aq with additional port forwarding flags and state tracking. |
| Caddy | CLI invocation: `caddy start`, `caddy stop`, `caddy reload` | Managed per-VM or shared. Admin API at `localhost:2019` available for health checks. |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| lr <-> aq | Shell subprocess (`aq` CLI invocation) | lr adds QEMU flags (hostfwd) via aq's passthrough mechanism. |
| lr <-> Caddy | Shell subprocess + generated Caddyfile | lr generates config, starts Caddy, tracks PID. Caddy's admin API can be used for health checks. |
| lr <-> guest VM | SSH over port-forwarded connection | All guest interaction (provisioning, tmux, git) goes through SSH. |
| host git <-> guest git | SSH transport via `git push`/`git pull` to `ssh://root@localhost:PORT/workspace` | No git protocol server needed -- SSH + git is sufficient. |
| guest agents <-> Caddy | HTTP over QEMU user-mode networking (10.0.2.2) | Guest sees host services at the gateway IP. No special networking config in guest. |

### Suggested Build Order

Based on the dependency graph between components:

1. **Phase 1: VM lifecycle + SSH** -- `lib/vm.sh`, `lib/ssh.sh`, `lib/config.sh`. Without a running VM you can SSH into, nothing else works. This validates aq integration and port forwarding.
2. **Phase 2: Caddy proxy** -- `lib/proxy.sh`, `templates/Caddyfile.template`. Once you can SSH in, add the proxy so API keys stay on the host. This is the core security boundary.
3. **Phase 3: Guest provisioning** -- `lib/setup.sh`. Install packages, set env vars. Depends on SSH (Phase 1) and proxy config (Phase 2, for setting `*_BASE_URL`).
4. **Phase 4: Git remote** -- `lib/git.sh`. Set up the code bridge. Depends on SSH (Phase 1) and a provisioned guest with git (Phase 3).
5. **Phase 5: Session management** -- Enhance `lib/ssh.sh` with tmux attach/create. The `lr code` command. Depends on everything above being stable.
6. **Phase 6: Polish** -- Config copying (`--config` flag), shell completions, installer, error messages, cleanup on failure.

## Sources

- [QEMU Networking Documentation](https://www.qemu.org/docs/master/system/devices/net.html) -- user-mode networking, 10.0.2.2 gateway, hostfwd syntax
- [QEMU/Networking Wikibook](https://en.wikibooks.org/wiki/QEMU/Networking) -- user-mode network topology (10.0.2.x subnet)
- [Caddy reverse_proxy documentation](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) -- `header_up` for injecting Authorization headers upstream
- [Caddy Admin API documentation](https://caddyserver.com/docs/api) -- programmatic lifecycle management, /stop endpoint
- [Claude Code LLM Gateway docs](https://code.claude.com/docs/en/llm-gateway) -- ANTHROPIC_BASE_URL configuration for custom API endpoints
- [OpenAI Codex Advanced Configuration](https://developers.openai.com/codex/config-advanced) -- openai_base_url and OPENAI_BASE_URL for custom endpoints
- [Git on the Server (official docs)](https://git-scm.com/book/en/v2/Git-on-the-Server-Setting-Up-the-Server) -- bare repository setup over SSH
- [XDG Base Directory Specification](https://wiki.archlinux.org/title/XDG_Base_Directory) -- XDG_STATE_HOME for runtime state, XDG_CONFIG_HOME for config
- [Command Line Interface Guidelines](https://clig.dev/) -- CLI design best practices for subcommand tools
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) -- shell script structure and naming conventions
- [SSH+tmux auto-attach pattern](https://rsadowski.de/posts/2025/ssh-tmux-reattach/) -- `tmux new-session -A -s` for attach-or-create semantics
- [wizetek/qvm](https://github.com/wizetek/qvm) -- reference QEMU wrapper script architecture

---
*Architecture research for: Shell-based CLI tool managing QEMU VMs for AI agent isolation*
*Researched: 2026-03-24*
