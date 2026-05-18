# Snapshot Kind (cold vs live) — Consumer-Driven Selection

## Background

The layered snapshot framework (see [`2026-05-11-layered-snapshots-design.md`](2026-05-11-layered-snapshots-design.md))
already orchestrates per-plugin cached qcow2 chains, with three strategies
(`cached`, `incremental`, `ephemeral`). Each layer's `snapshot_build` runs
inside a booted VM; on completion the framework saves the state.

Today, **what gets saved is only disk state** — `qemu-img convert` of the
stopped VM's qcow2. The framework relies on aq's cold-snapshot mechanism
(see `aq/docs/specs/2026-04-30-aq-ci-snapshots-design.md`). The `aq`
binary, however, also supports **live snapshots** since v2.2 — paused VM
with disk plus `migrate file:` memory dump. Restoring a live snapshot
brings the guest back at exactly its captured runtime state.

Phase 2 of `aq` (direct kernel boot, 2026-05-17) cut warm `aq start` from
~14 s to ~6 s. The residual ~6 s is QEMU init (~2 s), kernel→userspace
(~2 s), and OpenRC startup (~2 s). A **live snapshot taken after
OpenRC + sshd are ready** would let `aq new --from-snapshot=warm-base`
skip kernel + userspace + service startup — empirical target ~2 s wall
clock, ~3× faster than the current direct-kernel cold boot.

The cost is disk: a live snapshot carries the entire guest RAM dump (≥ 1
GiB at aq's current `-m 1G` default — and meaningfully more for any
workload that allocates seriously, e.g. Docker easily exceeds 1 GiB
working set). Cold snapshots stay sparse and small.

## Problem

Whether a given layer should be live-snapshotted is a **per-layer cost/
benefit decision** that the framework cannot make on its own:

- An idle `docker-engine` layer (just dockerd installed, no images yet)
  is small (~50 MiB disk delta) but, if live-captured, also drags a 1+
  GiB memory dump even though the memory doesn't help — dockerd hasn't
  cached anything meaningful.
- A `docker-compose` layer with the application stack `up` + healthy
  services has the runtime state plus images pulled — its memory dump
  contains caches, page cache for hot files, db connection pools,
  fork-prepared workers. Restoring this skips `docker compose up`
  entirely.
- A `branch` layer is git overlay — there's no memory state worth
  saving.

The framework should not pick. The plugin author and ultimately the
distribution (rlock vs ai.rlock vs bakeri.sh) should pick per layer.

## Goals

1. Add a per-layer `kind` field to the `[snapshot]` section of
   `plugin.toml`, with values `cold` (default) and `live`.
2. The framework's `snapshot_save` in `lib/snapshot.sh` branches on
   `kind` and calls the appropriate `aq snapshot create` path: cold for
   stopped VM, live for running VM.
3. Document the disk and time tradeoff so distribution authors choose
   informed.

## Non-goals

- Auto-tuning `kind` based on observed memory usage. Out of scope; a
  future analytics-driven optimization (already tracked in TODO under
  Snapshot analytics).
- Configurable VM RAM beyond aq's current `-m 1G`. Many docker-heavy
  workloads need 4-8 GiB. That is an `aq` change (a `--memory=NG`
  flag analogous to `--size=NG`), tracked separately. The live-snapshot
  cost analysis below assumes whatever RAM `aq` is configured for.
- Cross-machine snapshot transport / cache sync. Cached snapshots stay
  per-host.

## Design

### Plugin protocol

`plugin.toml`:

```toml
[snapshot]
strategy = "cached"   # unchanged: cached | incremental | ephemeral
kind     = "cold"     # new field: cold (default) | live
```

`kind = "live"` means: when this layer is saved, the framework takes a
live snapshot of the running VM (paused + memory dump + disk). On
restoration, the next-layer build (or the final VM start) consumes the
saved state with `aq new --from-snapshot=<live-tag>`.

`kind = "cold"` means today's behaviour: stop the VM, `qemu-img convert`
its disk, save under the layer's cache key.

### Framework changes

In `lib/snapshot.sh`, `snapshot_save` gains a `kind` parameter. The
`snapshot_walk_chain` orchestrator already calls `snapshot_save` after
`snapshot_build`; it reads `kind` from the plugin manifest and forwards
it.

For `kind = "live"`:
- VM is **not** stopped before save (cold flow stops first).
- `snapshot_save` invokes `aq snapshot create --live <vm> <tag>` (existing
  aq command), which performs the QMP pause + memory migrate + disk
  copy + resume sequence.
- The cache entry contains both `disk.qcow2` and `memory.bin` (aq
  already produces both for live snapshots; the framework just registers
  the tag in its layer cache).

For `kind = "cold"`:
- Unchanged from current Step 0 behaviour.

### Cache layout

Same as today (`~/.local/share/aq/cache/<plugin>/<key>/`), plus
optionally `memory.bin` for live entries. The cache lookup logic doesn't
change — a layer either has its directory or it doesn't.

`meta.json` gains a `kind` field so the framework knows how to restore.
`aq new --from-snapshot=<tag>` already handles both kinds based on the
presence of `memory.bin`; the framework relies on this.

