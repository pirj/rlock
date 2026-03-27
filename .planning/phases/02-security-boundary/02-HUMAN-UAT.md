---
status: partial
phase: 02-security-boundary
source: [02-VERIFICATION.md]
started: 2026-03-27T00:00:00Z
updated: 2026-03-27T00:00:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. End-to-end proxy request from guest
expected: curl from inside VM to 10.0.2.2:9110 reaches Anthropic API with injected auth (JSON response, not connection error)
result: [pending]

### 2. Mise env vars active in guest
expected: `mise env` inside VM shows ANTHROPIC_BASE_URL=http://10.0.2.2:9110, OPENAI_BASE_URL=http://10.0.2.2:9111, ANTHROPIC_API_KEY=dummy, OPENAI_API_KEY=dummy
result: [pending]

### 3. No real keys in guest
expected: `env | grep -i 'api.key\|secret\|token' | grep -v dummy` returns empty output inside VM
result: [pending]

### 4. Caddy survives rl rm
expected: After `rl rm`, `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9110` still returns a non-000 HTTP code
result: [pending]

## Summary

total: 4
passed: 0
issues: 0
pending: 4
skipped: 0
blocked: 0

## Gaps
