# Repo Split Migration Plan

Strategic split of the current `ai.rlock` repository into four distinct units, each with a clear single responsibility.

## Target topology

| Repo | Role | Contents |
|---|---|---|
| `aq` (exists) | VM + snapshot primitives, QEMU + firecracker backends | Nothing else. No plugin awareness. |
| `rlock` (new framework) | Plugin system, `bin/rl` dispatcher, snapshot orchestration, generic plugins | `bin/rl`, `lib/{plugin,toml,util,ui,snapshot}.sh`, `plugins/{git,branch}` |
| `ai.rlock` (this repo, narrowed) | AI-agent sandbox distribution | `plugins/{auth-proxy,agent-claude-code,agent-codex}`, AI UX bits (`rl auth`, `rl code` if AI-specific) |
| `<bake>` (new, name TBD) | CI / pre-baked-environment distribution | `plugins/{docker-engine,docker-compose,ruby-bundler,npm,mise,rails-*}`, CI-oriented commands |

Naming for the CI distribution is a placeholder (`<bake>`) pending domain availability. Likely candidates: `snapcompose`, `prebake.sh`, `oven.sh`, `proofed.sh`. The migration plan does not depend on the final choice — only the rename step at the end does.

## Guiding principles

1. **No regression for existing users** during migration. `rl new` continues to work after every checkpoint.
2. **Reverse-direction friendly**. Each step is independently revertible until the next step lands.
3. **Framework boundary is strict.** `rlock` knows nothing about Anthropic, OpenAI, Docker, Rails, npm. It only knows about plugins.
4. **Distributions own their commands.** Domain-specific commands (`rl auth`, `bake pr`) live in their distribution, not in `rlock`.
5. **Plugin protocol is the contract.** Changes to it require coordinated updates across consumers; bumped via a `protocol_version` field.

## Open questions to resolve before step 1

- **Distribution installation model.** Two options:
  - (i) Distribution is a Git repo that the user clones; its `plugins/` directory is added to `XDG_CONFIG_HOME/rl/plugins/` (or set via env var `RL_PLUGIN_PATH`). `rlock` itself stays a separate clone on PATH.
  - (ii) Distribution publishes a single install script that fetches `rlock` framework + the distribution's plugins into a versioned directory.
  - Recommendation: **(i)** for v1 — simpler, no installer mental model, easier to develop in parallel. Move to (ii) only when distribution lifecycles diverge enough that hand-coordinated installs hurt.

- **Command ownership.** Today `bin/rl` defines `new`, `code`, `status`, `rm`, `auth`, `help`. After the split:
  - `new`, `status`, `rm`, `help` → framework (`rlock`)
  - `code` → AI-specific (ai.rlock) — it's `ssh + tmux attach`, which is the agent's interactive UX
  - `auth` → AI-specific (ai.rlock) — manages API keys for `auth-proxy`
  - `branch` (subcommand) → framework (with `branch` plugin)
  - Future `snapc run` / `bake pr` → in `<bake>`
  - Plugins already declare `commands` in `plugin.toml`; the framework's dispatcher delegates by lookup. AI/CI distros add their commands via their own plugins. **No code change needed** in dispatcher logic — it already works this way.

- **Protocol versioning.** Add `protocol_version = 1` to `plugin.toml` schema now, before the framework is extracted. Framework rejects plugins with newer protocol than it supports.

## Migration steps

Each step is one or more PRs, ending with a verifiable state.

### Step 0 — Land the layered-snapshots design in this repo first

Before splitting, get the snapshot orchestration working in the current monorepo. Reasons:

- Refactor branch plugin onto new protocol → exercises the protocol in real code → catches API gaps before the framework is extracted.
- Adds `lib/snapshot.sh` — the thing that's about to move. Easier to extract once it's known to work.
- Lets us write integration tests against the AI-flow (`auth-proxy + git + branch`) and the CI-flow stubs (docker-engine + warm) in the same place.

**Deliverables** (per `docs/superpowers/specs/2026-05-11-layered-snapshots-design.md`):

- `lib/snapshot.sh` with `snapshot_cache_path`, `snapshot_lookup`, `snapshot_latest`, `snapshot_save`, `snapshot_rebase`, `snapshot_walk_chain`.
- `plugin.toml` schema gains `[snapshot]` section + `protocol_version = 1` field.
- `lib/plugin.sh` extended: `plugin_snapshot_strategy`, `plugin_snapshot_key`, `plugin_snapshot_build` helpers.
- Branch plugin refactored: no more direct `qemu-img` calls; uses `lib/snapshot.sh`.
- `docker-engine` and `docker-compose` plugins land here as well (the new docker-in-VM approach), still in this repo for now.
- Deprecated `docker` translator stays as is (already deprecated).

