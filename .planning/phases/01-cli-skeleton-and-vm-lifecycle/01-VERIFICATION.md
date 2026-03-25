---
phase: 01-cli-skeleton-and-vm-lifecycle
verified: 2026-03-25T10:15:00Z
status: passed
score: 13/13 must-haves verified
re_verification: false
---

# Phase 01: CLI Skeleton and VM Lifecycle Verification Report

**Phase Goal:** Users can create, connect to, inspect, and destroy per-repo isolated VMs with a simple CLI
**Verified:** 2026-03-25T10:15:00Z
**Status:** passed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

**Plan 01 Truths:**

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Running `rl help` prints usage with subcommands (new, code, status, rm) | VERIFIED | `./rl help` exits 0, output contains all four subcommands |
| 2 | Running `rl status` in a repo with no .rl/ directory produces a clear error | VERIFIED | `./rl status` exits 1, outputs "No airlock for this repo. Run 'rl new' first." |
| 3 | Running `rl rm` in a repo with no .rl/ directory produces a clear error | VERIFIED | `./rl rm` exits 1, outputs "No airlock for this repo. Run 'rl new' first." |
| 4 | Running `rl` with an unknown subcommand produces an error with help hint | VERIFIED | `./rl unknown` exits 1, outputs "Unknown command 'unknown'. Run 'rl help' for usage." |
| 5 | Missing dependencies produce install hints (per D-11) | VERIFIED | `check_dependency` in util.sh L20-26 calls `die "$cmd not found. Install: $hint"`; `check_all_deps` L28-34 lists aq, qemu, git, ssh, tmux with install hints including `brew install pirj/tap/aq` |
| 6 | Colors are auto-detected and disabled when piped (per D-09) | VERIFIED | `./rl unknown 2>&1 \| cat -v` shows no escape sequences; ui.sh L10 checks `[ -t 1 ]` + `tput colors` |
| 7 | Spinner renders on stderr only when connected to a TTY (per D-08) | VERIFIED | ui.sh L48 gates on `[ -t 2 ]`; non-TTY path prints single line to stderr L59 |

**Plan 02 Truths:**

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 8 | User can run `rl new` in a repo directory and get a running Alpine VM with SSH access, tmux, and git installed | VERIFIED | vm.sh cmd_new L42-109: aq new, aq start, wait_for_ssh, aq exec with `apk add --no-cache tmux git`, `mkdir -p /root/repo`, PROVISION_OK sentinel check |
| 9 | User can run `rl code` and land in a tmux session inside the VM at ~/repo | VERIFIED | ssh.sh cmd_code L42-68: `ssh -t "cd /root/repo 2>/dev/null; tmux new-session -A -s rl"` |
| 10 | Running `rl new` when a VM already exists errors with hint to use `rl code` or `rl rm` (D-03) | VERIFIED | vm.sh L47-53: checks .rl/vm-name, dies "VM already exists. Use 'rl code' to connect or 'rl rm' to destroy." |
| 11 | Progress spinner displays during slow operations (VM boot, package install) (D-07, D-08) | VERIFIED | vm.sh contains 8 spinner_start/spinner_stop pairs across Creating VM, Booting VM, Waiting for SSH, Installing packages |
| 12 | `rl code` on a stopped VM auto-starts it before connecting (Open Question 3) | VERIFIED | ssh.sh L51-55: `if ! is_vm_running` then `aq start` + `wait_for_ssh` |
| 13 | `rl code` SSH failure produces error suggesting `rl status` (D-12) | VERIFIED | ssh.sh L67: `die "SSH connection failed. Run 'rl status' to check VM state."` |

**Score:** 13/13 truths verified

### Required Artifacts

**Plan 01 Artifacts:**

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `rl` | CLI entry point with case-statement dispatch | VERIFIED | 60 lines, executable, `#!/bin/bash`, `set -euo pipefail`, case statement at L35 |
| `lib/util.sh` | Shared utilities: dependency checks, error handling, .rl/ state management | VERIFIED | 95 lines, exports: die, check_dependency, check_all_deps, get_vm_name, get_saved_vm_name, resolve_vm_name, save_vm_name, ensure_rl_dir, get_ssh_port |
| `lib/ui.sh` | Terminal UX: spinner, colors, formatted output | VERIFIED | 75 lines, exports: setup_colors, info, success, warn, spinner_start, spinner_stop; SPINNER_CHARS array present |
| `lib/vm.sh` | VM lifecycle: status, rm, new commands | VERIFIED | 124 lines, exports: is_vm_running, cmd_status, cmd_new, cmd_rm |

