---
phase: 03-agent-provisioning
plan: 01
subsystem: provisioning
tags: [claude-code, codex, npm, alpine, agent-install, bash]

# Dependency graph
requires:
  - phase: 02-security-boundary
    provides: "Caddy proxy with ANTHROPIC_BASE_URL/OPENAI_BASE_URL in mise.toml, dummy API keys"
provides:
  - "lib/agent.sh module with validate_agent_host() and install_agent_in_guest() functions"
  - "--agent flag on rl new for conditional agent installation"
  - "Claude Code installed with bypassPermissions mode inside guest VM"
  - "Codex installation function ready (deferred e2e testing per D-08)"
affects: [04-code-bridge]

# Tech tracking
tech-stack:
  added: ["@anthropic-ai/claude-code (npm)", "@openai/codex (npm)", "nodejs", "npm", "libgcc", "libstdc++"]
  patterns: ["separate aq exec heredoc per agent", "flag accumulation via bash array", "AGENT_OK sentinel for install verification"]

key-files:
  created: [lib/agent.sh]
  modified: [lib/vm.sh, bin/rl]

key-decisions:
  - "Separate aq exec calls per agent rather than one monolithic heredoc -- better error isolation"
  - "bypassPermissions via settings.json rather than CLI alias -- works for all invocation styles"
  - "Codex config.toml written alongside mise env var for belt-and-suspenders coverage (Pitfall 5)"
  - "npm cache directed to /tmp and cleaned up to avoid filling 1GB qcow2 disk (Pitfall 6)"

patterns-established:
  - "Pattern: AGENT_OK sentinel -- agent install heredocs echo AGENT_OK on success, caller checks with grep"
  - "Pattern: warn-not-block -- host binary validation warns but does not die, allowing proxy-only setups"
  - "Pattern: flag accumulation array -- local agents=() collects repeated --agent flags for loop processing"

requirements-completed: [AGENT-01]

# Metrics
duration: 2min
completed: 2026-03-28
---

# Phase 3 Plan 1: Agent Provisioning Summary

**--agent flag on rl new installs Claude Code and/or Codex inside guest VMs with bypassPermissions mode and proxy routing**

## Performance

- **Duration:** 2 min
- **Started:** 2026-03-27T23:05:52Z
- **Completed:** 2026-03-27T23:08:19Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Created lib/agent.sh with validate_agent_host() and install_agent_in_guest() dispatching to _install_claude_code and _install_codex
- Added --agent flag parsing to cmd_new() with while/case/shift pattern, supporting multiple agents
- Claude Code installs with nodejs, npm, libgcc, libstdc++, writes settings.json for bypassPermissions
- Codex installs with nodejs, npm, writes config.toml with openai_base_url as backup to mise env var
- Failed agent installs warn but do not block -- VM remains usable without agents
- Host binary validation warns if claude/codex not found (proxy may lack credentials)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create lib/agent.sh with agent validation and installation functions** - `50cf3a8` (feat)
2. **Task 2: Add --agent flag to cmd_new() and wire agent.sh into dispatch** - `fb3d8dd` (feat)

## Files Created/Modified
- `lib/agent.sh` - Agent validation and installation functions (validate_agent_host, install_agent_in_guest, _install_claude_code, _install_codex)
- `lib/vm.sh` - Added --agent flag parsing and agent installation loop after base provisioning in cmd_new()
- `bin/rl` - Sources agent.sh in new) dispatch case, updated help text to show --agent

## Decisions Made
- Separate aq exec calls per agent for independent error handling (not one giant heredoc)
- settings.json with bypassPermissions over CLI alias for persistence across all invocation styles
- npm cache to /tmp with cleanup to preserve disk space on 1GB qcow2 images
- Codex config.toml written as belt-and-suspenders with mise env var

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Agent installation infrastructure complete, ready for Phase 4 (code-bridge)
- Codex e2e testing deferred per D-08 until host with codex binary is available
- ANTHROPIC_BASE_URL and OPENAI_BASE_URL already configured by Phase 2 mise.toml

## Self-Check: PASSED

- [x] lib/agent.sh exists
- [x] 03-01-SUMMARY.md exists
- [x] Commit 50cf3a8 found
- [x] Commit fb3d8dd found

---
*Phase: 03-agent-provisioning*
*Completed: 2026-03-28*
