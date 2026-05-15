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

aq integration to skip first-boot setup on warm path.
 - Step 0 benchmark: warm rl new = 30s wall-clock. ~15s of that is aq's automatic
   first-boot setup (sfdisk + resize2fs) which runs on every fresh `aq new` even
   when we immediately rebase the disk to a cached qcow2.
 - Need an aq mode equivalent to `aq new --backed-by=<qcow2> --no-first-boot` or
   `aq new --from-snapshot=<tag>` that hands us an already-set-up disk.
 - Belongs to Phase 2 (firecracker + aq snapshot-aware backend).
 - Without this, sub-second warm boot from the original spec is unreachable.

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

Snapshot analytics.
 - Track per-plugin cache hit rate, rebuild count, avg rebuild duration, snapshot disk usage.
 - Persist in ~/.local/share/aq/cache/<plugin>/stats.json.
 - Surface via `rl cache stats` command.
 - Goal: identify plugins whose cache is rarely hit → recommend downgrade from `cached`/`incremental` to `ephemeral`.
 - Identify plugins with rebuilds so frequent that snapshotting costs more than it saves.
 - Inform per-ecosystem ordering decisions (top-of-chain = most volatile).

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