### Restoration

When walking the chain and a `live`-kind layer cache-hits, the framework
must use `aq new --from-snapshot=<tag>` to materialize the VM (because
that's what loads memory). For pure cold chains the existing path
(qemu-img create overlay) still works.

This means the framework's `snapshot_walk_chain` needs to know, before
booting the VM for the next miss, whether any ancestor in the chain was
live — if yes, the VM must be created via `aq new --from-snapshot`
rather than `aq new` + rebase.

### Tradeoff reference (for plugin authors)

| Aspect | `cold` | `live` |
|---|---|---|
| Disk per cached entry | ~10-500 MiB (sparse delta only) | ~1 GiB + delta (RAM dump + delta) |
| Warm `aq start` after cache hit | ~6 s (Phase 2 direct kernel boot) | ~2 s (memory resume, no boot) |
| Sensitive to Alpine version bump | Yes (kernel/userspace in disk) | Yes (RAM contains process state from old kernel) |
| Sensitive to RAM-size change in aq | No | Yes (snapshot RAM size must match) |
| Snapshot creation time | Fast (qemu-img convert, sparse) | Slower (full RAM dump, ~1 GiB write) |

### Recommended `kind` by plugin type (initial heuristic)

| Plugin family | Recommended `kind` | Rationale |
|---|---|---|
| `docker-engine` | `cold` | Idle dockerd; no useful runtime state to preserve. |
| `docker-compose` (warm) | `live` | Running services, page cache, db connection state — the big win. Docker workloads may push RAM well past 1 GiB; aq RAM sizing follow-up applies. |
| `mise`, `nvm` (tool managers) | `cold` | Static binaries on disk; no runtime state. |
| `ruby-bundler`, `npm` (dep installers) | `cold` | Vendor dirs on disk. Live snapshot of a freshly-finished bundler doesn't help much. |
| `rails-db-migrations` | n/a | `strategy = "ephemeral"` already, no snapshot saved. |
| `branch` (per-branch git overlay) | `cold` | Git overlay on disk; no runtime state. |
| `agent-claude-code` / `agent-codex` (ai.rlock) | `cold` | Installed binaries; the agent starts on demand via tmux when user runs `rl code`. No prepared runtime state. |
| `framework-base` (future, in rlock) | `live` | The single best target for "sub-second `rl new`": Alpine booted, sshd ready. ~1 GiB RAM cost shared across every project that uses rlock. |

Distributions can override these defaults — the heuristic is what we
ship; individual deployments customize per workload.

## Implementation surface

`lib/snapshot.sh`:

- `plugin_snapshot_kind <plugin>` — new helper reading `[snapshot].kind`.
  Default `cold` if absent.
- `snapshot_save` — accept `kind` parameter, branch to `aq snapshot
  create --live` or `aq snapshot create` (cold).
- `snapshot_walk_chain` — when iterating layers, pass the resolved
  `kind` into `snapshot_save`. When a cache hit's `meta.json` declares
  `kind=live`, switch the materialization path to `aq new
  --from-snapshot=<tag>`.

`lib/plugin.sh`:

- `plugin_snapshot_kind` lookup via existing `toml_get_in_section`.

`aq snapshot create --live <vm> <tag>` — already exists in aq today. The
framework only needs to call it correctly.

`aq new --from-snapshot=<tag>` — already handles both cold and live tags.

Estimated diff: ~50-100 lines in `lib/snapshot.sh` + `lib/plugin.sh`,
plus one new test in `test/snapshot.bats` covering `kind=live` save and
restore via stub VM ops.

## Risks

- **Live-snapshot incompatibility with kernel updates** — same as cold.
  Phase 2's boot_mode_checksum machinery (in aq) already refuses
  mismatched live restores. No new mechanism needed at the framework
  layer.
- **Restore path divergence** — `aq new --from-snapshot=...` vs `aq new`
  + qemu-img rebase have different semantics around overlays. Pure cold
  chains may not need the snapshot-restore path. Implementation must
  detect ancestor `kind` and pick consistently.
- **Disk cost surprise** — a layer flipped from `cold` to `live` quietly
  adds 1 GiB+ per cached entry. Framework should emit a one-line
  "Saving live snapshot (~1.2 GiB)" message on save so the user notices.
- **Distribution dependence on aq RAM size** — if aq later raises the
  default `-m` value, all `kind=live` layers cached at the old size are
  invalid. The framework's existing snapshot incompatibility refusal
  (boot_mode checksum) covers boot mode but not RAM size. Add a
  `ram_size` field to live snapshot `meta.json` and refuse on mismatch.

## Out of scope / follow-ups

- **`aq --memory=NG` flag** — parallel to `--size`. Tracked in aq, not
  this spec. Many `kind=live` layers will only earn their keep when aq
  guests can be sized to 4-8 GiB.
- **Auto-tuning** — see Snapshot analytics in TODO.
- **Snapshot prune for live entries** — same algorithm as today, but
  live entries should be the first to evict under disk pressure given
  their cost. A future tweak to `snapshot_prune`.
- **Cross-machine cache transport** — depot.dev's OCI registry pattern
  for shared cache; out of scope.
