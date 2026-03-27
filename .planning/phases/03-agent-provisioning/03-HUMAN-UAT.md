---
status: partial
phase: 03-agent-provisioning
source: [03-VERIFICATION.md]
started: 2026-03-28T00:00:00Z
updated: 2026-03-28T00:00:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Claude Code e2e installation
expected: `rl new --agent claude` installs Claude Code, `claude --version` works inside VM, API call through proxy succeeds
result: [pending]

### 2. Codex e2e installation
expected: Deferred per D-08 — no host codex binary available
result: [deferred]

### 3. No-agent provisioning
expected: `rl new` without `--agent` skips nodejs/npm installation entirely
result: [pending]

### 4. Graceful degradation
expected: Failed agent install (e.g. network timeout) leaves the VM usable — base provisioning intact
result: [pending]

## Summary

total: 4
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
