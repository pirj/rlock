---
phase: 01-cli-skeleton-and-vm-lifecycle
plan: 01
subsystem: cli
tags: [bash, shellcheck, cli-dispatch, spinner, tput]

# Dependency graph
requires: []
provides:
  - "rl CLI entry point with case-statement dispatch"
  - "lib/util.sh shared utilities (die, dependency checks, .rl/ state management)"
  - "lib/ui.sh terminal UX (colors, spinner, output helpers)"
  - "lib/vm.sh VM lifecycle commands (status, rm)"
affects: [01-02-PLAN]

# Tech tracking
tech-stack:
  added: [bash, shellcheck, tput]
  patterns: [case-statement-dispatch, lib-sourcing, color-auto-detection, braille-spinner, rl-state-dir]

key-files:
  created: [rl, lib/util.sh, lib/ui.sh, lib/vm.sh]
  modified: []

key-decisions:
  - "Source ui.sh before util.sh so colors are available when die() is called"
  - "Use ShellCheck --severity=warning for CI (SC1091 info on dynamic source is expected)"
  - "Intentional stubs for new/code commands -- Plan 02 implements them"

patterns-established:
  - "Case-statement dispatch: rl entry point parses $1, sources needed lib/ modules, calls handler"
  - "Lib sourcing: ui.sh and util.sh always loaded, vm.sh loaded per-command"
  - "Color auto-detection: tput colors + TTY check, empty strings when piped"
  - "Braille spinner: background subshell with TTY gating on stderr"
  - ".rl/ state: minimal state dir with vm-name file, auto-added to .gitignore"
  - "Dependency checking: check_dependency with install hints per D-11"

requirements-completed: [VM-02, VM-03]

# Metrics
duration: 3min
completed: 2026-03-24
---

# Phase 01 Plan 01: CLI Skeleton Summary

**Bash CLI entry point `rl` with case-statement dispatch, braille spinner, color auto-detection, and working status/rm subcommands wrapping pirj/aq**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-24T21:42:45Z
- **Completed:** 2026-03-24T21:46:01Z
- **Tasks:** 2
- **Files created:** 4

## Accomplishments
- Created `rl` CLI entry point with case-statement dispatch for all subcommands (new, code, status, rm, help)
- Built shared library modules: util.sh (error handling, dependency checks, .rl/ state management) and ui.sh (color auto-detection, braille spinner, output helpers)
- Implemented `rl status` with compact one-liner output (D-10) and `rl rm` with aq delegation and .rl/ cleanup
- All 4 files pass ShellCheck with zero warnings, Bash 3.2 compatible

## Task Commits

Each task was committed atomically:

1. **Task 1: Create shared library modules (util.sh and ui.sh)** - `5274eec` (feat)
2. **Task 2: Create rl entry point with dispatch, help, status, and rm** - `49e30b7` (feat)

## Files Created/Modified
- `rl` - Main CLI entry point with shebang, pipefail, case-statement dispatch
- `lib/util.sh` - Shared utilities: die(), check_dependency(), check_all_deps(), .rl/ state management, get_ssh_port()
- `lib/ui.sh` - Terminal UX: setup_colors() with tput auto-detection, braille spinner with TTY gating, info/success/warn helpers
- `lib/vm.sh` - VM lifecycle: is_vm_running(), cmd_status() one-liner output, cmd_rm() with aq delegation

## Decisions Made
- Sourcing order is ui.sh then util.sh (util.sh's die() uses color variables from ui.sh)
- ShellCheck SC1091 (info level) is expected for dynamically sourced files -- use --severity=warning for CI checks
- new/code commands are intentional stubs ("not yet implemented") -- Plan 02 builds them

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed sourcing order: ui.sh before util.sh**
- **Found during:** Task 2 (creating rl entry point)
- **Issue:** Plan specified sourcing util.sh then ui.sh, but util.sh's die() function uses $RED/$RESET variables defined in ui.sh. While this works at runtime (die is called after both are sourced), sourcing ui.sh first is the correct dependency order.
- **Fix:** Reversed source order in rl: ui.sh first, then util.sh
- **Files modified:** rl
- **Verification:** `./rl help` works, `./rl unknown` shows colored error
- **Committed in:** 49e30b7 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Minor ordering fix for correctness. No scope creep.

## Known Stubs

| File | Line | Stub | Reason |
|------|------|------|--------|
| rl | 39 | `die "Command 'new' not yet implemented."` | Plan 02 implements `rl new` |
| rl | 42 | `die "Command 'code' not yet implemented."` | Plan 02 implements `rl code` |

These stubs are intentional per the plan -- Plan 02 builds the new and code subcommands.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- CLI skeleton complete with all patterns established (dispatch, lib sourcing, colors, spinner, error handling)
- Plan 02 can build `rl new` and `rl code` on top of these modules
- lib/vm.sh ready for cmd_new() addition
- lib/ssh.sh placeholder noted in rl for Plan 02 to create

## Self-Check: PASSED

All 4 created files exist. Both commit hashes verified in git log.

---
*Phase: 01-cli-skeleton-and-vm-lifecycle*
*Completed: 2026-03-24*