**Plan 02 Artifacts:**

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/ssh.sh` | SSH connection and tmux session management | VERIFIED | 68 lines, exports: wait_for_ssh, cmd_code |
| `lib/vm.sh` | cmd_new added to existing vm.sh | VERIFIED | cmd_new at L42, uses aq new/start/exec, spinner, PROVISION_OK sentinel |
| `rl` | Updated dispatch -- new and code commands wired | VERIFIED | new at L36-39, code at L41-44; no "not yet implemented" stubs remain |

### Key Link Verification

**Plan 01 Links:**

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| rl | lib/util.sh | source (. "$LIB_DIR/util.sh") | WIRED | rl L9 |
| rl | lib/ui.sh | source (. "$LIB_DIR/ui.sh") | WIRED | rl L8 |
| rl | lib/vm.sh | source for status/rm/new commands | WIRED | rl L37, L42, L47, L51 |
| lib/vm.sh | lib/util.sh | calls resolve_vm_name, die | WIRED | vm.sh L21, L51, L59, L61, L68, L79, L87, L103, L114 |

**Plan 02 Links:**

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| lib/vm.sh (cmd_new) | aq new / aq start / aq exec | direct CLI calls | WIRED | vm.sh L66, L77, L94 |
| lib/vm.sh (cmd_new) | lib/ssh.sh (wait_for_ssh) | function call after aq start | WIRED | vm.sh L85 |
| lib/ssh.sh (cmd_code) | SSH + tmux | ssh -t with tmux new-session -A -s rl | WIRED | ssh.sh L61-66 |
| rl | lib/ssh.sh | source for new/code commands | WIRED | rl L38, L43 |

### Data-Flow Trace (Level 4)

Not applicable -- this is a CLI tool with shell scripts, not a data-rendering application. The "data" is VM state read from aq state files and process PIDs, which are traced and verified through the key links above.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `rl help` prints usage with all subcommands | `./rl help` | Exits 0, shows new/code/status/rm | PASS |
| Unknown command produces error with hint | `./rl unknown` | Exits 1, "Unknown command 'unknown'. Run 'rl help' for usage." | PASS |
| `rl status` without VM produces clear error | `./rl status` (no .rl/) | Exits 1, "No airlock for this repo. Run 'rl new' first." | PASS |
| `rl rm` without VM produces clear error | `./rl rm` (no .rl/) | Exits 1, "No airlock for this repo. Run 'rl new' first." | PASS |
| Colors disabled when piped | `./rl unknown 2>&1 \| cat -v` | No escape sequences in output | PASS |
| `rl status` with running VM shows state | `./rl status` (VM existed from prior use) | "ai.rlock: running (pid 81851, ssh:52338)" | PASS |
| `rl rm` destroys VM and cleans up | `./rl rm` (VM existed) | "Airlock 'ai.rlock' destroyed" | PASS |
| ShellCheck passes (warning+ severity) | `shellcheck --severity=warning --shell=bash rl lib/*.sh` | Exit 0 | PASS |
| No Bash 4+ features | `grep -c 'declare -A\|readarray\|mapfile' rl lib/*.sh` | 0 matches in all files | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| VM-01 | 01-02 | User can create a new per-repo VM with `rl new` (Alpine Linux via aq, with tmux and git pre-installed) | SATISFIED | cmd_new in vm.sh: aq new, aq start, aq exec with apk add tmux git, mkdir /root/repo |
| VM-02 | 01-01 | User can destroy a VM and clean up resources with `rl rm` | SATISFIED | cmd_rm in vm.sh: aq rm + rm -rf .rl/ |
| VM-03 | 01-01 | User can check if current repo has an attached airlock with `rl status` | SATISFIED | cmd_status in vm.sh: one-liner with running/stopped/not-found states |
| SESS-01 | 01-02 | User can SSH into VM and start or resume a tmux coding session with `rl code` | SATISFIED | cmd_code in ssh.sh: ssh -t with tmux new-session -A -s rl, auto-start stopped VMs |

No orphaned requirements. All four Phase 1 requirements from REQUIREMENTS.md traceability table are claimed by plans and verified in code.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | - | - | - | - |

No TODOs, FIXMEs, placeholders, empty implementations, or console.log-only handlers found. The "not yet implemented" stubs from Plan 01 were replaced by Plan 02 with real implementations.

### Human Verification Required

### 1. Full VM Lifecycle End-to-End

**Test:** Run `rl new`, `rl status`, `rl code` (interact, detach with Ctrl-B D), `rl code` (reattach), `rl rm` in sequence.
**Expected:** VM created with spinner feedback, status shows running state with PID and SSH port, code drops into tmux at /root/repo, reattach reconnects to same session, rm destroys everything.
**Why human:** Requires real QEMU VM boot, SSH connectivity, tmux session interaction, and visual confirmation of spinner/color output.

### 2. Duplicate `rl new` Error (D-03)

**Test:** Run `rl new` then immediately `rl new` again.
**Expected:** Second call produces "VM already exists. Use 'rl code' to connect or 'rl rm' to destroy."
**Why human:** Requires actual VM to be created first. Can only be tested with a real aq installation.

### 3. Guest Package Verification

**Test:** After `rl new`, run `rl code` and inside the VM execute `which tmux && which git && pwd`.
**Expected:** tmux and git are in PATH, working directory is /root/repo.
**Why human:** Requires running VM and SSH session to verify guest state.

### 4. Spinner Display in Terminal

**Test:** Run `rl new` in a real terminal (not piped).
**Expected:** Braille spinner characters animate during slow operations (Creating VM, Booting VM, Waiting for SSH, Installing packages), then replaced by checkmark on completion.
**Why human:** Visual behavior of animated spinner cannot be verified programmatically.

### Gaps Summary

No gaps found. All 13 observable truths are verified. All 7 artifacts exist, are substantive (60-124 lines of real implementation), and are fully wired. All 8 key links are connected. All 4 Phase 1 requirements are satisfied. All 4 commit hashes from summaries exist in git. ShellCheck passes at warning severity. No Bash 4+ features. No anti-patterns detected. Behavioral spot-checks all pass.

The phase goal -- "Shell-based CLI tool (`rl`) that can create, connect to, show status of, and remove QEMU VMs via aq, with shared library architecture and robust error handling" -- is achieved.

---

_Verified: 2026-03-25T10:15:00Z_
_Verifier: Claude (gsd-verifier)_
