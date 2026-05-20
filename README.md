# rlock

A plugin-driven framework for ephemeral, isolated coding environments on top of QEMU/KVM virtual machines. `rlock` provides the CLI (`rl`), the plugin protocol, and a layered qcow2 snapshot system. The interesting bits — what gets installed inside the VM, how secrets cross the boundary, which agent runs — live in plugin packs that consumers compose on top.

## Why VMs?

Containers share the host kernel. A determined process inside a container can escape; a hallucinated `rm -rf` can reach the host. Real isolation needs a hypervisor boundary. `rlock` uses [aq](https://github.com/pirj/aq) to spin Alpine VMs in seconds, and a layered snapshot mechanism to keep cold-start cheap.

## What the framework does

- **Plugin protocol** — `plugin.toml` + optional `plugin.sh` hooks. Plugins declare their dependencies, host requirements, triggers, commands, and (optionally) `[snapshot]` participation in the cached layer chain.
- **Layered snapshots** — every cached layer is a qcow2 file with a parent as its backing. `rl new` walks the chain in plugin order. Cache hits replay state in seconds; misses build on top of the parent and save a new layer. Three strategies (`cached`, `incremental`, `ephemeral`) cover dep installers, tool managers, and one-shot lifecycle plugins like migrations.
- **Generic plugins shipped here** — `git` (host-as-remote bridge) and `branch` (per-branch VM isolation via `<branch>@<base-sha>` keys).

## Plugin packs

The interesting use cases live in separate repos that depend on this framework:

- **[ai.rlock](https://github.com/pirj/ai.rlock)** — AI coding-agent sandbox. Provides `auth-proxy` (Caddy reverse proxy that injects API keys host-side), `agent-claude-code`, `agent-codex`. Use this when running Claude Code or Codex in "danger mode" against your codebase.
- **`<bake>`** (TBD) — CI / pre-baked-environment distribution. Provides `docker-engine`, `docker-compose`, and per-ecosystem dep installers (`mise`, `ruby-bundler`, `npm`, ...). Use this for fast PR sandboxes or local CI.

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│                       Host machine                        │
│                                                           │
│  rl (CLI) ──── lib/{plugin,snapshot,toml,...}.sh          │
│      │                                                    │
│      ├─→ aq new / start / stop / snapshot                 │
│      ├─→ qemu-img create -b <cache.qcow2>                 │
│      └─→ ~/.local/share/aq/cache/<plugin>/<key>/          │
│                                                           │
│  ═══════════════════════════════════════════════════════  │
│                    QEMU VM (Alpine)                       │
│                                                           │
│  /home/rlock/repo  ←─ pushed via the `git` plugin's       │
│                       host-as-remote SSH bridge           │
└───────────────────────────────────────────────────────────┘
```

A plugin pack adds plugins to a directory on `RLOCK_PLUGIN_PATH` (colon-separated, like shell `PATH`; defaults to `~/.config/rl/plugins`). The framework discovers them at `rl new`, resolves their dependencies, walks the snapshot chain, and runs their hooks.

## Commands

| Command | Behavior |
|---|---|
| `rl new [plugins...]` | Create a VM for the current repo. Activates plugins explicitly listed or matched by triggers. |
| `rl rm` | Destroy the current repo's VM. |
| `rl status` | Show VM state (running / stopped / ssh port). |
| `rl ssh` | SSH into the VM. |
| `rl <plugin-cmd>` | Any command a plugin declares in its `plugin.toml` (e.g. `rl branch`). |

## Prerequisites

| Dependency | Install |
|---|---|
| [aq](https://github.com/pirj/aq) | `git clone https://github.com/pirj/aq` |
| QEMU | `brew install qemu` / `apt install qemu-system` |
| `qemu-img` | bundled with QEMU |
| Git, SSH | pre-installed on macOS/Linux |

A plugin pack may add more (Caddy for `auth-proxy`, `yq`/`jq` for compose, etc.) — see its README.

## Quick start with a plugin pack

```sh
# Framework + AI plugin pack:
git clone git@github.com:pirj/rlock.git
git clone git@github.com:pirj/ai.rlock.git
export PATH="$PWD/rlock/bin:$PATH"
export RLOCK_PLUGIN_PATH="$PWD/ai.rlock/plugins"

cd your-project
rl new
```

Replace `ai.rlock` with another plugin pack (or layer several into a single directory) to switch use cases.

## Documentation

- [`docs/superpowers/specs/`](docs/superpowers/specs/) — design specs (layered snapshots, plugin protocol, branch isolation, ...).
- [`docs/superpowers/plans/`](docs/superpowers/plans/) — implementation plans.
- [`docs/superpowers/benchmarks/`](docs/superpowers/benchmarks/) — measured timings.
- [`KNOWN-LIMITATIONS.md`](KNOWN-LIMITATIONS.md) — what doesn't work yet.

## Project layout

```
bin/rl                   CLI dispatcher
lib/
  plugin.sh              plugin discovery, dependency resolution, hook execution
  snapshot.sh            layered qcow2 cache + walk_chain orchestrator
  toml.sh                tiny TOML reader (flat keys + named sections)
  util.sh                shared utilities
  ui.sh                  output helpers (spinner, info, warn, success)
plugins/
  git/                   host-as-remote git bridge (generic)
  branch/                per-branch VM isolation (generic)
test/                    BATS unit + integration tests
docs/                    specs, plans, benchmarks
```
