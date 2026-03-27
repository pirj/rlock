---
phase: 03-agent-provisioning
verified: 2026-03-28T12:00:00Z
status: human_needed
score: 5/6 must-haves verified
gaps: []
human_verification:
  - test: "Run `rl new --agent claude` and verify Claude Code installs and can make an API call through the Caddy proxy"
    expected: "Claude Code installs without errors, `claude --version` works inside the VM, and an API call routed through http://10.0.2.2:9110 succeeds"
    why_human: "Requires a running QEMU VM with network access to the host Caddy proxy. Cannot verify npm install success or network routing programmatically without executing the full VM lifecycle."
  - test: "Run `rl new --agent codex` and verify Codex installs (when host codex binary becomes available)"
    expected: "Codex installs inside the VM, `codex --version` works, and an API call through http://10.0.2.2:9111 succeeds"
    why_human: "Codex e2e validation explicitly deferred per locked decision D-08 (no host codex binary available). The installation function is implemented but untested end-to-end."
  - test: "Run `rl new` without --agent and verify no nodejs/npm packages are installed"
    expected: "VM provisions with base packages only (tmux, git, bash, curl, mise). No nodejs or npm present."
    why_human: "Requires running the VM and checking installed packages. Cannot verify without executing the full provisioning flow."
---

# Phase 3: Agent Provisioning Verification Report

**Phase Goal:** Claude Code and Codex are installed and functional inside the VM, routing API calls through the host proxy
**Verified:** 2026-03-28T12:00:00Z
**Status:** human_needed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Running `rl new --agent claude` installs Claude Code inside the guest VM and it can execute API calls through the host proxy | ? UNCERTAIN | `_install_claude_code` function exists with correct `aq exec` heredoc: installs nodejs, npm, libgcc, libstdc++, runs `npm install -g @anthropic-ai/claude-code`, writes settings.json, verifies with `claude --version`. All code is correct but requires live VM to confirm end-to-end. |
| 2 | Running `rl new --agent codex` executes the Codex installation function; functional validation deferred per D-08 | VERIFIED | `_install_codex` function exists with `aq exec` heredoc: installs nodejs, npm, runs `npm install -g @openai/codex`, writes config.toml with `openai_base_url`, verifies with `codex --version`. Function is called via `install_agent_in_guest`. Deferral is a known scope limitation (D-08), not a gap. |
| 3 | Running `rl new` without --agent installs no agents (no nodejs/npm overhead) | VERIFIED | `cmd_new()` initializes `local agents=()` and the agent installation loop `for agent in "${agents[@]}"` iterates zero times when empty. No agent code runs. nodejs/npm installation is only inside `_install_claude_code` and `_install_codex` heredocs, not in the base provisioning heredoc. |
| 4 | If the host lacks the `claude` or `codex` binary, `rl new --agent <name>` warns but does not block | VERIFIED | `validate_agent_host` uses `command -v` and calls `warn` (not `die`). No `exit` or `return 1` in the function. Failed installs also warn: `warn "Failed to install $agent. VM is usable without it."` |
| 5 | Claude Code inside the VM runs with bypassPermissions mode by default (settings.json) | VERIFIED | `_install_claude_code` writes `/root/.claude/settings.json` with `{"permissions":{"defaultMode":"bypassPermissions"}}` via heredoc. Confirmed at lib/agent.sh lines 64-71. |
| 6 | ANTHROPIC_BASE_URL and OPENAI_BASE_URL are automatically configured to point to the host proxy | VERIFIED | Set in vm.sh base provisioning heredoc (Phase 2): `ANTHROPIC_BASE_URL = "http://10.0.2.2:9110"` and `OPENAI_BASE_URL = "http://10.0.2.2:9111"` in mise.toml. Additionally, Codex config.toml provides belt-and-suspenders coverage with `openai_base_url = "http://10.0.2.2:9111/v1"`. |

**Score:** 5/6 truths verified (1 uncertain -- requires live VM testing)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/agent.sh` | Agent installation functions for Claude Code and Codex | VERIFIED | 104 lines. Contains `validate_agent_host`, `install_agent_in_guest`, `_install_claude_code`, `_install_codex`. ShellCheck clean. Has `# shellcheck shell=bash` directive. |
| `lib/vm.sh` | Updated cmd_new() with --agent flag parsing and agent installation loop | VERIFIED | `--agent` flag parsing via while/case/shift (lines 46-78). Agent installation loop (lines 181-193). --help with usage examples. |
| `bin/rl` | Updated dispatch sourcing agent.sh for new command | VERIFIED | Line 43: `. "$LIB_DIR/agent.sh"`. Help text updated: `new      Create a new isolated VM for the current repo (--agent claude\|codex)` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| lib/vm.sh | lib/agent.sh | source and function calls | WIRED | vm.sh calls `validate_agent_host "$agent"` (line 183) and `install_agent_in_guest "$vm_name" "$agent"` (line 186). agent.sh is sourced via bin/rl dispatch. |
| lib/agent.sh | aq exec | heredoc provisioning | WIRED | `_install_claude_code` uses `aq exec "$vm_name" <<'PROVISION_CLAUDE'` (line 53). `_install_codex` uses `aq exec "$vm_name" <<'PROVISION_CODEX'` (line 83). Both heredocs contain substantive provisioning code. |
| bin/rl | lib/agent.sh | source in new case | WIRED | Line 43: `. "$LIB_DIR/agent.sh"` in the `new)` case block, before `cmd_new "$@"` is called. |

