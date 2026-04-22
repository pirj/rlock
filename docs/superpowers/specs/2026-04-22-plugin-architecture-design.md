# Plugin Architecture for rlock

**Date:** 2026-04-22
**Status:** Draft

## Problem

rlock v1.0 is a monolithic shell tool where VM lifecycle, agent installation, credential management, git bridging, and Caddy proxying are all tightly coupled. Users must take everything or nothing. Expanding to new use cases (PR isolation, dockerfile translation) will compound this coupling. The codebase needs a plugin architecture that provides clean separation, lets users install only what they need, and opens the door for third-party plugins.

## Solution

Split rlock into a thin **base** (aq wrapper + SSH) and **convention-based plugins** that hook into VM provisioning, lifecycle events, and command dispatch. Plugins are directories under `~/.config/rl/plugins/` with a `plugin.toml` manifest and a `plugin.sh` for hooks.

## Architecture Overview

### Base (`bin/rl`)

Base is a thin dispatcher responsible for:

1. **Plugin discovery** — scan `~/.config/rl/plugins/*/plugin.toml`
2. **Activation** — from CLI args or interactive trigger-based prompts
3. **Dependency resolution** — topological sort by `deps`, auto-include with notification
4. **Host dep check** — verify `host_deps` binaries exist
5. **Hook dispatch** — call each plugin's `plugin.sh <hook>` in dependency order
6. **Command dispatch** — for subcommands not built into base, search activated plugins

### Built-in commands (base only)

| Command | Purpose |
|---|---|
| `rl new [plugins...]` | Create VM, activate plugins, run provisioning hooks |
| `rl rm` | Run `rm` hooks in reverse dependency order, destroy VM |
| `rl status` | Show VM state + list of active plugins |
| `rl ssh` | Raw SSH into VM (no tmux, no agent — just a shell) |

### What moves out of base

- `rl code` → removed (replaced by `rl claude` / `rl codex` in agent plugins)
- `rl auth` → auth-proxy plugin
- Git remote setup → git plugin
- Caddy management → auth-proxy plugin
- Agent installation → agent-claude-code / agent-codex plugins
- Credential management → auth-proxy plugin

## Plugin Structure

### Directory layout

```
~/.config/rl/plugins/
  git/
    plugin.toml
    plugin.sh
  auth-proxy/
    plugin.toml
    plugin.sh
  agent-claude-code/
    plugin.toml
    plugin.sh
    commands/
      claude.sh
  agent-codex/
    plugin.toml
    plugin.sh
    commands/
      codex.sh
  pr/
    plugin.toml
    plugin.sh
    commands/
      branch.sh
      reset.sh
      snapshot.sh
  dockerfile-translator/
    plugin.toml
    plugin.sh
```

### Manifest (`plugin.toml`)

```toml
description = "Git gateway between host and guest"
deps = []
host_deps = ["git", "ssh"]
triggers = [".git"]
commands = []
```

All fields optional except `description`. Missing fields default to empty. Parsed in bash with `grep`/`sed` — no nested tables, flat key-value only.

### Hook script (`plugin.sh`)

Receives the hook name as its first argument, VM name as second:

```bash
#!/usr/bin/env bash

provision() {
    local vm="$1"
    # runs inside guest during rl new
}

start() {
    local vm="$1"
    # runs on host when VM starts
}

rm() {
    local vm="$1"
    # cleanup on host when VM is destroyed
}

# dispatch — silently ignore unknown hooks
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

Available hooks:
- **`provision`** — runs during `rl new`, installs packages and configures the guest
- **`start`** — runs on host when VM starts (e.g., start Caddy, add git remote)
- **`rm`** — cleanup on host when VM is destroyed

If a hook function isn't defined, the dispatch fails silently (or the plugin can handle unknown hooks with a default case).

## Core Plugins

### `git`

- **Trigger:** `.git`
- **Host deps:** `git`, `ssh`
- **Provision:** install `git` in guest, create `~/repo` with `receive.denyCurrentBranch=updateInstead`
- **Start:** print command to add remote, ask for user confirmation
- **Rm:** remove git remote, unset `core.sshCommand`

### `auth-proxy`

- **Trigger:** none (pulled in as a dependency of agent plugins)
- **Host deps:** `caddy`
- **Provision:** none (Caddy runs on host)
- **Start:** generate Caddyfile, start/reload Caddy
- **Rm:** stop Caddy if no other airlocks using it
- **Commands:** `auth` (import OAuth tokens, set API keys)

### `agent-claude-code`

- **Trigger:** `.claude`
- **Deps:** `auth-proxy`
- **Provision:** install `nodejs`, `npm`, `@anthropic-ai/claude-code`, write `settings.json` with `bypassPermissions`, set up `mise.toml` with `ANTHROPIC_BASE_URL`
- **Commands:** `claude` (SSH + tmux session)

### `agent-codex`

- **Trigger:** `codex` on host PATH
- **Deps:** `auth-proxy`
- **Provision:** install `nodejs`, `npm`, `@openai/codex`, write `config.toml` with `openai_base_url`
- **Commands:** `codex` (SSH + tmux session)

### `pr`

- **Deps:** `git`
- **Provision:** none beyond what deps provide
- **Commands:** `branch`, `reset`, `snapshot`
- Manages qcow2 layering (env.qcow2 / live.qcow2)
- If `dockerfile-translator` is also activated, `snapshot` uses its translated provisioning script for the env layer. Otherwise, `snapshot` captures whatever is currently installed in the VM.

### `dockerfile-translator`

- **Trigger:** `Dockerfile`, `docker-compose.yml`
- **Provision:** translates Dockerfile into Alpine provisioning script and runs it; translates docker-compose.yml services into native Alpine packages with init scripts
- No commands

## Plugin Activation

### Via CLI args

```bash
rl new git claude-code
```

Plugin names are positional arguments to `rl new`.

### Interactive trigger detection

When plugins are not passed as args, base scans available plugins for trigger matches in the current directory and prompts:

```
Include git gateway? (Y/n)        # .git detected
Include claude-code agent? (Y/n)  # .claude detected
```

### Dependency auto-inclusion

```bash
$ rl new git claude-code
Including auth-proxy (required by claude-code)
```

Dependencies are included automatically with a notification message.

### Activation state

`rl new` writes activated plugin names to `.rl/plugins` (one per line):

```
auth-proxy
git
agent-claude-code
```

All subsequent commands (`rl rm`, `rl status`, `rl claude`, etc.) read `.rl/plugins` to know which plugins are active. If `.rl/plugins` doesn't exist, the airlock is base-only.

## Lifecycle Flows

### `rl new git claude-code`

```
1. Parse args → activated = [git, claude-code]
2. Resolve deps → claude-code needs auth-proxy
   Print: "Including auth-proxy (required by claude-code)"
   Final list: [auth-proxy, git, claude-code]  (topologically sorted)
