Sandbox remote agent connectors:
 - https://github.com/chenhg5/cc-connect
 - https://github.com/slopus/happy
 - https://github.com/nurikk/ccremote

Sandbox PRs

Why not just https://github.com/microvm-nix/microvm.nix#hypervisors ?!

Now, `rl new claude-code` takes minutes due to long installation.
Let the system cache preliminary results (key: combination of plugins) so those can be reused

rlock against local supply chain attacks https://github.com/philiprehberger

rlock for ci - faster startup than docker, one vm vs multiple containers, snapshots

rlock to back an open-source exe.dev clone

firecracker (linux host only) https://firecracker-microvm.github.io/
and other backends https://github.com/microvm-nix/microvm.nix#hypervisors

linux host

[RESOLVED in aq v2.4.0 "Bolt"] aq integration to skip first-boot setup on warm path.
 - The 15s sfdisk + resize2fs round-trip was eliminated by aq's per-size base
   catalog: each `alpine-base-<v>-<arch>-NG.raw` is pre-partitioned at full N
   from the start, no first-boot resize needed. Combined with direct kernel
   boot (also v2.4.0), `aq start` of a fresh VM is now ~6.3s on macOS HVF.
 - Sub-second warm boot is now achievable via the in-progress `kind = "live"`
   snapshot mechanism (see specs/2026-05-18-snapshot-kind-design.md), which
   captures memory state post-OpenRC + sshd ready.

Caddy-based caching mirror for language registries (rubygems.org, registry.npmjs.org, PyPI, etc.).
 - Extend auth-proxy plugin (or sibling plugin) with cache-only reverse proxies.
 - Guest hits host mirror via env (BUNDLE_MIRROR__HTTPS___RUBYGEMS_ORG, npm_config_registry, etc.).
 - Goal: kill the "gigs of traffic per layer rebuild" problem when lockfiles change.
 - Cross-project gem/npm cache sharing for free.
 - Defer until docker-in-VM + per-ecosystem layers ship and we measure real download pain.

Per-ecosystem snapshot layer order is driven by change frequency.
 - Layers higher in the chain rebuild more often.
 - Heuristic: npm > bundle > python deps > Dockerfile/compose (observed in practice).
 - Make order configurable per project? Or auto-reorder based on observed lockfile churn?
 - Revisit once we have real usage data.

[done 2026-05-19, commit f6c912e] Snapshot analytics. Shipped as `rl cache stats`. Per-plugin stats.json under $RL_CACHE_DIR/<plugin>/stats.json, recorded by walk_chain on each iteration (hit / miss / duration). Ephemeral layers are recorded too (every iteration is a miss). Disk usage stays in bake-cache. Open: average duration is total/misses — no median yet; "disk usage per plugin" surfaced separately by `bake-cache`. Reconsider both if churn signals make them load-bearing.

Subset-detection for snapshot keys.
 - Some plugins (e.g., rails-db-migrations when only new migrations are added) have additive-only key changes.
 - If snapshot_key emits a SET of hashes (one per migration file) and the new set is a strict superset of the cached set, run incremental build instead of fresh rebuild.
 - Requires extending snapshot_key protocol to optionally return a set.
 - Skip until analytics show it would meaningfully reduce rebuild time.

For the bakeri.sh spec (when written):
 - Document the shared "alpine + dockerd installed" layer.
 - It already exists by design: docker-engine plugin's snapshot_key is a
   constant ('docker-engine-recipe-v1'), so the cached qcow2 is shared
   across all projects that activate docker-engine. Any service stack
   (kafka in one VM, postgres in another, the layered Rails+PG fixture
   in a third) chains off the same base.
 - Measurement TODO: how long does `apk add docker docker-cli-compose`
   take cold vs. cache-hit rebase to that snapshot? And how big is the
   snapshot on disk? Currently ~470 MB. If the build is <10s, caching
   may not be worth the disk cost. Decide before the bakeri.sh release.
 - Companion measurement: at what point in the chain does caching pay
   off the most? (Likely the docker-compose `up + healthcheck` layer
   for typical projects, not the docker-engine layer itself.)
 - Do NOT introduce a separate "bare Alpine" snapshot below docker-engine.
   In bakeri.sh every VM activates docker-engine, so the bare-Alpine
   layer would always have exactly one descendant (+dockerd) — pure
   overhead in this distribution.

