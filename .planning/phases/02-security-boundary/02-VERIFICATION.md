---
phase: 02-security-boundary
verified: 2026-03-27T08:24:18Z
status: human_needed
score: 4/4
re_verification: false
human_verification:
  - test: "End-to-end proxy request from guest VM to Anthropic API"
    expected: "curl from guest to http://10.0.2.2:9110/v1/messages returns a JSON response from Anthropic (not a connection error)"
    why_human: "Requires a running VM with network connectivity and a valid ANTHROPIC_API_KEY on the host"
  - test: "Verify mise env vars are active in guest shell session"
    expected: "Running 'mise env | grep ANTHROPIC' inside guest shows ANTHROPIC_BASE_URL=http://10.0.2.2:9110 and ANTHROPIC_API_KEY=dummy"
    why_human: "Requires connecting to a running VM via rl code and checking live shell environment"
  - test: "Verify no real API keys exist inside the guest"
    expected: "env | grep -i 'api.key' inside guest shows only dummy values"
    why_human: "Requires connecting to a running VM and inspecting the live environment"
  - test: "Verify Caddy survives rl rm"
    expected: "After rl rm, curl http://127.0.0.1:9110 still returns an HTTP response"
    why_human: "Requires running rl rm and checking host Caddy afterwards"
---

# Phase 2: Security Boundary Verification Report

**Phase Goal:** API keys never enter the VM; a host-side Caddy reverse proxy injects Authorization headers so AI agents can call APIs without possessing secrets
**Verified:** 2026-03-27T08:24:18Z
**Status:** human_needed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Caddy reverse proxy starts automatically during `rl new`, listening on fixed ports (9110 for Anthropic, 9111 for OpenAI) bound to 127.0.0.1 | VERIFIED | `cmd_new` in `lib/vm.sh:66-72` calls `ensure_caddy_running` before VM creation. `lib/proxy.sh:12-14` defines `ANTHROPIC_PORT=9110`, `OPENAI_PORT=9111`. Caddyfile template at `lib/proxy.sh:35,42` binds to `http://127.0.0.1:${ANTHROPIC_PORT}` and `http://127.0.0.1:${OPENAI_PORT}`. |
| 2 | HTTP requests from inside the VM to http://10.0.2.2:9110 and :9111 arrive at upstream APIs with correct auth headers injected (x-api-key for Anthropic, Authorization: Bearer for OpenAI) | VERIFIED (code-level) | `lib/proxy.sh:37` writes `header_up x-api-key` for Anthropic (correct, not Authorization: Bearer). `lib/proxy.sh:44` writes `header_up Authorization "Bearer"` for OpenAI. `lib/proxy.sh:38,45` include `header_up Host` directives. `lib/vm.sh:120-121` sets `ANTHROPIC_BASE_URL=http://10.0.2.2:9110` and `OPENAI_BASE_URL=http://10.0.2.2:9111` in guest mise.toml. End-to-end flow requires human verification. |
| 3 | No API key, token, or credential exists anywhere inside the VM -- not in env vars, config files, shell history, or process memory | VERIFIED (code-level) | `lib/vm.sh:122-123` provisions guest with `ANTHROPIC_API_KEY = "dummy"` and `OPENAI_API_KEY = "dummy"`. No real key is ever transmitted to the VM. Real keys stay in host-side credential store (`lib/creds.sh:35`, chmod 600) and Caddyfile (`lib/proxy.sh:49`, chmod 600). End-to-end requires human verification. |
| 4 | Caddy is a shared instance -- starts with first `rl new`, stays running across VM lifecycle (not stopped on `rl rm`) | VERIFIED | `cmd_rm` in `lib/vm.sh:147-159` does not reference Caddy, proxy, or any stop/shutdown command. `proxy.sh` is not sourced for the `rm)` case in `bin/rl:54-57`. `ensure_caddy_running` is idempotent -- `lib/proxy.sh:73-79` checks if already running and just reloads config. |

