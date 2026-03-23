# Feature Research

**Domain:** VM-based AI agent isolation CLI tools
**Researched:** 2026-03-24
**Confidence:** HIGH

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = product feels incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| VM creation from CLI | Every competitor (claudebox, Docker Sandboxes, Daytona) offers single-command environment creation. Users expect `lr new` to just work. | LOW | Built on aq which handles Alpine VM lifecycle. The hard part is post-provisioning (installing tools). |
| SSH access into VM | Users need to interact with the running agent, inspect output, debug. Docker Sandboxes uses `docker sandbox run`, claudebox has `claudebox run`. | LOW | aq already provides SSH. `lr code` wraps this with tmux session attachment. |
| Git-based code exchange | Git is the universal code transport. Sandbox-claude uses deploy keys, Docker Sandboxes mounts workspace, Fly.io Sprites use persistent filesystems. Host-guest git remote is the clean approach for VM isolation. | MEDIUM | Requires setting up host as git remote from guest, managing push/pull workflow. Must handle branch conventions. |
| API key protection | The #1 reason users adopt sandboxes. Every tool addresses this: Docker Sandboxes passes env vars through hypervisor, sandbox-claude uses deploy keys, Anthropic's own sandbox uses JWT-scoped egress proxies. Keys must never enter the VM. | MEDIUM | Caddy reverse proxy on host injects Authorization headers. Guest uses ANTHROPIC_BASE_URL / OPENAI_BASE_URL to route through host proxy at 10.0.2.2. |
| Agent pre-installation | Users expect the sandbox to come ready with their agent. Docker Sandboxes includes Claude Code + Codex + dev tools. claudebox includes Claude Code. Nobody wants to manually install agents after VM boot. | MEDIUM | Alpine package availability may limit options. Claude Code binary install with checksum verification (like ExitBox does) is the right approach. |
| Session persistence | Fly.io Sprites persist across sessions. Daytona preserves filesystem + env + process state. Users expect to stop working, come back later, and resume. Per-repo VM lifecycle (not ephemeral per-command) is expected. | LOW | aq VMs persist by default. `lr code` reconnects to existing tmux session. This is table stakes but essentially free with the architecture. |
| Resource limits | Users need to constrain VM resource consumption so it does not starve the host. Docker Sandboxes runs in a microVM with defined resources. E2B and Northflank enforce CPU/memory/disk quotas. | LOW | aq handles defaults (1 vCPU, 1GB disk). Should be configurable but defaults must be sane. |
| Internet access from VM | Agents need to install packages (npm, pip, apk), fetch documentation, and access web resources. Docker Sandboxes, Daytona, and Fly.io Sprites all provide internet access. | LOW | QEMU user-mode networking provides this by default. No extra work needed. |

### Differentiators (Competitive Advantage)

