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

Framework-base snapshot layer (in rlock itself, not in any distribution).
 - Today `cmd_new` runs base provisioning (apk add bash curl sudo
   openssh-server-pam + rlock user + sshd hardening) inline. Skipped on
   warm path when any plugin has a cache hit, but on FIRST cold run for
   any project it costs ~15-30 s. Same work runs again on every fresh
   project.
 - Promote this into a built-in snapshot layer keyed by the framework's
   own recipe hash. Shared across every distribution and every project:
     framework-base
       |-- ai.rlock chain (+auth-proxy / +agent-* / +git ...)
       `-- bakeri.sh chain (+docker-engine / +docker-compose / +deps ...)
 - Requires a way for the framework to participate in walk_chain
   alongside plugin layers. Cleanest: ship a hidden "core" plugin in
   rlock with [snapshot] strategy="cached" that produces the framework
   base, deps = [] so it sorts first.
 - Measurement first (per Snapshot analytics TODO): confirm the savings
   are worth the added complexity before implementing.

Linear chain limitation (deferred from layered-snapshots design).
 - qcow2 backing files are linear, so two sibling plugins (e.g. ruby-bundler
   and npm both depending only on mise) serialize in load order even though
   they're semantically independent. Acceptable for v1 but introduces
   unnecessary rebuild latency when only one of the sibling layers churns.
 - Possible fixes: per-sibling fork-and-merge of cached layers (complex), or
   merge-on-build into a single combined layer (loses cache-hit granularity).
 - Defer until analytics show siblings frequently rebuild in isolation.

Out-of-band Docker state persistence — `rl warm rebuild` command.
 - `docker volume create` / images pulled by the user during an `rl code`
   session don't persist to the cached warm layer automatically. Next fresh
   `rl new` starts from the cached warm and loses that work.
 - Proposed surface: explicit `rl warm rebuild` that snapshots the CURRENT
   running VM into the warm cache slot. User controls when to promote
   live tweaks into the cached snapshot.
 - From specs/2026-05-11-layered-snapshots-design.md "Known limitations".

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