**Score:** 4/4 truths verified at code level

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/proxy.sh` | Caddy lifecycle management (generate, detect, ensure running) | VERIFIED | 91 lines. Contains `generate_caddyfile`, `is_caddy_running`, `ensure_caddy_running`. Exports `ANTHROPIC_PORT=9110`, `OPENAI_PORT=9111`. ShellCheck clean. |
| `lib/util.sh` | Updated dependency check including caddy | VERIFIED | Line 36: `check_dependency "caddy" "brew install caddy"` inside `check_all_deps()`. ShellCheck clean. |
| `lib/vm.sh` | cmd_new with Caddy ensure + extended provisioning (mise + env vars) | VERIFIED | 159 lines. `ensure_caddy_running` called at line 68. Provisioning heredoc installs mise, writes mise.toml with proxy URLs and dummy API keys. ShellCheck clean. |
| `bin/rl` | Entry point sources creds.sh and proxy.sh for new and auth commands | VERIFIED | 69 lines. `new)` case sources creds.sh, proxy.sh, vm.sh, ssh.sh in correct order. `auth)` case sources creds.sh and proxy.sh. `code)`, `status)`, `rm)` do NOT source proxy.sh. |
| `lib/creds.sh` | Credential store, OAuth import, refresh daemon | VERIFIED | 337 lines. Contains `creds_resolve`, `creds_set`, `creds_get`, `import_claude_oauth`, `refresh_if_needed`, `start_refresh_daemon`, `cmd_auth`. Not in original plan but extends the security boundary with credential management. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/proxy.sh` | `~/.config/rl/Caddyfile` | `generate_caddyfile` writes Caddyfile to XDG config dir | WIRED | `lib/proxy.sh:30` writes `cat > "$CADDY_FILE"`. `CADDY_FILE` resolves to `$CADDY_CONFIG_DIR/Caddyfile` at line 11. |
| `lib/proxy.sh` | `caddy start` | `ensure_caddy_running` invokes caddy start with --config | WIRED | `lib/proxy.sh:82` runs `caddy start --config "$CADDY_FILE" --adapter caddyfile`. |
| `lib/vm.sh` | `lib/proxy.sh` | `cmd_new` calls `ensure_caddy_running` before VM creation | WIRED | `lib/vm.sh:68` calls `ensure_caddy_running`. `bin/rl:40` sources `proxy.sh` before `vm.sh`. |
| `lib/vm.sh` | guest mise.toml | `aq exec` provisioning script generates /root/mise.toml | WIRED | `lib/vm.sh:118-124` writes mise.toml via `cat > /root/mise.toml` heredoc with `ANTHROPIC_BASE_URL=http://10.0.2.2:9110`. |
| `bin/rl` | `lib/proxy.sh` | source proxy.sh in new command dispatch | WIRED | `bin/rl:40` has `. "$LIB_DIR/proxy.sh"` in `new)` case block. |
| `lib/proxy.sh` | `lib/creds.sh` | `generate_caddyfile` calls `creds_resolve` | WIRED | `lib/proxy.sh:23-24` calls `creds_resolve`. `bin/rl:39` sources `creds.sh` before `proxy.sh`. |

### Data-Flow Trace (Level 4)

Not applicable -- this phase produces shell scripts (CLI tool), not components rendering dynamic data. The "data flow" is API keys from host environment/credential store into the Caddyfile, which was verified at the key-link level above.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| All shell files pass syntax check | `bash -n bin/rl lib/proxy.sh lib/creds.sh lib/vm.sh` | Exit 0 | PASS |
| All shell files pass ShellCheck | `shellcheck --severity=warning lib/proxy.sh lib/util.sh lib/vm.sh lib/ui.sh lib/ssh.sh lib/creds.sh bin/rl` | Exit 0 | PASS |
| `rl help` includes auth command | `grep 'auth' bin/rl` | `auth     Configure API keys for AI agents` | PASS |
| Proxy module exports 3 functions | `grep -c 'generate_caddyfile\|is_caddy_running\|ensure_caddy_running' lib/proxy.sh` | 8 matches (definitions + usages) | PASS |
| Caddy in dependency checks | `grep 'check_dependency "caddy"' lib/util.sh` | Match found at line 36 | PASS |
| Caddyfile uses x-api-key for Anthropic (not Authorization: Bearer) | `grep 'x-api-key' lib/proxy.sh` | `header_up x-api-key` at line 37 | PASS |
| Guest provisioning has dummy API keys | `grep 'ANTHROPIC_API_KEY.*dummy' lib/vm.sh` | Match at line 122 | PASS |
| Guest provisioning has proxy URLs | `grep 'ANTHROPIC_BASE_URL.*10.0.2.2:9110' lib/vm.sh` | Match at line 120 | PASS |
| End-to-end proxy request from guest | N/A -- requires running VM | N/A | SKIP (needs human) |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| SEC-01 | 02-01, 02-02 | Caddy reverse proxy on host injects Authorization headers for Anthropic and OpenAI APIs | SATISFIED | `lib/proxy.sh` generates Caddyfile with `header_up x-api-key` for Anthropic and `header_up Authorization "Bearer"` for OpenAI. `ensure_caddy_running` starts and manages Caddy lifecycle. |
| SEC-02 | 02-02 | Guest Claude Code/Codex configured to use host proxy via ANTHROPIC_BASE_URL / OPENAI_BASE_URL env vars pointing to 10.0.2.2 | SATISFIED | `lib/vm.sh:120-121` writes `ANTHROPIC_BASE_URL = "http://10.0.2.2:9110"` and `OPENAI_BASE_URL = "http://10.0.2.2:9111"` to guest mise.toml. Note: REQUIREMENTS.md still marks this as "Pending" -- should be updated to "Complete". |
| SEC-03 | 02-01, 02-02 | API keys never enter the VM in any form (not in env vars, config files, or process memory) | SATISFIED | Guest receives `ANTHROPIC_API_KEY = "dummy"` and `OPENAI_API_KEY = "dummy"` only. Real keys stay in host-side credential store (chmod 600) and Caddyfile (chmod 600). No mechanism exists to transfer real keys to the VM. |