Features that set the product apart. Not required, but valuable.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Host-side API proxy with header injection | Unlike Docker Sandboxes (which pass API keys as env vars into the sandbox) or sandbox-claude (which uses deploy keys scoped per-service), AILockr's Caddy proxy means the API key literally never enters the VM at all -- not in env vars, not in config files, not in process memory. The agent calls a local URL, the host injects auth. This is architecturally superior to every competitor. | MEDIUM | Caddy config is ~10 lines. The complexity is in making it reliable: health checks, error handling, multi-provider support (Anthropic + OpenAI simultaneously). |
| True VM isolation (not containers) | Docker Sandboxes markets "microVM" but actually runs Docker inside a VM -- muddying the boundary. claudebox uses libkrun/Firecracker. DevContainer approaches use Docker (shared kernel = weaker isolation). AILockr uses QEMU with a separate kernel, which is the gold standard for isolation. No shared kernel attack surface. | LOW | aq handles this. The differentiator is communicating it clearly: "QEMU VM with its own kernel" beats "container with cgroup isolation." |
| Opt-in config copying | Most tools either copy everything (Docker Sandboxes mounts workspace) or nothing (bare sandbox). ExitBox has an encrypted vault for secrets but it is complex. AILockr's `lr new --config claude --config git` approach lets users explicitly choose what crosses the airlock. No accidental secret leakage, no complex vault system. | MEDIUM | Need a registry of known config types (claude = ~/.claude/settings.json, git = ~/.gitconfig minus credential helpers, etc.) with safe defaults that strip sensitive fields. |
| Shell-script simplicity | Every competitor is a compiled binary (claudebox = Python, Docker Sandboxes = Go, Daytona = Go, E2B = TypeScript SDK). A POSIX shell script with zero compile step means users can read, audit, fork, and modify the tool trivially. For a security tool, auditability is a feature. | LOW | Constraint from PROJECT.md. The trick is keeping it simple enough that shell remains viable as features grow. |
| PR review mode | Sandbox-claude mentions this as a use case but does not implement it as a first-class feature. Running `lr review <PR-URL>` to fetch a PR into a sandboxed VM, let an agent analyze it, and output a review is a unique workflow. Maintainers can safely run untrusted PR code without risking their host. | HIGH | Requires: fetching PR diff/branch, setting up the repo state in VM, running agent with review-specific prompt, extracting output back to host. Multiple subsystems must coordinate. |
| Git-only bridge (no filesystem mounts) | Docker Sandboxes mounts your project directory. DevContainers mount workspace. This means the agent has direct filesystem access to host files. AILockr communicates only via git -- the agent commits, pushes to host remote, and the host decides what to merge. This is a stronger security boundary than any mount-based approach. | LOW | Already the core architecture. The differentiator is in the workflow: push from guest, pull/review on host. No mount = no accidental host file mutation. |
| Multi-agent support (multiple VMs) | sandbox-claude supports parallel agents in separate Incus containers. Codex supports sub-agents. Running `lr new repo-feature-a` and `lr new repo-feature-b` for parallel isolated agents on the same repo (different branches) is powerful for divide-and-conquer workflows. | MEDIUM | Each VM is independent (different git branches). The complexity is in managing multiple VMs per repo, port allocation for Caddy proxies, and merging results. |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Network egress filtering | Security-conscious users want to restrict outbound connections to only approved domains (like sandbox-claude does with iptables allowlists). | Adds significant complexity (iptables/nftables management, domain allowlist maintenance, breaks legitimate package installs when allowlist is incomplete). The threat model for AILockr is "agent cannot exfiltrate host secrets" -- which is already solved by not putting secrets in the VM. Egress filtering solves a different threat (agent phones home with generated code) that is lower priority. | Trust the isolation boundary. The VM has no host secrets to exfiltrate. If egress filtering is ever needed, add it as an optional layer, never as default. |
| GUI/browser access inside VM | claudebox supports GUI capabilities. agent-infra/sandbox includes a browser and VSCode Server. Users may want to visually inspect agent output. | VMs without display servers are simpler and more resource-efficient. Adding X11/VNC/browser support to Alpine is heavy, fragile, and unnecessary for CLI-based coding agents. It contradicts the "lightweight VM" value proposition. | Agent output is text (diffs, logs, code). Use `lr diff` or `lr log` on the host to inspect results. |
| Pre-built VM images / golden images | sandbox-claude uses btrfs snapshots of pre-built images for instant container creation. Users may want to skip the package installation step. | Creates distribution/hosting burden (where to store images?), version management headaches, and reproducibility issues. aq installs packages fast enough on Alpine that the cold-start penalty is small (seconds, not minutes). Golden images also drift from upstream packages. | Use aq's native Alpine package installation. Cache the installed state in the VM itself (VMs persist). First boot is slightly slower; every subsequent boot is instant. |
| Docker-inside-VM | Docker Sandboxes runs Docker inside its microVM. sandbox-claude gives each container its own Docker daemon. Agents sometimes want to build/run containers. | Running Docker inside a QEMU VM adds a virtualization layer inside a virtualization layer. It increases resource requirements dramatically, complicates networking, and is fragile on Alpine. The core use case is code editing, not container orchestration. | If the agent needs to test a Dockerfile, it can write it and push via git. The host can build/run it. Keeps the VM lightweight. |
| Web dashboard / monitoring UI | Daytona and Northflank offer web dashboards for managing sandboxes. Users may expect visual management. | Contradicts the CLI-first philosophy. A web UI requires a server process, auth, frontend assets -- massive scope expansion for marginal value. The target user is a developer comfortable with terminal. | `lr list`, `lr status`, `lr logs` provide all management through the CLI. tmux-based session management is sufficient. |
| Automatic secret detection / scanning | ExitBox has an encrypted vault with per-access approval popups. Users may want the tool to detect when secrets are about to leak. | Adds complexity (secret pattern matching is imperfect), false positives annoy users, and it solves the wrong problem. AILockr's architecture means secrets never enter the VM in the first place -- there is nothing to detect. | The proxy architecture makes this unnecessary. API keys are on the host, injected by Caddy. Config copying is opt-in with explicit flags. Prevention > detection. |
| Session recording / audit trail | NVIDIA's security guidance recommends audit logging for agentic workflows. Users in regulated environments may want full session replay. | Significant storage and performance overhead. Requires capturing terminal I/O, git operations, and network traffic. Overkill for personal/small-team use. Changes the tool from "lightweight sandbox" to "compliance platform." | Git history IS the audit trail. Every meaningful action results in a commit. `lr log` can show the sequence of pushes from guest to host. |
| Agent orchestration / task routing | Composio's agent-orchestrator and Codex sub-agents show demand for coordinating multiple agents on related tasks. | This is an orchestration problem, not an isolation problem. Mixing orchestration into the sandbox tool creates a monolithic system. Each agent should run in its own VM; how tasks are divided is a separate concern. | Support multiple VMs (`lr new repo-task-a`, `lr new repo-task-b`) but leave orchestration to the user or a separate tool. The sandbox should sandbox, not orchestrate. |