aq --memory=NG flag + live-snapshot RAM hotplug.
 - aq guests are hardcoded to -m 1G. Many kind=live snapshot consumers
   (especially Docker workloads under bakeri.sh) need 4-8 GiB to be
   meaningful: even a small compose stack with postgres + redis blows
   past 1 GiB working set.
 - Two related deliverables, both tracked in aq/ROADMAP.md (canonical
   location): (a) `aq new --memory=NG` flag + meta.json ram_size_mb
   pinning; (b) memory hotplug for grow-after-restore via QMP device_add
   pc-dimm, contingent on launching source VMs with -m N,maxmem=M,slots=K.
 - Cross-referenced here because consumers of "snapshot kind = live"
   (see specs/2026-05-18-snapshot-kind-design.md) need both before they
   can declare kind = "live" on Docker-class workloads.

[done 2026-05-19] Framework-base shared snapshot layer. The apk-add /
rlock-user / sshd-hardening block previously inline in `cmd_new` lives
in `plugins/_base` with a constant `snapshot_key`. `discover_plugins`
skips `_`-prefixed names so the layer is invisible to triggers and the
plugin CLI but `plugin_dir` still resolves it. `cmd_new` prepends
`_base` to walk_chain. Second cold `rl new` on the host hits the cache
regardless of distribution.

Linear chain limitation (deferred from layered-snapshots design).
 - qcow2 backing files are linear, so two sibling plugins (e.g. ruby-bundler
   and npm both depending only on mise) serialize in load order even though
   they're semantically independent. Acceptable for v1 but introduces
   unnecessary rebuild latency when only one of the sibling layers churns.
 - Possible fixes: per-sibling fork-and-merge of cached layers (complex), or
   merge-on-build into a single combined layer (loses cache-hit granularity).
 - Defer until analytics show siblings frequently rebuild in isolation.

[done 2026-05-19, commit f097dd6] `rl warm rebuild` — promotes the
running VM's current state into the topmost cached snapshot layer's
slot. Finds the topmost active plugin with `[snapshot]`, re-computes
its key, and overwrites $RL_CACHE_DIR/<plugin>/<key>/ (cold:
qemu-img convert; live: aq snapshot create). `snapshot_save` is
overwrite-safe — prior disk.qcow2 / memory.bin / meta.json are dropped
before writing so cold→live or live→cold promotions leave a clean
slot. 118/118 bats.

[done 2026-05-19, commit 003cfe2] snapshot_walk_vm_rebase loses earlier live layers' memory.bin. Fix: only touch incoming-memory.bin when the new layer is live (overwrite); on cold rebase, preserve. snapshot_walk_chain clears once at the start and before a miss-build boot. 3 new bats, 100/100.

[done 2026-05-19, commit 0456f0f] Skip rebase+boot+stop cycle for no-op snapshot_build layers via `snapshot_should_skip` hook. Plugin prints "skip" to stdout to bail out of an iteration before VM boot. Stdout-based signal because the framework's plugin dispatch falls through to exit 0 when a hook isn't defined (exit-code protocol would mistake "absent" for "skip"). bakeri.sh's mise / ruby-bundler / npm adopt it (commit dfb1e55).

Plugin protocol v2: "command-only plugin" semantic.

Today, a plugin that exists purely to host CLI commands (no [snapshot]
section, no provisioning hooks) must still declare `triggers = [...]`
to appear in ACTIVE_PLUGINS, so the framework's `dispatch_command` can
find it. The workaround is to mirror the distribution's union of
triggers in every command-only plugin — see bakeri.sh's bake-run /
bake-pr / bake-cache duplication. The 2026-05-19 architecture review
(Issue 3) calls this out as the kind of change that would justify
protocol_version = 2.

Candidate semantics:

  (a) `[plugin] always_active_for_dist = true` — auto-activate whenever
      ANY other plugin in the same distribution activates. Requires a
      distribution-membership concept the protocol currently lacks.
  (b) Dispatch from all DISCOVERABLE plugins, not just active ones.
      Risky for commands that assume their plugin's snapshot layer is
      built; safe for pure-CLI commands.

Either path means bumping `protocol_version` so old plugins that don't
declare new fields still work. Defer until we have a second reason to
bump (e.g. a needed change to the [snapshot] schema) so a single v2
bump batches multiple improvements.

