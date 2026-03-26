---
phase: 02-security-boundary
plan: 02
subsystem: infra
tags: [caddy-integration, mise, oauth, credential-store, guest-provisioning]

# Dependency graph
requires:
  - phase: 02-security-boundary/plan-01
    provides: lib/proxy.sh with ensure_caddy_running(), generate_caddyfile()
provides:
  - Caddy proxy integrated into rl new flow
  - lib/creds.sh with credential store and OAuth import from Claude Code keychain
  - rl auth command (anthropic, openai, status)
  - Guest provisioning with mise, bash, proxy URLs, dummy API keys
  - Token refresh daemon for OAuth lifecycle
affects: [vm-lifecycle, security-boundary, guest-environment]

# Tech tracking
tech-stack:
  added: [mise-en-place, macOS-keychain-integration]
  patterns: [credential-store-with-env-fallback, oauth-token-import, background-refresh-daemon]
---

## Plan 02-02: Proxy Integration & Guest Provisioning

**Status:** Complete
**Tasks:** 2/2
**Commits:** 10

## What Was Built

### Credential Store (`lib/creds.sh`)
- Credential storage in `~/.config/rl/credentials` (chmod 600)
- `creds_resolve()`: store first, env var fallback
- OAuth token import from macOS Keychain (`Claude Code-credentials`)
- Token refresh daemon: background process re-imports from keychain every 5 min
- `rl auth anthropic`: imports OAuth tokens or falls back to API key entry
- `rl auth openai`: API key entry for Codex users
- `rl auth status`: shows auth type, key preview, daemon status

### Caddy Integration (`lib/vm.sh`, `lib/proxy.sh`)
- `ensure_caddy_running` called in `cmd_new` before VM creation
- Caddyfile writes actual key values (not `{env.*}` references) — keys exported after Caddy starts are picked up via `caddy reload`
- Caddy running detection: HTTP status code check (not `curl -sf` which fails on upstream 404)
- No API key required at startup — proxy starts unconditionally

### Guest Provisioning (`lib/vm.sh`)
- bash set as default shell (ash can't run mise output)
- mise-en-place installed from Alpine community repo
- `mise.toml` generated with fixed proxy URLs and dummy API keys
- `ANTHROPIC_BASE_URL=http://10.0.2.2:9110`, `OPENAI_BASE_URL=http://10.0.2.2:9111`

### CLI Updates (`bin/rl`)
- `rl` moved to `bin/rl`, `LIB_DIR` resolves via `PROJECT_DIR`
- `rl auth` command wired into dispatch
- Help text updated with `auth` command

## Bugs Found During Verification

1. **spinner_stop exit code** — `wait` on killed spinner process returns 143 (SIGTERM). With `set -e`, silently killed the script after every `spinner_stop`. Fix: `|| true` on wait.
2. **Caddy running detection** — `curl -sf` fails on HTTP 404 from upstream API. Caddy IS running but detection says it isn't. Fix: check HTTP status code != "000".
3. **aq start stdout redirect** — `>/dev/null 2>&1` hangs QEMU (needs stdout for detach). Fix: stderr-only redirect.
4. **mise activate sh** — mise doesn't accept `sh` as shell type. Fix: use `bash`.
5. **ash vs bash** — Alpine's default ash shell can't run `mise activate bash` output (`export -a` illegal). Fix: set `/bin/bash` as root's login shell.
6. **API key requirement** — Original code required `ANTHROPIC_API_KEY` at VM creation, blocking Codex-only users and OAuth users. Fix: warn but don't require.

## Key Files

### Created
- `lib/creds.sh` — Credential store, OAuth import, refresh daemon, `rl auth`

### Modified
- `lib/proxy.sh` — Caddyfile generation with actual values, improved running detection
- `lib/vm.sh` — Caddy integration, mise provisioning, bash default shell
- `lib/ui.sh` — spinner_stop wait fix, shellcheck directive
- `lib/ssh.sh` — Better error message for missing SSH port
- `lib/util.sh` — shellcheck directive
- `bin/rl` — Moved from root, added auth dispatch

## Self-Check: PASSED
- [x] Caddy starts automatically during `rl new`
- [x] Guest has mise with proxy URLs and dummy API keys
- [x] No real API key in the VM
- [x] OAuth tokens imported from Claude Code keychain
- [x] Refresh daemon running for token lifecycle
- [x] ShellCheck passes on all files
