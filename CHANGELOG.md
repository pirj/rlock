# Changelog

All notable changes to rlock — one-liner per change. Date-stamped releases group related work; the latest unreleased work sits under `## Unreleased`.

## Unreleased

- (nothing pending)

## v0.1.7 — 2026-05-27

### Switch from AQ_MEMORY_PATCH_MODE to AQ_MEMORY_SNAPSHOT enum

Pairs with aq v2.5.35's enum refactor. `snapshot_save` (live
kind) now passes `AQ_MEMORY_SNAPSHOT=zstd-patch` (plus the
existing `AQ_PARENT_MEMORY_ZST=<path>`) to `aq snapshot create`
when the caller set `AQ_MEMORY_SNAPSHOT=zstd-patch` in the
environment and the parent layer is a live cache entry with a
memory.bin.zst.

Breaking change in lockstep with aq v2.5.35:
- old: caller sets `AQ_MEMORY_PATCH_MODE=1`; rlock passes that flag through
- new: caller sets `AQ_MEMORY_SNAPSHOT=zstd-patch`; rlock passes it through

Requires aq ≥ v2.5.35. Older aq won't recognise the new env
var and silently ignores it, producing plain pzstd output.
Restore-side chain reconstruction is unchanged from v0.1.6 —
detection is based on the on-disk `memory.bin.zstpatch` file
shape, not on env vars.

## v0.1.6 — 2026-05-27

### B5 wiring — zstd --patch-from for stacked live layers (opt-in)

When `AQ_MEMORY_PATCH_MODE=1` is set in the environment,
`snapshot_save` (live kind) now passes
`AQ_PARENT_MEMORY_ZST=<parent_plugin>/<parent_key>/memory.bin.zst`
to `aq snapshot create`, which emits the live memory state as
a zstd delta against the parent's decompressed memory (see
aq's v2.5.34 entry). When the parent isn't a live layer or no
parent.memory.bin.zst exists in the cache, save behaviour is
unchanged from v0.1.5.

The captured artifact is a `memory.bin.zstpatch` plus a
`memory.format` sentinel — stored alongside disk.qcow2 and
meta.json under `$RL_CACHE_DIR/<plugin>/<key>/`.

On restore, `snapshot_walk_vm_rebase` detects `.zstpatch` on
the leaf live layer and reconstructs the raw memory.bin via
chain walk:
1. Follow meta.json's `parent_plugin` / `parent_key` links
   back until a layer with full `memory.bin.zst` is reached
   (the chain base).
2. Decompress the base into a working raw file (parallel via
   pzstd if available, else sequential zstd).
3. For each forward link, apply
   `zstd -d --patch-from=<working_raw>` to the layer's
   `.zstpatch`, replacing working_raw with the result.
4. Move the final raw into vm_dir/incoming-memory.bin so aq's
   `-incoming file:` consumer uses it like any plain memory
   snapshot.

Chain reconstruction is single-thread + sequential; each step
takes ~2–3 s per 1.6 GiB raw layer on M3. The trade is disk vs
restore time: ~95 % less disk per delta layer in exchange for
~2–3 s per extra link at restore. Useful when CI cache / OCI
push size is the binding constraint and chain depth is shallow
(2–4 layers); plain pzstd (v2.5.33) remains the better choice
for deep chains or laptops where disk is plentiful.

Not yet exercised by the existing rails-pg-sample fixture —
that workload has a single live layer (`docker-compose`), so
the patch path never triggers. A multi-live-layer fixture is
needed to bench the actual disk/time tradeoff. Plumbing only
in this release.

## v0.1.5 — 2026-05-27

### Skip duplicate `detect_triggers` in non-tty mode

`rl new`'s post-resolve "extra triggered plugins" prompt branch
iterates every available plugin and reads each `plugin.toml` —
~120 ms on M3 with 13 plugins. The branch then offers an
interactive `read -rp` confirmation that can't accept input
without a tty, so the whole detection pass is dead weight for
programmatic callers (`bake run`, scripts, CI). Add `-t 0`
guard at the branch top to skip the detection entirely when
stdin is not a tty. Save: ~70–120 ms per warm `rl new`.

### In-process memoize for plugin TOML reads