Cross-machine snapshot transport.
 - Cached snapshots are host-local under ~/.local/share/aq/cache/. For CI
   fleets and team setups, sharing the cache across machines is
   significant — depot.dev built an OCI-compatible registry for this
   (chunk-level caching of disk + memory snapshots).
 - From specs/2026-05-18-snapshot-kind-design.md "Out of scope / follow-ups".
 - Bakeri.sh follow-up — not in MVP. Revisit when bakeri.sh hits multi-
   machine fleet use.

Cold-boot optimization reading list.

Reference: https://depot.dev/blog/optimizing-microvm-boot-times — Cloud
Hypervisor + Firecracker-focused, but several techniques transfer to
QEMU+Alpine. Mapping their tricks to where we'd apply them:

| Their trick                            | Where to apply in our stack                                                  |
|----------------------------------------|------------------------------------------------------------------------------|
| Direct kernel boot                     | base layer (first cold rl new per project, plus CI cold-start on cache miss) |
| fw_cfg instead of cloud-init for SSH   | base layer provisioning                                                      |
| kvm-clock + quiet boot, hugepages      | QEMU args in aq — helps warm-restore too                                     |
| Custom init instead of OpenRC          | Marginal — OpenRC is already light; ~1s saving vs a real compat risk         |

Two layers of the same chart "user runs rl new -> user can work":

 - depot has squeezed the lower layer (sub-second kernel boot) close to
   the limit and is now climbing into the upper one (experimenting with
   memory snapshot/restore).
 - Our spec builds straight on top of the upper layer (memory + disk
   snapshot of a fully provisioned VM), exploiting project-specific
   structure (single-tenant, content-addressable cache).
 - Phase 2 (Firecracker in aq) effectively hooks in the lower layer for
   free: Firecracker already does direct kernel boot, has no BIOS phase,
   and uses minimal device emulation. Most of depot's recipe is
   "build a Firecracker-like environment on top of Cloud Hypervisor" —
   we skip straight to Firecracker and get those wins by construction.

Cross-references the "aq integration to skip first-boot setup" TODO
above — same problem from a different angle. Sequence the work after we
measure where the 30 s warm boot actually spends its time on each layer
(see "Snapshot analytics" TODO).

CI: wire `integration_layered.sh` into the bats suite.
 - The integration script (test/integration_layered.sh) verifies the
   full snapshot chain with a real VM. Currently runs manually only.
 - Plumb it as a separate bats target (e.g. `bats test/integration/`)
   that the user can opt into with a flag, skipping by default to
   keep `bats test/` fast.
 - Needs a way to detect "are we on a host that can boot a VM?" so
   CI skips on linux-without-kvm and macOS-without-HVF runners.

End-to-end `cmd_new` smoke test in CI.
 - Validate the "sub-second warm" claim against a fresh runner.
 - Could reuse rails-pg-sample fixture from bakeri.sh.
 - Asserts warm walk_chain ≤ N seconds (some generous bound — bench
   shows 2.7 s typical).
 - Useful as a regression detector for changes to walk_chain /
   `cmd_new` boot ordering.

Explicit `--memory=1G` passed to `aq new` when no plugin declares.
 - Today `cmd_new` only passes `--memory=NG` when `max_snapshot_memory`
   returns non-empty. When all active plugins omit `[snapshot] memory`,
   aq falls back to its own default (1G). That's correct but
   non-obvious — `aq inspect` doesn't show explicit memory.
 - Make it explicit: always pass `--memory` to aq new, even if it's
   the same as aq's default. Helps debuggability and surfaces the
   value in `.memory` markers for downstream tooling.