3. Check triggers for non-listed plugins:
   - dockerfile-translator: Dockerfile found → "Include dockerfile-translator? (Y/n)"
4. Check host deps for all activated plugins
   - auth-proxy needs caddy ✓
   - git needs git, ssh ✓
5. Create VM via aq (base responsibility)
6. Run provision hooks in dependency order:
   - auth-proxy.provision (nothing — Caddy is host-side)
   - git.provision (install git, create ~/repo)
   - claude-code.provision (install node, npm, claude-code, settings.json, mise.toml)
7. Run start hooks in dependency order:
   - auth-proxy.start (generate Caddyfile, start Caddy)
   - git.start (print command to add remote, ask for confirmation)
   - claude-code.start (nothing extra)
8. Save activated plugins to .rl/plugins
```

### `rl rm`

```
1. Read .rl/plugins → [auth-proxy, git, claude-code]
2. Run rm hooks in REVERSE dependency order:
   - claude-code.rm
   - git.rm (remove remote, unset core.sshCommand)
   - auth-proxy.rm (stop Caddy if no other airlocks)
3. Destroy VM via aq (base)
4. Remove .rl/
```

### `rl claude` (command dispatch)

```
1. Command "claude" not built into base
2. Read .rl/plugins → [auth-proxy, git, agent-claude-code]
3. Read each plugin's plugin.toml commands field
4. agent-claude-code declares commands = ["claude"]
5. Execute plugins/agent-claude-code/commands/claude.sh
```

### `rl status`

```
Airlock: my-project
VM:      running (PID 12345, SSH port 2222)
Plugins: auth-proxy, git, claude-code
```

## Plugin Installation

### Core plugins

Shipped with the `rl` project. On install (cloning the repo + adding `bin/` to PATH), core plugins are symlinked or copied into `~/.config/rl/plugins/`.

### Third-party plugins

Manual in v1 — user clones or copies a plugin directory into `~/.config/rl/plugins/<name>/`. No `rl plugin install` command.

## Error Handling

### Dependency errors

- Plugin declares a dep not in `~/.config/rl/plugins/` → error: `"Plugin 'foo' requires 'bar', but 'bar' is not installed"`
- Circular dependency → error: `"Circular dependency detected: foo → bar → foo"`

### Host dep errors

- Missing binary → error: `"Plugin 'auth-proxy' requires 'caddy' on the host. Install with: brew install caddy"`
- Checked after dependency resolution, before VM creation (fail fast)

### Command conflicts

- Two activated plugins declare the same command → error at `rl new` time: `"Command 'code' claimed by both agent-claude-code and agent-codex"`

### Plugin not activated

- User runs `rl claude` but claude-code wasn't activated → error: `"Command 'claude' not available. Active plugins: git, auth-proxy"`

### Provisioning failure

- A plugin's `provision` hook exits non-zero → abort `rl new`, print which plugin failed, leave VM in place for debugging
- User can `rl ssh` to inspect, then `rl rm` to clean up

### Missing state

- No `.rl/plugins` file (pre-plugin airlock or base-only) → base-only behavior, no plugin hooks

### TOML parse errors

- Missing `plugin.toml` in a plugin directory → skip that directory with a warning
- Malformed TOML → error naming the plugin and the issue

## Shell Quality

All shell files (base, plugins, command scripts) must pass `shellcheck` with no warnings. Strict mode in every file:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

`shellcheck` is a required host dev dependency. CI (when added) should run `shellcheck **/*.sh`.

## Known Limitations

Written to `KNOWN-LIMITATIONS.md` in the project root during implementation. Updated as limitations are discovered.
