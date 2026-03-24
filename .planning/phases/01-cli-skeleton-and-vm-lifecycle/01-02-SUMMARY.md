---
phase: 01-cli-skeleton-and-vm-lifecycle
plan: 02
subsystem: cli
tags: [bash, ssh, tmux, aq, vm-lifecycle, shellcheck]

# Dependency graph
requires:
  - phase: 01-cli-skeleton-and-vm-lifecycle
    provides: "rl CLI entry point, util.sh, ui.sh, vm.sh skeleton"
provides:
  - "cmd_new: full VM creation with aq new/start, SSH wait, guest provisioning"
  - "cmd_code: SSH+tmux session attach/reattach with auto-start"
  - "lib/ssh.sh: SSH connectivity (wait_for_ssh) and session management"
  - "resolve_vm_name: orphaned VM recovery fallback"
affects: [02-security-boundary, 03-agent-provisioning, 04-code-bridge]

# Tech tracking
tech-stack:
  added: [ssh, tmux, aq-exec]
  patterns: [ssh-wait-two-phase, tmux-attach-or-create, orphaned-vm-recovery, early-state-save]

key-files:
  created: [lib/ssh.sh]
  modified: [lib/vm.sh, lib/util.sh, rl]

key-decisions:
  - "save_vm_name called right after aq new succeeds (before aq start) so rl rm can always clean up partial failures"
  - "resolve_vm_name falls back to directory-name VM lookup when .rl/vm-name is missing, handling orphaned VMs gracefully"
  - "Cross-repo collision check distinguishes orphaned same-repo VMs from actual cross-repo collisions"

patterns-established:
  - "Two-phase SSH wait: poll for ssh-port.conf file, then poll SSH connectivity"
  - "tmux attach-or-create: ssh -t with tmux new-session -A -s rl"
  - "Early state save: persist .rl/vm-name immediately after VM creation, before boot/provisioning"
  - "Orphaned VM recovery: resolve_vm_name tries saved name, then derives from directory basename"
  - "Provisioning sentinel: echo PROVISION_OK at end of aq exec script, grep output to verify"

requirements-completed: [VM-01, SESS-01]

# Metrics
duration: 39min
completed: 2026-03-24
---

# Phase 01 Plan 02: VM Creation and Session Connect Summary

**Full rl new (aq new/start, SSH wait, guest provisioning with tmux+git) and rl code (SSH+tmux attach-or-create with auto-start), with orphaned VM recovery for partial failures**

## Performance

- **Duration:** 39 min (includes human verification and bug fix cycle)
- **Started:** 2026-03-24T22:59:31Z
- **Completed:** 2026-03-24T23:38:55Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Implemented `rl new` with full VM lifecycle: aq new, aq start, two-phase SSH wait, guest provisioning (apk add tmux git, mkdir /root/repo), PROVISION_OK sentinel verification
- Implemented `rl code` with SSH+tmux attach-or-create, auto-starting stopped VMs, and clear error messages per D-12
- Created `lib/ssh.sh` with `wait_for_ssh()` (two-phase: port file poll then SSH connectivity poll) and `cmd_code()`
- Fixed critical bug: moved `save_vm_name` to right after `aq new` so `rl rm` can always clean up, even after boot/SSH/provisioning failures
- Added `resolve_vm_name()` helper for orphaned VM recovery -- cmd_status, cmd_code, cmd_rm all handle missing .rl/vm-name gracefully
- Improved cross-repo collision detection to distinguish orphaned VMs from actual collisions

## Task Commits

Each task was committed atomically:

1. **Task 1: Create lib/ssh.sh and implement cmd_new in lib/vm.sh** - `afa0545` (feat)
2. **Task 2: Fix orphaned VM bugs found during verification** - `b859890` (fix)

## Files Created/Modified
- `lib/ssh.sh` - SSH connectivity (wait_for_ssh with two-phase polling) and session management (cmd_code with tmux attach-or-create)
- `lib/vm.sh` - Added cmd_new() with aq new/start/exec, early save_vm_name, spinner feedback; updated cmd_status and cmd_rm to use resolve_vm_name
- `lib/util.sh` - Added resolve_vm_name() helper that falls back to directory-name VM lookup for orphaned VM recovery
- `rl` - Updated dispatch: new and code commands wired to real implementations via vm.sh and ssh.sh