**Exit gate**: existing tests pass, `rl new` in a Rails+Postgres project boots a warm VM in <1s on cache hit. Benchmark recorded.

### Step 1 — Extract `rlock` framework repo

Create `github.com/pirj/rlock`. Copy out:

- `bin/rl`
- `lib/{plugin,toml,util,ui,snapshot}.sh`
- `plugins/{git,branch}`
- `test/` (the parts covering framework + git + branch)

Keep in this repo (`ai.rlock`):

- `plugins/{auth-proxy,agent-claude-code,agent-codex}`
- AI-specific tests
- The deprecated `docker` translator (until step 4)

**Wiring**: `ai.rlock` becomes a "plugin pack" — a repo whose `plugins/` directory is added to `RL_PLUGIN_PATH`. README explains: `git clone rlock && git clone ai.rlock; export RL_PLUGIN_PATH=$PWD/ai.rlock/plugins`. Eventually a one-line installer.

**Exit gate**: a user can clone `rlock` + `ai.rlock`, run `rl new` in a project, get the same AI-sandbox experience as before. Old `rl auth` / `rl code` still work (now provided by ai.rlock's plugins).

### Step 2 — Extract `<bake>` distribution repo

Create the CI distribution repo. Move from `ai.rlock` (and from the framework where applicable):

- `plugins/docker-engine`, `plugins/docker-compose` (just added in step 0) → move
- New plugins as separate commits/PRs in `<bake>` repo: `mise`, `ruby-bundler`, `npm`, `rails-db-migrations`, `rails-db-seeds`, `rails-load-db-schema`
- CI-flavor commands: `snapc run` (one-shot job), `bake pr` (PR-from-untrusted), `bake snapshot` (manage cached layers explicitly)

**Wiring**: `<bake>` is a plugin pack on the same model as `ai.rlock`. Combination `rlock + <bake>` gives the CI experience. `rlock + ai.rlock + <bake>` is also valid (an AI agent could use Docker-in-VM through `<bake>` plugins).

**Exit gate**: a user can run a sample CI job — `snapc run --image rails:warm` — that pulls the warm snapshot and executes the job in <1s wall clock.

### Step 3 — Delete the deprecated translator

Remove `plugins/docker` from `ai.rlock` (the original translator). Distribution users wanting Docker behavior install `<bake>` instead.

**Exit gate**: `ai.rlock` is down to its 3-4 plugins. The repo description is updated: "AI-agent sandbox distribution for rlock."

### Step 4 — Final docs sweep

- The original spec `docs/superpowers/specs/2026-05-11-layered-snapshots-design.md` is split:
  - Framework parts (plugin protocol, lib/snapshot.sh, branch refactor) → moved to `rlock/docs/specs/`
  - CI plugin parts (docker-engine, docker-compose, dep installers) → moved to `<bake>/docs/specs/`
  - This repo keeps only AI-relevant docs (CLAUDE.md, KNOWN-LIMITATIONS.md trimmed to AI scope, README rewritten).
- `TODO.md` is split per-repo too: framework TODOs (analytics, subset-detection, mirror) → `rlock`, CI-specific TODOs → `<bake>`, AI-specific (none currently) → here.

## Non-goals during migration

- **Plugin protocol bump beyond v1.** Step 0 introduces v1. Don't add v2 mid-migration.
- **Firecracker work.** Lives in `aq`, gated by post-Phase-1 benchmark.
- **Caddy registry mirror.** Future TODO, irrelevant to split.
- **Backwards compatibility shims** for users who already have an `ai.rlock` clone. We're pre-1.0 with one user (the author) — a clean break with a README note is enough.

## Risks

- **Plugin protocol gets exercised by only one consumer (this repo) before extraction.** The first real cross-repo consumer (`<bake>`) may find API gaps. Mitigation: keep protocol v1 minimal in step 0; deliberately delay any "nice-to-have" hook until step 2 reveals real needs.
- **Three-repo coordination is overhead.** Recommendation: while only the author is consuming all three, develop with all three checked out side-by-side under one parent directory. Set up a shared script that runs tests in all three.
- **Naming for `<bake>` not finalized.** Doesn't block steps 0-1. Step 2 is the first that needs the name (creates the actual repo). Decide before then.

## Decision points / sign-offs

- After Step 0: confirm benchmark target (warm `rl new` < 1s) is met. Otherwise revisit before extracting.
- Before Step 1: confirm distribution installation model (option (i) recommended).
- Before Step 2: name and domain for `<bake>` distribution.
- After Step 4: revisit `TODO.md` items and re-prioritize per-repo.
