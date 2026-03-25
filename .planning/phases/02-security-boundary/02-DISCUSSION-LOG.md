# Phase 2: Security Boundary - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-26
**Phase:** 02-security-boundary
**Areas discussed:** Proxy architecture, API key handling, Caddy lifecycle, Guest env var setup

---

## Proxy Architecture

| Option | Description | Selected |
|--------|-------------|----------|
| One Caddy, two ports | Same instance, different ports per API, different headers | ✓ |
| Separate Caddy instances | One per API | |
| Single port, path-based routing | `/anthropic/*` and `/openai/*` | |

**User's choice:** Same Caddy instance, different ports. Each injects different keys from different env vars into different headers.
**Notes:** Anthropic uses `x-api-key` header, OpenAI uses `Authorization: Bearer`. Fixed ports on guest side, shared across all airlocks.

---

## API Key Handling

| Option | Description | Selected |
|--------|-------------|----------|
| API key only (v1) | Require console.anthropic.com API key | |
| Dummy key + proxy overwrite | Set dummy key in guest, proxy overwrites | ✓ |
| OAuth sidecar on host | Shared process manages OAuth tokens for Pro/Max | ✓ |

**User's choice:** Both dummy key AND OAuth sidecar. Dummy key in guest so CC starts. Proxy/sidecar overwrites with real credential. OAuth sidecar handles Pro/Max token refresh, shared across airlocks. Both in scope for Phase 2.
**Notes:** User raised that Pro/Max subscriptions use OAuth, not API keys. Console API keys are separate pay-as-you-go. Sidecar approach handles both auth methods transparently.

---

## Caddy Lifecycle

| Option | Description | Selected |
|--------|-------------|----------|
| Start on `rl new`, stop on `rl rm` | Per-VM lifecycle | |
| Start if not running, never stop | Shared persistent instance | ✓ |
| System service (launchd/systemd) | OS-managed lifecycle | |

**User's choice:** Start if not running on `rl new`. Never stop on `rl rm`. Just ensure it's running.
**Notes:** Originally discussed PID file in `.rl/`, but since Caddy is shared across airlocks, per-repo PID management isn't needed. Just detect and start.

---

## Guest Env Var Setup

| Option | Description | Selected |
|--------|-------------|----------|
| Shell profile (.bashrc/.profile) | Set env vars in login shell | |
| mise.toml + mise-en-place | Install mise, generate mise.toml with fixed URLs | ✓ |
| Direct env vars in provisioning | Export in provisioning script | |

**User's choice:** Install mise-en-place during provisioning. Generate mise.toml with fixed proxy URLs and dummy API keys. Fixed guest ports across all VMs.
**Notes:** mise handles env var loading automatically when entering directory. Clean separation of config.

---

## Claude's Discretion

- Exact fixed port numbers
- Caddy "is running" detection method
- Caddyfile location on host
- OAuth sidecar implementation details
- mise.toml placement in guest

## Deferred Ideas

None — discussion stayed within phase scope
