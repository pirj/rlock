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
