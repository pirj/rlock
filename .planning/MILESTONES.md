# Milestones

## v1.0 MVP (Shipped: 2026-03-30)

**Phases completed:** 4 phases, 6 plans, 12 tasks

**Key accomplishments:**

- Bash CLI entry point `rl` with case-statement dispatch, braille spinner, color auto-detection, and working status/rm subcommands wrapping pirj/aq
- Full rl new (aq new/start, SSH wait, guest provisioning with tmux+git) and rl code (SSH+tmux attach-or-create with auto-start), with orphaned VM recovery for partial failures
- Caddy reverse proxy module with Caddyfile generation (x-api-key for Anthropic, Bearer for OpenAI), port-probe liveness detection, and idempotent ensure-running guard
- Status:
- --agent flag on rl new installs Claude Code and/or Codex inside guest VMs with bypassPermissions mode and proxy routing
- Git code bridge via 'rl' remote with updateInstead guest repo and SSH-transparent fetch/push

---
