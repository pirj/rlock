# Roadmap: AILockr

## Overview

AILockr delivers VM-isolated AI agent execution in four phases: first a working CLI with VM lifecycle management, then the security boundary (Caddy proxy for API key injection), then agent provisioning inside the VM, and finally the git code bridge that completes the airlock. Each phase delivers a testable capability that builds on the previous one.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: CLI Skeleton and VM Lifecycle** - User can create, connect to, inspect, and destroy per-repo VMs via the `rl` CLI
- [ ] **Phase 2: Security Boundary** - API keys stay on the host; Caddy proxy injects auth headers for AI agent API calls
- [ ] **Phase 3: Agent Provisioning** - Claude Code and Codex are installed, configured, and functional inside the VM
- [ ] **Phase 4: Code Bridge** - Code moves between host and guest exclusively via git

## Phase Details

### Phase 1: CLI Skeleton and VM Lifecycle
**Goal**: Users can create, connect to, inspect, and destroy per-repo isolated VMs with a simple CLI
**Depends on**: Nothing (first phase)
**Requirements**: VM-01, VM-02, VM-03, SESS-01
**Success Criteria** (what must be TRUE):
  1. User can run `rl new` in a repo directory and get a running Alpine VM with SSH access, tmux, and git installed
  2. User can run `rl code` and land in a tmux session inside the VM, resuming a previous session if one exists
  3. User can run `rl status` and see whether the current repo has an attached airlock and its state
  4. User can run `rl rm` and the VM plus all associated resources are cleaned up
  5. The `rl` CLI dispatches subcommands via a modular lib/ structure with ShellCheck-clean code
**Plans**: TBD

### Phase 2: Security Boundary
**Goal**: API keys never enter the VM; a host-side Caddy reverse proxy injects Authorization headers so AI agents can call APIs without possessing secrets
**Depends on**: Phase 1
**Requirements**: SEC-01, SEC-02, SEC-03
**Success Criteria** (what must be TRUE):
  1. Caddy reverse proxy starts automatically during `rl new`, listening on a per-VM port with IP-restricted access (10.0.2.0/24 and 127.0.0.1 only)
  2. HTTP requests from inside the VM to http://10.0.2.2:<port> arrive at upstream Anthropic/OpenAI APIs with correct Authorization headers injected
  3. No API key, token, or credential exists anywhere inside the VM -- not in env vars, config files, shell history, or process memory
  4. Caddy lifecycle is tied to VM lifecycle -- proxy starts with `rl new`, stops with `rl rm`
**Plans**: TBD

### Phase 3: Agent Provisioning
**Goal**: Claude Code and Codex are installed and functional inside the VM, routing API calls through the host proxy
**Depends on**: Phase 2
**Requirements**: AGENT-01, AGENT-02
**Success Criteria** (what must be TRUE):
  1. Claude Code runs inside the VM and successfully completes an API call routed through the host Caddy proxy
  2. Codex runs inside the VM and successfully completes an API call routed through the host Caddy proxy
  3. ANTHROPIC_BASE_URL and OPENAI_BASE_URL env vars are automatically configured to point to the host proxy (http://10.0.2.2:<port>)
**Plans**: TBD

### Phase 4: Code Bridge
**Goal**: Code moves between host and guest exclusively via git, completing the airlock
**Depends on**: Phase 1
**Requirements**: CODE-01
**Success Criteria** (what must be TRUE):
  1. Host has a git remote pointing to the guest VM, added automatically during `rl new`
  2. User can fetch commits made by AI agents inside the VM to the host repo using standard git commands
  3. No filesystem mounts, shared directories, or non-git data channels exist between host and guest
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. CLI Skeleton and VM Lifecycle | 0/0 | Not started | - |
| 2. Security Boundary | 0/0 | Not started | - |
| 3. Agent Provisioning | 0/0 | Not started | - |
| 4. Code Bridge | 0/0 | Not started | - |