Hot loops (`detect_triggers`, `snapshot_walk_chain`) called
`plugin_dir` + `toml_get*` for many plugins via `$(...)`
subshells — each call forked `sed`/`awk`. Add a parent-shell
prefetch (`plugin_meta_prefetch`) that slurps every discoverable
`plugin.toml` into an associative array (`_TOML_CACHE` in
`toml.sh` + `_PLUGIN_DIR_CACHE` in `plugin.sh`). Bash inherits
the arrays into subshells, so subsequent `toml_get*` calls in
`$(...)` parse the cached strings via bash builtins instead of
forking. Not a disk-based cache — purely subshell-inherited
memoize within one `rl new` process; the cache only lives for
the lifetime of the shell that ran prefetch.

Save: ~70 ms wall-clock on M3 warm restore (rails-pg-sample,
~13 plugins). Variance also tightens because the per-fork CPU
contention that produced bimodal warm cohorts in v0.1.4 is gone.

## v0.1.4 — 2026-05-26

### Stage memory.bin via hardlink instead of cp

`snapshot_walk_vm_rebase`: stage cached `memory.bin[.zst]` to the
vm_dir via `ln` (hardlink) instead of `cp`. Zero-copy when cache
and vm_dir share a filesystem (the normal case). qemu reads the
file once and removes the staged path after migration; with a
hardlink the cache file's inode is preserved by the remaining
refcount. Falls back to `cp` on cross-fs / hardlink-disallowed
setups. Expected saving on cross-host warm restore: ~5–7 s on
GH Actions Azure disks (550 MB file copy → instant link).

## v0.1.3 — 2026-05-24

### Stage memory.bin to vm_dir after a live miss save

v0.1.2's live-promotion rule was incomplete: `snapshot_save` deposits
`memory.bin[.zst]` into the cache dir but didn't stage it into
`$_vm_dir`, so the NEXT layer's miss-path build still cold-booted
from its own dirty storage.qcow2 (build mutations baked in, no
memory) and lost the running state we just captured.

- After a live `snapshot_save`, re-rebase storage.qcow2 onto the
  just-saved cache entry via `snapshot_walk_vm_rebase`. That copies
  `memory.bin[.zst]` from the cache dir into `$_vm_dir` as
  `incoming-memory.bin[.zst]` for the next boot, exactly like cache
  hits do.

## v0.1.2 — 2026-05-24

### "After live → all live" rule in snapshot_walk_chain

Once any layer in the chain (cache-hit or freshly-built) is live,
all subsequent layers are force-promoted to live. Previously, a
cold layer on top of a live ancestor required a cold-reboot of the
VM for the build, which:
- Lost any ambient services started by the live ancestor (running
  postgres, warm dockerd, redis page cache).
- Triggered rc-update to auto-start services to a different on-disk
  state, creating a memory↔disk inconsistency at the final restore.

The fix: promotion keeps the VM live-restored throughout the chain
so each layer's `snapshot_build` sees the cumulative running state
and captures it. Storage cost is bounded by TTL-based GC and the
opt-in `zstd --patch-from` mode (see aq's ROADMAP).

- `snapshot_walk_chain`: track `chain_has_live` flag. Force
  `kind=live` for all layers downstream of the first live one.
- Cache hits that lookup a cold entry under a live-promoted chain
  are treated as stale (fall through to miss path and rebuild as
  live).
- Live-promoted misses keep `incoming-memory.bin` staged for the
  build VM so it boots live-restored (previously cleared).

Surfaced by `pirj/bakerish-rails-pg-example` CI: docker-compose
captured postgres live, then the cold git + prebuild layers
clobbered docker daemon state during their cold-rebuild boots; the
final restore saw memory saying "postgres running" but disk saying
"all containers stopped" → `docker compose exec db` reported
service not running. Promotion eliminates the cold-reboot in
between.

## v0.1.1 — 2026-05-23

### `rl new --size=NG`

Accept `--size=<N|NG>` to override `aq new --size`. Default remains
`16G` — generous for arbitrary CI workloads — but small projects
can now drop to `4G`–`8G` via `bake run` reading `[disk] size` from
`bakerish.toml` (which threads it through as this flag).

- `cmd_new`: parse `--size` alongside `--memory`; strip optional
  trailing `G`. Default unchanged at `16G`.
- Use in conjunction with bakeri.sh v0.1.2's `[disk] size` field
  to declare a project-wide preference.

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