## Decisions Made
- save_vm_name is called immediately after aq new succeeds (before aq start/SSH/provisioning) to ensure rl rm can always clean up partial failures
- resolve_vm_name provides graceful fallback for all read commands (status, code, rm) when .rl/vm-name is missing but a matching VM exists in aq state
- Cross-repo collision check now distinguishes between orphaned VMs (no .rl/vm-name, suggests rl rm) and actual cross-repo collisions (has .rl/vm-name with different name, suggests rename)
- Error messages on partial failures now suggest `rl rm` for cleanup

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] save_vm_name called too late in cmd_new**
- **Found during:** Task 2 (human verification of rl workflow)
- **Issue:** save_vm_name was called after provisioning (step 7 in plan). If aq start, SSH wait, or aq exec failed, .rl/vm-name was never written. This left an orphaned VM that rl rm, rl status, and rl code could not find, and a subsequent rl new would fail with a misleading cross-repo collision error.
- **Fix:** Moved save_vm_name to right after aq new succeeds (before aq start). Now rl rm can always clean up, regardless of which later step failed.
- **Files modified:** lib/vm.sh
- **Verification:** ShellCheck passes; save_vm_name now at line 73 (after aq new at line 66, before aq start at line 77)
- **Committed in:** b859890

**2. [Rule 1 - Bug] Cross-repo collision check fired on same-repo orphaned VM**
- **Found during:** Task 2 (human verification)
- **Issue:** When .rl/vm-name did not exist (due to bug #1) but a VM with the directory name existed in aq state, the check assumed it was from another repo. The error "from another repo" was misleading when the VM was actually from a failed rl new in the current repo.
- **Fix:** Split the collision check: if .rl/vm-name is absent and VM exists, suggest rl rm (likely orphaned). If .rl/vm-name exists with a different name, suggest rename (actual collision).
- **Files modified:** lib/vm.sh
- **Verification:** ShellCheck passes; two distinct error paths for orphaned vs cross-repo cases
- **Committed in:** b859890

**3. [Rule 2 - Missing Critical] cmd_status, cmd_code, cmd_rm could not handle orphaned VMs**
- **Found during:** Task 2 (human verification)
- **Issue:** All three commands used get_saved_vm_name which requires .rl/vm-name to exist. Orphaned VMs (from failed rl new) were invisible to the entire CLI.
- **Fix:** Added resolve_vm_name() to util.sh that tries get_saved_vm_name first, then falls back to checking if a VM matching the directory name exists in aq state. Updated cmd_status, cmd_code, and cmd_rm to use resolve_vm_name.
- **Files modified:** lib/util.sh, lib/vm.sh, lib/ssh.sh
- **Verification:** ShellCheck passes; resolve_vm_name defined in util.sh, used in all three commands
- **Committed in:** b859890

---

**Total deviations:** 3 auto-fixed (2 bugs, 1 missing critical)
**Impact on plan:** All fixes address real-world failure modes discovered during end-to-end testing. The early save_vm_name and resolve_vm_name patterns are essential for robust CLI behavior. No scope creep.

## Issues Encountered
- Guest provisioning via `aq exec` failed during first test run (the specific failure was between aq new and save_vm_name, preventing cleanup). Root cause was the ordering of save_vm_name -- fixed by moving it earlier. The user had to manually run `aq rm` to clean up the orphaned VM before retesting.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All four rl subcommands are fully functional: new, code, status, rm
- Phase 1 complete -- CLI skeleton and VM lifecycle management working end-to-end
- Phase 2 (Security Boundary) can build Caddy proxy integration on top of rl new
- Phase 3 (Agent Provisioning) can extend the aq exec provisioning script to install Claude Code and Codex
- Phase 4 (Code Bridge) can add git remote setup to cmd_new

## Self-Check: PASSED

All 4 key files exist (lib/ssh.sh, lib/vm.sh, lib/util.sh, rl). Both commit hashes verified in git log (afa0545, b859890).

---
*Phase: 01-cli-skeleton-and-vm-lifecycle*
*Completed: 2026-03-24*
