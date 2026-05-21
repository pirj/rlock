# Changelog

All notable changes to rlock — one-liner per change. Date-stamped releases group related work; the latest unreleased work sits under `## Unreleased`.

## Unreleased

- (nothing pending)

## v0.1.0 — 2026-05-21

Initial public release. Plugin protocol, snapshot chain, the lot.

### Framework
- Plugin protocol with `plugin.toml` + `plugin.sh` (hooks: `snapshot_key`, `snapshot_build`, `snapshot_should_skip`, `provision`, `start`, `rm`, `resolve_vm`).
- `discover_plugins` + DAG `resolve_deps` + trigger-based auto-prompt at `rl new`.
- `dispatch_command` with two-pass lookup (active plugins first, all discoverable as fallback).
- `RLOCK_PLUGIN_PATH` — colon-separated PATH-like list of plugin dirs.

### Snapshot chain
- `snapshot_walk_chain` with `cached` / `incremental` strategies, `cold` / `live` kinds.
- Framework-base `_base` shared snapshot layer (apk-add + rlock user + sshd hardening) auto-prepended.
- `snapshot_should_skip` hook short-circuits no-op layers (~5–7 s saving per skipped).
- Pipelining v1: removed pre-walk boot from `cmd_new` (warm 8 s → 3 s on rails-pg-sample).
- Pipelining v2: coalesce consecutive cache-hit rebases into one (sub-second incremental win).
- zstd-compressed `memory.bin.zst` round-trip via aq (`-incoming exec:zstd -dc`); transparent `.bin` / `.bin.zst` handling in `snapshot_save` / `snapshot_walk_vm_rebase` / `snapshot_prune`.
- Live-layer `memory.bin` chain preservation through subsequent cold rebases.
- Snapshot analytics — per-plugin stats.json, surfaced via `rl cache stats`.
- `rl warm rebuild` — promote running VM state into the topmost cache slot (out-of-band Docker state persistence).
- Overwrite-safe `snapshot_save` (cold→live / live→cold replacement leaves no stale `memory.bin`).

### CLI
- `rl new [--memory=NG] [--name=<vm>] [plugins...]` — `--memory` overrides per-plugin max; `--name` overrides cwd-basename-derived VM name.
- `rl status` / `rl rm` / `rl ssh`.
- `rl warm rebuild` / `rl cache stats`.

### Stock plugins shipped
- `_base` (framework-internal).
- `git` — host-as-remote SSH bridge; auto-adds the `rl` remote and pushes HEAD on `rl new`.
- `branch` — per-branch VM resolution.

### TOML parser (`lib/toml.sh`) — generic, downstream-reusable
- `toml_get`, `toml_get_array`, `toml_get_in_section`, `toml_get_array_in_section`.
- `toml_validate` (rejects duplicate table headers per TOML 1.0).
- Downstream-reusable: bakeri.sh + ai.rlock source via `${RL_LIB_DIR}/toml.sh`.

### Removed
- `ephemeral` snapshot strategy. Had zero adopting plugins; behaviour better expressed as either `cached` with proper `key_files` or as a `start` hook. Old plugin.toml declaring it now fails with "unknown snapshot strategy".
- Singular `PLUGIN_USER_DIR` env var (use `RLOCK_PLUGIN_PATH` — colon-list, PATH-like).

### Tests
- 134/134 bats covering plugin discovery, dep resolution, snapshot chain (all strategies × kinds), warm-rebuild overwrite-safety, TOML parser including reuse contract.