## Feature Dependencies

```
[API Key Protection (Caddy Proxy)]
    |
    +--requires--> [VM Creation]
    |                  |
    |                  +--requires--> [aq installed on host]
    |
    +--requires--> [Internet Access from VM]
                       (QEMU user-mode networking to reach 10.0.2.2)

[Git-Based Code Exchange]
    |
    +--requires--> [VM Creation]
    |
    +--requires--> [SSH Access]
    |
    +--enhances--> [PR Review Mode]

[Agent Pre-Installation]
    |
    +--requires--> [VM Creation]
    |
    +--requires--> [Internet Access from VM]
                       (to download Claude Code binary, npm packages)

[Opt-In Config Copying]
    |
    +--requires--> [VM Creation]
    |
    +--enhances--> [Agent Pre-Installation]
                       (agent configs like CLAUDE.md, .claude/settings.json)

[Session Persistence]
    |
    +--requires--> [VM Creation]
    |
    +--enhances--> [SSH Access]
                       (tmux session reconnection)

[PR Review Mode]
    |
    +--requires--> [Git-Based Code Exchange]
    +--requires--> [Agent Pre-Installation]
    +--requires--> [API Key Protection]

[Multi-Agent Support]
    |
    +--requires--> [VM Creation]
    +--requires--> [API Key Protection]
    +--requires--> [Git-Based Code Exchange]
    +--conflicts--> [Single Caddy Instance]
                       (need per-VM or shared proxy with port mapping)
```

### Dependency Notes

- **API Key Protection requires VM Creation + Internet Access:** The Caddy proxy runs on the host, but the VM must exist and have network access to reach 10.0.2.2 (QEMU gateway).
- **Git-Based Code Exchange requires SSH Access:** Setting up the host as a git remote from inside the VM requires SSH connectivity.
- **PR Review Mode requires three features:** It is the most dependent feature -- needs git (to fetch the PR), agent (to analyze it), and API proxy (for the agent to function). Build last.
- **Multi-Agent Support conflicts with single Caddy instance:** Multiple VMs hitting one Caddy proxy is fine (stateless), but each VM needs its own git remote setup and potentially its own branch. Port management becomes non-trivial.
- **Opt-In Config Copying enhances Agent Pre-Installation:** Agents work better when their config (CLAUDE.md, settings files) is present. Config copying is optional but improves the agent experience.

## MVP Definition

### Launch With (v1)

Minimum viable product -- what is needed to validate the concept.

- [ ] **VM creation with agent installed** (`lr new`) -- Without this, nothing works. Alpine VM via aq with Claude Code and Codex pre-installed.
- [ ] **SSH into VM with tmux session** (`lr code`) -- Users need to interact with the agent. tmux provides session persistence for free.
- [ ] **Host as git remote** -- The code bridge. Guest pushes, host pulls. This is the core of the "airlock" concept.
- [ ] **Caddy API proxy with header injection** -- The security differentiator. API keys never enter the VM. This is what makes AILockr worth using over "just SSH into a server."
- [ ] **Basic resource limits** -- 1 vCPU, 1GB disk via aq defaults. Prevents runaway agents from killing the host.

### Add After Validation (v1.x)

Features to add once core is working.

- [ ] **Opt-in config copying** (`lr new --config claude --config git`) -- Add when users complain about manually setting up agent configs in the VM.
- [ ] **VM listing and status** (`lr list`, `lr status`) -- Add when managing multiple VMs becomes painful.
- [ ] **Multi-agent support** (multiple VMs per repo on different branches) -- Add when users want to parallelize work.
- [ ] **Configurable resource limits** (`lr new --disk 2G --cpus 2`) -- Add when the 1GB default is too limiting for real projects.

### Future Consideration (v2+)

Features to defer until product-market fit is established.