No orphaned requirements found -- all three SEC requirements mapped to Phase 2 are claimed by the plans.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | -- | -- | -- | No TODO, FIXME, placeholder, or stub patterns found in any Phase 2 files |

### Notable Design Deviations

1. **Caddyfile uses actual key values instead of `{env.*}` references** -- Plan 01 specified `{env.ANTHROPIC_API_KEY}` in the Caddyfile, but the implementation writes actual credential values. This is documented in the 02-02 SUMMARY as intentional: Caddy reads env vars only at startup, so keys exported after Caddy starts would be invisible. Writing actual values + `caddy reload` is more robust. Security is maintained via chmod 600 on the Caddyfile.

2. **API key no longer required at startup** -- Plan 01 specified that `ensure_caddy_running` should `die` if `ANTHROPIC_API_KEY` is not set. The implementation starts Caddy unconditionally (no key validation), which is more flexible: supports OAuth users who run `rl auth anthropic` after initial setup, and supports Codex-only users. Documented as Bug 6 fix in 02-02 SUMMARY.

3. **Added `lib/creds.sh` (not in original plan)** -- A credential store with OAuth import from macOS Keychain and a refresh daemon was added. This extends the security boundary beyond the original scope but enhances it: credentials are stored in a chmod 600 file rather than requiring env var exports.

4. **`rl` moved from root to `bin/rl`** -- Entry point relocated with `PROJECT_DIR`-relative lib resolution.

### Human Verification Required

### 1. End-to-end proxy request from guest VM

**Test:** Create a VM with `rl new`, connect with `rl code`, run `curl -s http://10.0.2.2:9110/v1/messages -H "Content-Type: application/json" -H "x-api-key: dummy" -H "anthropic-version: 2023-06-01" -d '{"model":"claude-sonnet-4-20250514","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'`
**Expected:** JSON response from Anthropic API (not a connection error or auth failure)
**Why human:** Requires a running VM with QEMU SLIRP networking, a valid ANTHROPIC_API_KEY on the host, and network connectivity to api.anthropic.com

### 2. Verify mise environment variables are active in guest

**Test:** Connect to guest via `rl code`, run `mise env | grep -E 'ANTHROPIC|OPENAI'`
**Expected:** `ANTHROPIC_BASE_URL=http://10.0.2.2:9110`, `OPENAI_BASE_URL=http://10.0.2.2:9111`, `ANTHROPIC_API_KEY=dummy`, `OPENAI_API_KEY=dummy`
**Why human:** Requires a running VM and live shell session to verify mise activation works

### 3. Verify no real API keys inside the guest

**Test:** Inside guest, run `env | grep -i 'api.key\|secret\|token' | grep -v dummy`
**Expected:** Empty output
**Why human:** Requires live VM inspection to confirm no credential leakage through unexpected channels

### 4. Verify Caddy survives rl rm

**Test:** Run `rl rm`, then `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9110`
**Expected:** Non-"000" HTTP status code (Caddy still listening)
**Why human:** Requires actually destroying a VM and checking host services afterwards

### Gaps Summary

No code-level gaps found. All four Success Criteria from the ROADMAP are satisfied at the code level:

1. Caddy proxy infrastructure is complete with proper Caddyfile generation, port-probe detection, and idempotent ensure-running guard.
2. Guest provisioning correctly configures mise with proxy URLs and dummy API keys.
3. No mechanism exists to transfer real API keys into the VM.
4. Caddy lifecycle is independent of VM lifecycle -- `cmd_rm` does not touch Caddy.

The implementation exceeds the original plan scope with a credential store (`lib/creds.sh`), OAuth token import from Claude Code's macOS Keychain, and a background token refresh daemon.

One administrative note: REQUIREMENTS.md marks SEC-02 as "Pending" but the implementation satisfies it. This should be updated.

---

_Verified: 2026-03-27T08:24:18Z_
_Verifier: Claude (gsd-verifier)_