In-place update of leaf incremental layers.
 - A snapshot layer with `strategy = "incremental"` rebuilds on cache
   miss by running its installer on top of the parent's cached state,
   rather than rebuilding from scratch. Useful for installers whose
   output is additive: `npm install -g @anthropic-ai/claude-code` to a
   newer version, `docker compose pull` of a newer image tag, `bundle
   install` adding a single new gem.
 - Today every incremental rebuild produces a new cache slot under
   $RL_CACHE_DIR/<plugin>/<key>/ because the snapshot key changes.
   When the layer is a LEAF in the active chain (no downstream plugin
   chains off its qcow2), the new slot has no descendants either way,
   so the old slot is dead weight on disk the moment the new one
   lands.
 - Proposed: when `snapshot_save` is called for a leaf-position layer
   that was built incrementally, overwrite the existing slot for this
   plugin rather than allocating a fresh one keyed by the new
   snapshot_key. Equivalent to `rl warm rebuild` (commit f097dd6) but
   triggered automatically on the cache-miss-via-incremental path
   instead of via explicit user command.
 - Open questions:
   - How does the framework know a layer is leaf in the *current*
     distribution? `walk_chain` knows position; cache invalidation is
     keyed per-plugin not per-chain. The "I'm leaf in this walk"
     signal lives at the call site of `snapshot_save`, not in the
     plugin metadata. Simplest path: `walk_chain` passes `is_leaf=1`
     to the save call when iterating the last plugin.
   - What does "in-place" mean on disk? qcow2 backing files are
     immutable from a child's perspective, but a leaf has no child.
     Atomic mv of the new disk.qcow2 / memory.bin / meta.json over the
     old slot is sufficient. Concurrent `rl new` on the same project
     is already serialized by aq's per-VM lock, so no readers race.
   - How does this interact with `rl warm rebuild` (which already
     overwrites the topmost active plugin's slot)? They converge to
     the same operation. Auto-trigger could be implemented as
     `walk_chain` calling the same internal helper at the right
     moment.
 - Unsafe cases that LOOK like increments but aren't: anything
   requiring data migration. Example: a `postgres-data` snapshot
   layer where the underlying PG major version changes between runs —
   the on-disk data directory layout is incompatible, `postgres`
   won't start against it. These are not increments; the layer needs
   a full rebuild from a pre-PG-data parent. The user-visible rule:
   if `snapshot_build` can produce the new state by running its
   provisioning steps on top of the previous state (and the result is
   correct), it's an increment. Otherwise it's a rebuild and the
   normal new-slot path applies. Plugin authors decide via the
   strategy declaration; in-place is just an optimization within the
   `incremental` strategy.
 - Defer until measured: do we have evidence that disk churn from
   incremental layer rebuilds is meaningful? Need a representative
   workload (e.g., claude-code minor version bumps + npm dep churn
   over 30 days) to know if this saves real disk vs being a clever
   optimization with no observable benefit.

## [done in v0.1.5] snapshot_walk_chain wall-clock overhead

Original size: 186 ms on rails-pg-sample warm (M3, R12 bench).
Mostly subprocess forks for `plugin_has_snapshot`,
`plugin_snapshot_strategy`, `plugin_snapshot_kind`, `run_hook
snapshot_key` per plugin in the chain — each reads the plugin's
`plugin.toml`, each is a `bash -c` hop.

**Shipped in v0.1.5** as in-process memoize (NOT a persistent
cache). `lib/toml.sh` gained `_TOML_CACHE` (file path → file
content) and `lib/plugin.sh` gained `_PLUGIN_DIR_CACHE` +
`plugin_meta_prefetch`. Hot loops (`detect_triggers`,
`snapshot_walk_chain`) call prefetch at entry; the bash assoc
arrays inherit into the `$(...)` subshells where `plugin_dir` /
`toml_get*` get called, and those parse from the in-memory
strings via bash builtins instead of forking sed/awk. The cache
lives only for the lifetime of one `rl new` process — child
subshells read it but writes don't propagate back to the parent.

Measured save: ~70 ms wall-clock + tighter variance (per-fork
CPU contention that produced bimodal cohorts in v0.1.4 is gone).

### Possible follow-up (defer until profiled)

Remaining framework overhead after v0.1.5 is ~750 ms (M3
full-stack warm bake-run after R16 = 1854 ms total, aq phase
~1100 ms). The non-aq slice splits roughly:
- bake-run preprocess (~80 ms — synthesise prebuild + first detect_triggers, paid before rl is called)
- rl new orchestration (~250 ms — aq new + resolve_deps + check_* + spinners)
- snapshot_walk_chain core (~100 ms — what's left after the memoize)
- do_ssh + exec wrapper (~26 ms)

To attack further, profile with `bash -x` + timestamps inside
`rl new` (not just at entry/exit). The biggest single block is
`aq new` itself (port allocation, meta.json write, uefi-vars
copy on x86_64) — that's aq territory, not rlock's. Inside
rlock, candidate wins: skip `aq stop` when VM isn't running
(we currently call it as a no-op; ~30 ms each), elide spinner
in non-tty mode (the spinner_start/stop pair is a fork pair
per layer, ~5 ms × N layers).

None of this is worth doing speculatively — the 80 % win came
from the elimination of the *known* hot loops; what's left is
diffuse and would take more time to optimize than it'd save
per call.