- [ ] **PR review mode** (`lr review <PR-URL>`) -- High complexity, requires multiple subsystems. Defer until core is rock-solid and user demand is validated.
- [ ] **VM snapshots / checkpointing** -- Fly.io Sprites and ConTree show demand but QEMU snapshotting adds complexity. Defer until session persistence via tmux is insufficient.
- [ ] **Multi-provider proxy** (support for Gemini, Mistral, etc.) -- Caddy can proxy anything, but each provider has different auth header formats. Add as demand emerges.
- [ ] **Installable package / Homebrew formula** -- Important for adoption but not for validating the core concept.

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| VM creation (lr new) | HIGH | LOW | P1 |
| SSH + tmux session (lr code) | HIGH | LOW | P1 |
| Git remote bridge | HIGH | MEDIUM | P1 |
| Caddy API proxy | HIGH | MEDIUM | P1 |
| Agent pre-installation | HIGH | MEDIUM | P1 |
| Resource limits (defaults) | MEDIUM | LOW | P1 |
| Opt-in config copying | MEDIUM | MEDIUM | P2 |
| VM lifecycle management (lr list/status/rm) | MEDIUM | LOW | P2 |
| Configurable resource limits | LOW | LOW | P2 |
| Multi-agent (multiple VMs) | MEDIUM | MEDIUM | P2 |
| PR review mode | HIGH | HIGH | P3 |
| VM snapshots | MEDIUM | HIGH | P3 |
| Multi-provider proxy | LOW | MEDIUM | P3 |
| Homebrew/install packaging | MEDIUM | MEDIUM | P3 |

**Priority key:**
- P1: Must have for launch
- P2: Should have, add when possible
- P3: Nice to have, future consideration

## Competitor Feature Analysis

| Feature | Docker Sandboxes | claudebox | sandbox-claude | Daytona | Fly.io Sprites | AILockr (planned) |
|---------|-----------------|-----------|---------------|---------|----------------|-------------------|
| Isolation level | microVM (Docker inside VM) | microVM (libkrun/Firecracker) | Container (Incus) | Container (Docker) | VM (Firecracker) | VM (QEMU) -- strongest |
| API key handling | Env vars passed into sandbox | Env vars | Deploy keys per service | Env vars via SDK | Env vars | Proxy injection -- keys never enter VM |
| Code exchange | Filesystem mount | Filesystem mount | Git deploy keys | SDK/filesystem | Persistent filesystem | Git remote only -- no mounts |
| Config management | Docker image templates | Skills/templates | Golden images (btrfs) | Docker templates | Dockerfile | Opt-in explicit copying |
| Session persistence | Per-sandbox | Workspace persistence | Container lifecycle | Stateful sandboxes | Checkpoint/restore | Per-repo VM + tmux |
| CLI simplicity | `docker sandbox run` | `claudebox run` | Custom scripts | `daytona create` | API-first | `lr new` / `lr code` |
| Multi-agent | Not first-class | Not mentioned | Parallel containers | Via SDK | Multiple Sprites | Multiple VMs (planned) |
| Secret scanning | No | No | No (isolation-based) | No | No | No (prevention-based) |
| Cost model | Free (Docker Desktop) | Free (open source) | Free (open source) | Free tier + paid | Pay per CPU-hour | Free (open source, local) |
| Runs locally | Yes | Yes | Yes | Cloud or self-hosted | Cloud only | Yes -- fully local |
| Internet access | Yes | Yes | Filtered (egress rules) | Yes | Yes | Yes (unfiltered) |
| Audit trail | No | No | No | API logs | No | Git history |

## Sources

- [claudebox (BoxLite)](https://github.com/boxlite-ai/claudebox) -- micro-VM sandbox for Claude Code using libkrun/Firecracker
- [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/get-started/) -- Docker Desktop microVM sandboxes for coding agents
- [Daytona](https://github.com/daytonaio/daytona) -- secure infrastructure for AI-generated code execution
- [Fly.io Sprites](https://sprites.dev/) -- persistent stateful VMs for AI agents with checkpoint/restore
- [E2B](https://e2b.dev/) -- Firecracker-based cloud sandboxes with 150ms boot times
- [sandbox-claude (Pere Villega)](https://perevillega.com/posts/2026-03-03-ai-sandbox-coding-agents/) -- Incus containers with btrfs snapshots and egress filtering
- [ExitBox](https://medium.com/@cloud-exit/introducing-exitbox-run-ai-coding-agents-in-complete-isolation-6013fb5bdd06) -- container sandbox with encrypted vault and binary verification
- [Northflank sandbox comparison](https://northflank.com/blog/best-code-execution-sandbox-for-ai-agents) -- comprehensive sandbox platform comparison
- [Anthropic Claude Code sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing) -- official Anthropic engineering post on sandboxing approach
- [Using proxies to hide secrets (Formal)](https://www.formal.ai/blog/using-proxies-claude-code/) -- reverse proxy pattern for API key isolation
- [DevContainer isolation patterns](https://markphelps.me/posts/running-ai-agents-in-devcontainers/) -- devcontainer-based AI agent isolation
- [NVIDIA sandboxing guidance](https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/) -- enterprise security guidance for agentic workflows
- [ConTree](https://contree.dev/) -- git-like branching for sandbox execution environments
- [Docker Sandboxes blog post](https://www.docker.com/blog/docker-sandboxes-run-claude-code-and-other-coding-agents-unsupervised-but-safely/) -- Docker's approach to running agents safely

---
*Feature research for: VM-based AI agent isolation CLI tools*
*Researched: 2026-03-24*
