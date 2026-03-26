---
phase: 02-security-boundary
plan: 01
subsystem: infra
tags: [caddy, reverse-proxy, api-key-injection, security-boundary]

# Dependency graph
requires:
  - phase: 01-cli-skeleton-and-vm-lifecycle
    provides: lib/util.sh with check_all_deps(), die(), lib/ui.sh with color output
provides:
  - lib/proxy.sh with generate_caddyfile(), is_caddy_running(), ensure_caddy_running()
  - caddy dependency check in check_all_deps()
  - Caddyfile template with x-api-key for Anthropic, Authorization: Bearer for OpenAI
affects: [02-security-boundary, guest-provisioning, vm-lifecycle]

# Tech tracking
tech-stack:
  added: [caddy]
  patterns: [shared-caddy-instance, port-probe-detection, idempotent-ensure-guard]

key-files:
  created: [lib/proxy.sh]
  modified: [lib/util.sh]

key-decisions:
  - "OPENAI_PORT exported as constant (9111) but ShellCheck warning suppressed with SC2034 disable -- will be consumed by guest provisioning in Plan 02"
  - "Pre-existing SC2148 (missing shell directive) in util.sh left untouched per scope boundary -- only proxy.sh gets shellcheck shell=bash directive"

patterns-established:
  - "Port probe pattern: curl -sf with --connect-timeout 1 for service liveness detection"
  - "Idempotent guard pattern: check if running, validate prereqs, start, verify after start"
  - "Sourced file shellcheck directive: # shellcheck shell=bash for files without shebang"

requirements-completed: [SEC-01, SEC-03]

# Metrics
duration: 3min
completed: 2026-03-26
---

# Phase 02 Plan 01: Caddy Proxy Module Summary

**Caddy reverse proxy module with Caddyfile generation (x-api-key for Anthropic, Bearer for OpenAI), port-probe liveness detection, and idempotent ensure-running guard**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-26T14:07:26Z
- **Completed:** 2026-03-26T14:10:31Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Created lib/proxy.sh with three functions: generate_caddyfile, is_caddy_running, ensure_caddy_running
- Caddyfile uses correct headers -- x-api-key for Anthropic (not Authorization: Bearer), Authorization: Bearer for OpenAI
- Caddy bound to 127.0.0.1 on ports 9110/9111 (secure and reachable by SLIRP guests)
- ANTHROPIC_API_KEY validated as required; OPENAI_API_KEY left optional per D-08
- caddy added to check_all_deps() in util.sh

## Task Commits

Each task was committed atomically:

1. **Task 1: Create lib/proxy.sh with Caddy lifecycle functions** - `6064d3b` (feat)
2. **Task 2: Add caddy to dependency checks in lib/util.sh** - `1de7eb6` (feat)

## Files Created/Modified
- `lib/proxy.sh` - Caddy reverse proxy lifecycle: Caddyfile generation, running detection, ensure-running guard
- `lib/util.sh` - Added `check_dependency "caddy" "brew install caddy"` to check_all_deps()

## Decisions Made
- Used `# shellcheck shell=bash` directive in proxy.sh instead of a shebang, since sourced files should not have shebangs (follows project pattern)
- Suppressed SC2034 for OPENAI_PORT using the same `# shellcheck disable=SC2034` pattern established in ui.sh
- Did not fix pre-existing SC2148 in util.sh per scope boundary -- only added the caddy dependency line as specified

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- SC2148 (missing shell directive) is pre-existing in all lib/*.sh files from Phase 1. Only proxy.sh gets the `# shellcheck shell=bash` directive since the plan requires ShellCheck to pass for new code. Existing files are out of scope per deviation scope boundary rules.

## User Setup Required

None - no external service configuration required. Users will need `caddy` installed (`brew install caddy`), but the dependency check in check_all_deps() will catch this at runtime.

## Next Phase Readiness
- lib/proxy.sh ready to be sourced by the rl entry point and called during `rl new` flow
- Plan 02 will integrate ensure_caddy_running() into VM provisioning and configure guest environment

## Self-Check: PASSED

All files exist, all commits verified.

---
*Phase: 02-security-boundary*
*Completed: 2026-03-26*
