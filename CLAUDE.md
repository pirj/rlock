# rlock — orientation for agents

`rlock` is the **plugin-driven framework** for ephemeral, VM-isolated
workspaces. It owns the `rl` CLI, the plugin protocol, and the layered
qcow2 snapshot orchestrator. The use cases — AI coding agents, CI
pre-baked envs, anything else — live in **plugin packs** that depend
on this repo.

For project background and quick start see [`README.md`](README.md);
for what doesn't work yet see
[`KNOWN-LIMITATIONS.md`](KNOWN-LIMITATIONS.md); for the security
boundary see [`SECURITY.md`](SECURITY.md); for open mechanical work
see [`TODO.md`](TODO.md).

## What rlock is (and isn't)

**Is:** plugin discovery + dependency resolution, layered qcow2
snapshot orchestration (cached / incremental / ephemeral), two
generic in-tree plugins (`git` host-as-remote bridge, `branch`
per-branch VM isolation). Subprocess wrapper around
[`aq`](https://github.com/pirj/aq) for VM lifecycle.

**Isn't:** opinionated about *what* runs in the VM. No Claude Code,
no Caddy, no Docker installation, no API-key handling — those belong
in plugin packs ([`ai.rlock`](https://github.com/pirj/ai.rlock) for
AI agents; snapcompose for CI / pre-baked envs).

## Hard constraints

- **Bash, not POSIX sh.** Arrays, `[[ ]]`, `local`, `set -euo pipefail`
  are all used. The host runs Bash 5+ (Homebrew on macOS, distro on
  Linux).
- **Host-side only.** `rl` runs on the developer's machine. The guest
  runs Alpine via `aq`; nothing in `rlock/` ever ships into the guest
  except via a plugin's explicit provisioning step.
- **No vendor lock-in inside the framework.** A change that hardcodes
  Anthropic / OpenAI / Docker / a specific compose schema belongs in a
  plugin pack, not here. The two in-tree plugins (`git`, `branch`)
  are deliberately generic.
- **Snapshot on-disk format is a contract.** `aq` and the plugin packs
  rely on the layered qcow2 layout, `memory.bin[.zst|.zstpatch]`
  artifacts, and `meta.json` shape. Any format change needs a
  CHANGELOG entry, a benchmark, and coordinated bumps in `aq` and
  consumers.

## Mental model

```
rl <command>
   │
   ├── lib/plugin.sh   discovery from $RLOCK_PLUGIN_PATH,
   │                   dependency resolution, hook dispatch
   │
   ├── lib/snapshot.sh walk_chain(plugin_order):
   │                     for each plugin with [snapshot]
   │                       key = snapshot_key()
   │                       if cache hit  → rebase VM onto cached layer
   │                       if cache miss → boot + snapshot_build + save
   │
   ├── lib/toml.sh     flat-keys + [section] reader for plugin.toml
   ├── lib/util.sh     shared utilities
   ├── lib/ui.sh       info / warn / success / spinner
   │
   └── plugins/{git,branch}/   the two generic in-tree plugins
```

Plugin packs add their own directories to `RLOCK_PLUGIN_PATH`
(colon-separated, like shell `PATH`). The framework discovers them
at `rl new`, resolves `[dependencies]`, walks the snapshot chain,
runs their hooks.

## Plugin protocol

Each plugin is a directory:

```
plugins/<name>/
├── plugin.toml      manifest: deps, triggers, commands, [snapshot]
├── plugin.sh        lifecycle hooks (Bash functions)
└── commands/        optional CLI subcommands dispatched by `rl`
```

- **`protocol_version`** in `plugin.toml` should be explicit (`"1"`).
- **Snapshot participation** is opt-in via a `[snapshot]` section.
  Three strategies (see `docs/superpowers/specs/`):
  - **`cached`** — plugin contributes a layer to the chain; on hit,
    `snapshot_build` is skipped. Dep installers (`bundle install`,
    `npm install`) use this.
  - **`incremental`** — plugin's `snapshot_build` runs on every
    `rl new` but its output is stable enough to live below higher
    layers without invalidating them. Tool managers like `mise` use
    this.
  - **`ephemeral`** — plugin runs at boot, contributes no cached
    layer. Migrations, one-shot fixups.
- **Hooks** are Bash functions in `plugin.sh`. The framework calls
  `snapshot_key`, `snapshot_build`, `snapshot_should_skip`, `start`,
  `rm` by name. See `lib/plugin.sh` for the dispatch.
- **`_`-prefixed plugin names** (e.g. `_base`) are hidden from
  `discover_plugins` so they don't appear in triggers / CLI but
  still resolve via `plugin_dir`.

## Conventions

- **Names:** plugins are kebab-case (`docker-compose`,
  `agent-claude-code`); shell functions are snake_case.
- **`bin/rl` is the entry point** — keep it thin. New logic goes
  into `lib/` or the relevant plugin.
- **Tests:** BATS in `test/`. Unit tests source `lib/*.sh` directly;
  integration tests drive the `rl` CLI. `test/integration_layered.sh`
  is the end-to-end smoke for snapshot chains.
- **Output:** use `info`, `warn`, `success`, `spinner` from
  `lib/ui.sh`. No bare `echo`/`printf` to stderr in user-visible
  paths.

## Linting (shellcheck)

All shell scripts must pass
`shellcheck --severity=warning --external-sources`. CI enforces this
on every push and PR via `.github/workflows/shellcheck.yml`; run the
same check locally before committing shell changes.

Disable findings only with inline `# shellcheck disable=SCxxxx  # reason`
directives. Do not disable warnings repo-wide. The repo-level
`.shellcheckrc` only sets `external-sources=true` and
`source-path=SCRIPTDIR` so sourced libs resolve correctly.

## What NOT to do

- Don't put AI-agent / Caddy / Docker / language-runtime code in
  this repo. That's a plugin pack's job. The grep test: if a string
  like `ANTHROPIC` or `docker-compose` lands in `lib/` or
  `plugins/{git,branch}/`, it's in the wrong repo.
- Don't bypass `aq`. The framework talks to VMs only through `aq`
  subcommands; reaching for `qemu-system-*` directly leaks the
  abstraction.
- Don't change snapshot-chain semantics without a CHANGELOG entry
  and a benchmark. `ai.rlock` / snapcompose / `rlock-server` all
  depend on the layered-qcow2 contract.
- Don't add framework features speculatively. Plugin protocol v2
  ideas live in `TODO.md` until a real consumer needs them.

## Sibling repos

- [`aq`](https://github.com/pirj/aq) — the QEMU/Alpine VM wrapper
  this framework drives. The two repos move in lockstep when the
  snapshot format changes.
- [`ai.rlock`](https://github.com/pirj/ai.rlock) — the AI coding
  agent plugin pack (auth-proxy, agent-claude-code, agent-codex).
- snapcompose — the CI / pre-baked-env plugin pack (private; see
  umbrella `CLAUDE.md`).
- `rlock-server` — the closed-source commercial control plane that
  drives `rlock` programmatically. Private.

## Where decisions go

- **Mechanical work** → [`TODO.md`](TODO.md).
- **Single-repo cornerstone decisions** → CHANGELOG entry on the
  release that lands them.
- **Cross-cutting decisions** that affect rlock + sibling repos →
  ADRs in `../meta/decisions/`. See `../meta/CLAUDE.md`.

## Workspace context

This repo lives at `~/source/ai.rlock/rlock/` inside the umbrella
workspace. The umbrella's [`CLAUDE.md`](../CLAUDE.md) is the single
best map of how all sibling repos connect.