### Data-Flow Trace (Level 4)

Not applicable -- this phase produces shell script modules (not components rendering dynamic data). The data flow is: user passes `--agent claude` -> flag parsed into `agents` array -> array iterated -> `install_agent_in_guest` called -> `aq exec` heredoc runs inside VM. This is a command-line invocation flow, not a data rendering pipeline.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| agent.sh passes ShellCheck | `shellcheck --severity=warning lib/agent.sh` | Exit 0, no warnings | PASS |
| vm.sh passes ShellCheck | `shellcheck --severity=warning lib/vm.sh` | Exit 0, no warnings | PASS |
| bin/rl passes ShellCheck | `shellcheck --severity=warning bin/rl` | Exit 0, no warnings | PASS |
| Commit 50cf3a8 exists | `git log 50cf3a8 --oneline -1` | `feat(03-01): create lib/agent.sh...` | PASS |
| Commit fb3d8dd exists | `git log fb3d8dd --oneline -1` | `feat(03-01): add --agent flag...` | PASS |
| Claude Code npm package name correct | grep in agent.sh | `@anthropic-ai/claude-code` | PASS |
| Codex npm package name correct | grep in agent.sh | `@openai/codex` | PASS |
| bypassPermissions in settings.json | grep in agent.sh | `"defaultMode": "bypassPermissions"` present | PASS |
| AGENT_OK sentinel in both install functions | grep in agent.sh | Found in `_install_claude_code` (line 76) and `_install_codex` (line 102) | PASS |

Step 7b: Live VM testing SKIPPED (requires running QEMU VM with aq -- cannot execute provisioning without full VM lifecycle).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| AGENT-01 | 03-01-PLAN.md | Claude Code is pre-installed and functional inside the VM | SATISFIED (code complete, needs human e2e) | `_install_claude_code` function installs Claude Code via npm with all required dependencies (nodejs, npm, libgcc, libstdc++), writes bypassPermissions settings.json, verifies installation. Wired into `cmd_new --agent claude` flow. |
| AGENT-02 | (not claimed by any plan) | Codex is pre-installed and functional inside the VM | KNOWN DEFERRAL (D-08) | `_install_codex` function is fully implemented (npm install, config.toml, verification). However, e2e validation is explicitly deferred per locked decision D-08 because no host codex binary is available. The plan declares `requirements: [AGENT-01]` only. This is a documented scope limitation, not a gap. |

**Note on AGENT-02:** The ROADMAP maps AGENT-02 to Phase 3, and REQUIREMENTS.md shows it as "Pending". The plan explicitly does not claim AGENT-02 coverage per D-08. The installation code is implemented but untested end-to-end. Per the user's instruction, this is treated as a known scope limitation rather than a verification gap.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | - | - | - | No TODO, FIXME, placeholder, or stub patterns found in any modified file |

No anti-patterns detected. All three modified files (lib/agent.sh, lib/vm.sh, bin/rl) are clean of TODOs, FIXMEs, placeholder text, empty implementations, and console.log-only handlers.

### Human Verification Required

### 1. Claude Code End-to-End Installation

**Test:** Run `rl new --agent claude` in a repo directory with a valid Anthropic API key configured
**Expected:** VM creates, Claude Code installs via npm, `claude --version` succeeds inside the VM, and running `claude` can reach the Anthropic API through the Caddy proxy at http://10.0.2.2:9110
**Why human:** Requires live QEMU VM with network access to host. Cannot verify npm install success on Alpine/musl, or network routing through SLIRP, without executing the full VM lifecycle.

### 2. Codex End-to-End Installation (when available)

**Test:** Run `rl new --agent codex` on a host where the `codex` binary is available
**Expected:** Codex installs inside the VM, `codex --version` succeeds, config.toml is written, API calls route through http://10.0.2.2:9111
**Why human:** Deferred per D-08. Requires host with codex binary and OpenAI credentials.

### 3. No-Agent Provisioning

**Test:** Run `rl new` without any `--agent` flag
**Expected:** VM provisions with base packages only. Running `which node` or `which npm` inside the VM should return "not found".
**Why human:** Requires live VM to verify package state.

### 4. Failed Agent Install Graceful Degradation

**Test:** Simulate a network failure or unavailable npm registry during `rl new --agent claude`
**Expected:** Agent installation fails with a warning message, but the VM remains usable. User sees "Failed to install claude. VM is usable without it." and can still `rl code` into the VM.
**Why human:** Requires simulating failure conditions in a live VM environment.

### Gaps Summary

No code-level gaps were found. All artifacts exist, are substantive (not stubs), are properly wired, and pass ShellCheck. The implementation matches the plan exactly with no deviations.

The only items requiring further validation are live VM e2e tests, which cannot be performed programmatically. The code is structurally complete and correct -- it follows established patterns (`aq exec` heredocs, while/case/shift parsing, warn-not-block), uses correct npm package names, writes correct configuration files, and handles errors gracefully.

AGENT-02 (Codex) is a known deferral (D-08), not a gap. The installation function is implemented but awaits a host environment with the codex binary for end-to-end testing.

---

_Verified: 2026-03-28T12:00:00Z_
_Verifier: Claude (gsd-verifier)_
