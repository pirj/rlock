---
phase: 04-code-bridge
plan: 01
subsystem: infra
tags: [git, ssh, qemu, code-bridge, remote]

# Dependency graph
requires:
  - phase: 01-cli-skeleton-and-vm-lifecycle
    provides: SSH connectivity, get_ssh_port(), vm lifecycle commands
  - phase: 03-agent-provisioning
    provides: ai user, ~/repo directory, provisioning HEREDOC
provides:
  - Guest git repo at /home/ai/repo with receive.denyCurrentBranch=updateInstead
  - Host 'rl' git remote pointing to guest via SSH
  - core.sshCommand configured for transparent git fetch/push
  - Git remote and SSH config cleanup on rl rm
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns: [git-remote-over-ssh, updateInstead-working-tree, idempotent-remote-cleanup]

key-files:
  created: []
  modified: [lib/vm.sh]

key-decisions:
  - "Used receive.denyCurrentBranch=updateInstead for guest repo so pushes update both branch and working tree"
  - "Set core.sshCommand at local git config level for transparent SSH options on all remotes"
  - "Stale remote removed before adding new one for idempotent rl new re-runs"

patterns-established:
  - "Git remote cleanup: remove remote + unset core.sshCommand with || true for idempotent cleanup"
  - "Conditional push: detect no-commits, detached HEAD, and normal branch before pushing"

requirements-completed: [CODE-01]

# Metrics
duration: 2min
completed: 2026-03-29
---

# Phase 4 Plan 1: Code Bridge Summary

**Git code bridge via 'rl' remote with updateInstead guest repo and SSH-transparent fetch/push**

## Performance

- **Duration:** 2 min
- **Started:** 2026-03-29T16:54:17Z
- **Completed:** 2026-03-29T16:56:28Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- Guest repo initialized with `git init` + `receive.denyCurrentBranch=updateInstead` during provisioning
- Host-side `rl` remote added with SSH-based URL, `core.sshCommand` configured for transparent operations
- Conditional push logic handles no-commits, detached HEAD, and normal branch edge cases
- `cmd_rm()` cleans up git remote and SSH config before VM destruction, fully idempotent

## Task Commits

Each task was committed atomically:

1. **Task 1: Add git repo init to guest provisioning and host remote setup to cmd_new** - `5885898` (feat)
2. **Task 2: Add git remote cleanup to cmd_rm** - `73a698e` (feat)

## Files Created/Modified
- `lib/vm.sh` - Added git bridge to cmd_new (guest init + host remote + push) and cleanup to cmd_rm (remote remove + unset sshCommand)

## Decisions Made
- Used `receive.denyCurrentBranch=updateInstead` (not bare repo) so host pushes update both branch ref and working tree in the guest -- the agent sees files immediately after push
- Set `core.sshCommand` at repo-local level rather than using `GIT_SSH_COMMAND` env var -- makes `git fetch rl` work without any prefix, tradeoff of affecting all remotes is acceptable for this use case
- Remove stale remote before adding for idempotent re-runs of `rl new` after partial failures
- Used `git symbolic-ref --short HEAD` instead of `git branch --show-current` for Git 2.20+ compatibility

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- CODE-01 complete: host has guest as git remote, code moves via git exclusively
- All v1 requirements addressed across phases 1-4
- Ready for final milestone verification

---
*Phase: 04-code-bridge*
*Completed: 2026-03-29*
