# Layered Snapshots & Docker-in-VM

## Problem

The current `docker` plugin translates `Dockerfile`/`docker-compose.yml` into Alpine `apk` packages and Alpine OpenRC services. It works, but:

- **Drift** — `FROM ruby:3.2.1` becomes `mise use ruby@3.2`, which resolves to whatever patch version Alpine's mise repo ships. Versions silently diverge from upstream Dockerfile.
- **Coverage** — only `postgres`/`redis`/`mysql`/`memcached` are mapped. Custom or niche compose services need manual install. Multi-stage builds, `COPY`/`ADD`, exotic `RUN` invocations are silently skipped or fail on musl.
- **Maintenance** — every new service users add requires extending the translator. Each Dockerfile flavor is its own bug surface.
- **Cost of dep install** — `bundle install` / `npm ci` run inside every fresh VM. Minutes of CPU and gigabytes of network traffic per `rl new`, repeated across branches and projects.

The `branch` plugin already proves that qcow2 backing-file chains work for fast VM creation (`qemu-img create -b ancestor`). But the mechanism is hardcoded inside `branch/lib.sh` and applies only to git ancestry — no other layer participates.

## Goals

1. Replace the Dockerfile/compose translator with real Docker running inside the VM. Snapshot the VM after `docker compose up -d` and healthchecks pass. Subsequent `rl new` boots from that snapshot in under a second.
2. Generalize the snapshot mechanism so any plugin can declare a cached layer. The chain extends from `base → warm → mise → ruby-bundler → npm → … → branch`.
3. Make the layer protocol declarative — plugin manifest + two hooks (`snapshot_key`, `snapshot_build`), framework orchestrates the chain.
4. Refactor the branch plugin onto the new protocol so it's no longer a special case.

## Non-goals

The following are deliberately out of this spec and tracked in `TODO.md`:

- Caddy-based caching mirror for `rubygems.org` / `registry.npmjs.org` / PyPI.
- Snapshot analytics (hit rate, rebuild duration, cache size).
- Subset-detection for additive-only key changes (e.g., new migration files).
- Per-ecosystem layer ordering driven by observed churn.

The deprecated `docker` translator stays in the tree as `deprecated = true` (warning at provision time) for one release cycle, then is removed.

---

## Phase 1 — Layered Snapshots + Docker-in-VM

### Layer chain

A linear qcow2 backing-file chain, ordered by plugin load order (the existing `resolve_deps` topological sort over `deps` in `plugin.toml`):

```
base (Alpine + dockerd, per-project)
  └─ warm        (compose up + healthchecks)        cached, key = hash(Dockerfile + compose + .dockerignore + overrides)
       └─ mise   (tool versions installed)          cached, key = hash(mise.toml + .tool-versions + .ruby-version + .nvmrc)
            └─ ruby-bundler (bundle install)        incremental, key = hash(Gemfile.lock + .bundler-version)
                 └─ npm    (npm ci)                 incremental, key = hash(package-lock.json)
                      └─ rails-db-migrations        ephemeral
                           └─ rails-db-seeds        ephemeral
                                └─ branch           cached, key = <branch>@<base-sha>
```

- Tool managers (mise, nvm) have no deps on dep-installers and sit lower in the chain.
- Dep installers declare `deps = ["mise"]` (or similar) to position above tool managers.
- The branch plugin is the leaf.
- Plugins without a `[snapshot]` section don't participate in the chain — they keep their existing `provision`/`start`/`rm` hooks unchanged (e.g., `auth-proxy`).

### Plugin protocol additions

**`plugin.toml`**:

```toml
[snapshot]
strategy = "cached"   # one of: cached | incremental | ephemeral
```

Absence of the `[snapshot]` section means the plugin does not contribute a layer.

**`plugin.sh`** (two new hooks):

```sh
# Emit a content hash representing this plugin's layer identity
# for the current project state. The plugin chooses what goes
# into the hash (lockfiles, configs, env, anything).
snapshot_key() {
    {
        cat Gemfile.lock 2>/dev/null
        cat .ruby-version 2>/dev/null
    } | sha256sum | cut -d' ' -f1
}

# Run the provisioning that constitutes this layer's state inside
# the VM. Called on cache miss only.
snapshot_build() {
    local vm="$1"
    aq exec "$vm" <<SH
su -l rlock -c 'cd /home/rlock/repo && bundle install --jobs=4 --retry=3'
SH
}
```

### Strategies

| Strategy | Cache lookup | Miss behavior | Use cases |
|---|---|---|---|
| `cached` (default) | by current key | Boot fresh on **parent layer**, run `snapshot_build`, save as `<plugin>/<key>/snapshot.qcow2`. | `warm` (compose up), `mise`, `rails-load-db-schema`. Safe default. |
| `incremental` | by current key | Boot on **most recent snapshot of this plugin** (any key), run `snapshot_build`, save under current key. | `ruby-bundler`, `npm` — additive ops where leftover state is acceptable. |
| `ephemeral` | never cached | Run `snapshot_build` on parent every `rl new`. Layer state stays in the active VM but never saved to global cache. | `rails-db-migrations`, `rails-db-seeds` — frequently mutated, full rebuilds cheap from clean DB. |

### Cache layout

```
~/.local/share/aq/cache/
  <plugin-name>/
    <key>/
      snapshot.qcow2
      meta.json        # { built_at, build_duration_s, parent_plugin, parent_key, key_inputs }
```

`meta.json` is debugging/telemetry only — the framework does not depend on it being present.

### Framework orchestration

Pseudocode for `rl new`:

```
plugins = resolve_deps(active_plugins)
parent_qcow = AQ_BASE_IMAGE
vm = create_vm_attached_to(parent_qcow)

for plugin in plugins:
    if not plugin has [snapshot]:
        provision(plugin, vm)   # legacy path
        continue

    strategy = plugin.snapshot.strategy
    key = run_hook(plugin, "snapshot_key")
    cache_path = "$HOME/.local/share/aq/cache/$plugin/$key/snapshot.qcow2"

    if exists(cache_path):
        rebase_vm(vm, backing=cache_path)
        parent_qcow = cache_path
        continue

    if strategy == "incremental":
        latest = find_latest_snapshot(plugin)    # any key
        if latest: rebase_vm(vm, backing=latest)

    boot(vm)
    wait_for_ssh(vm)
    run_hook(plugin, "snapshot_build", vm)
    stop(vm)

    if strategy != "ephemeral":
        save_snapshot(vm, cache_path)
        write_meta(cache_path, ...)
        parent_qcow = cache_path
    # ephemeral: parent_qcow unchanged, VM's current qcow2 is the live state for next layer

final_boot(vm)
run_start_hooks(plugins, vm)
```

`save_snapshot` is `qemu-img convert -O qcow2` of the current VM disk after a clean `aq stop` (mirrors today's branch plugin).

### Library extraction

Snapshot orchestration lives in **`lib/snapshot.sh`**:

- `snapshot_cache_path <plugin> <key>` — resolve cache path
- `snapshot_lookup <plugin> <key>` — return cache path if exists, empty otherwise
- `snapshot_latest <plugin>` — return path of most recent snapshot for plugin (any key)
- `snapshot_save <vm> <plugin> <key>` — `aq stop` + `qemu-img convert` + write `meta.json`
- `snapshot_rebase <vm> <backing>` — create new top qcow2 with the given backing file
- `snapshot_walk_chain <plugins...>` — the orchestrator pseudocode above

`bin/rl` calls `snapshot_walk_chain` from `cmd_new`. Plugins do not touch qcow2 directly.

### New & refactored plugins

**New** (this spec ships them):

- **`docker-engine`** — `strategy = "cached"`. Key = pinned Alpine `docker` package version. `snapshot_build`: `apk add docker docker-cli-compose`, `rc-update add docker`, `service docker start`, wait for `/var/run/docker.sock`.
- **`docker-compose`** — `strategy = "cached"`, `deps = ["docker-engine"]`. Key = hash of `Dockerfile`, `docker-compose.yml`/`.yaml`, `compose.override.*`, `.dockerignore`. `snapshot_build`: `docker compose build && docker compose up -d`, then poll `docker compose ps --format json` until every service is `running` and (if `healthcheck` declared) `Health == healthy`. Timeout: 5 minutes.

**Refactored**:

- **`branch`** — gains `[snapshot]` with `strategy = "cached"`. `snapshot_key` returns `<sanitized-branch>@<base-sha>`. `snapshot_build` performs the existing `git push rl <branch>` flow. The hardcoded qcow2 logic in `branch/commands/branch.sh` and `branch/lib.sh` is deleted in favor of the shared library.

**Stubs / out of scope** for this spec but referenced in the layer chain (separate plugins, separate specs):

- `mise`, `nvm` — tool version installers
- `ruby-bundler`, `npm`, `uv`, `pnpm`, `poetry` — dep installers
- `rails-db-migrations`, `rails-db-seeds`, `rails-load-db-schema` — Rails lifecycle

### VM sizing

Docker-in-VM needs more headroom than the translator approach:

- Disk: **16 GB** (was 4 GB) — accommodates pulled images + compose stacks + DB volumes. qcow2 stays sparse so on-disk footprint grows only as used.
- RAM: **4 GB** (was default ~1 GB) — dockerd + multiple service containers. May still be tight for heavy compose stacks; revisit after first benchmark.

Bumped in the `rl new` invocation of `aq new` and in the post-create `qemu-img resize`.

### Background prune

After `rl new` completes provisioning, fork a background process to prune stale cache entries:

- A cache entry is **stale** if no active VM (in `$AQ_STATE_DIR/*/storage.qcow2`) references it in its backing chain, AND its `meta.json` `built_at` is older than 30 days.
- Walk `~/.local/share/aq/cache/*/*/snapshot.qcow2`. For each, use `qemu-img info --backing-chain` to discover referenced ancestors, build a "live set", then delete entries outside the live set + older than the threshold.
- Log to `$AQ_STATE_DIR/cache-prune.log`. On next `rl new`, if a recent prune log exists, print one line summarizing it ("Pruned 3 stale snapshots (240 MB)").

### Healthcheck-based warm trigger

The `docker-compose` plugin polls compose service health to decide when to snapshot:

```sh
for i in $(seq 1 60); do
    state=$(docker compose ps --format json | jq -r '
        [.[] | select(.State != "running" or (.Health != null and .Health != "healthy"))]
        | length
    ')
    [ "$state" = "0" ] && break
    sleep 5
done
```

Services without a declared `healthcheck` are considered ready when `State == running`. Timeout: 5 minutes — failure aborts the build with the offending service's last 50 log lines.

### Migration & rollout

1. Land the snapshot library + protocol additions + branch refactor in one PR. Verify the branch plugin still works (existing tests pass).
2. Ship `docker-engine` + `docker-compose` plugins. Deprecation warning continues firing in the old `docker` plugin.
3. **Benchmark milestone** (see Phase 2): on a real Rails+Postgres project, measure cold `rl new` (no cache) and warm `rl new` (cache hit) for both old translator and new docker-in-VM. Record results in `docs/superpowers/benchmarks/` (dated on the day measurements are taken). Decision point: if warm `rl new` is not at least 5× faster than cold translator, revisit the design before Phase 2.
4. Remove the deprecated `docker` plugin in the release after Phase 1 stabilizes.

---

## Phase 2 — Firecracker backend in aq

This phase lives in the [`pirj/aq`](https://github.com/pirj/aq) repository, not in `rlock`. It is included here for visibility and to define the touchpoints from `rlock`'s side.

### Scope (in aq)

- Detect host capability: Linux + `/dev/kvm` + `firecracker` binary on PATH. Otherwise fall back to QEMU.
- New backend module: VM lifecycle (`new`, `start`, `stop`, `rm`, `snapshot create/rm`, `exec`) implemented against Firecracker API socket.
- Reuse existing Alpine root image (qcow2 → raw conversion or direct ext4 export).
- Networking: tap device on Linux, expose same `10.0.2.2`-style gateway abstraction to guests.
- Snapshot/restore via Firecracker's diff snapshot API. Faster restore than QEMU save/load.

### Touchpoints from rlock

- None expected if `aq` keeps its CLI surface stable. The snapshot library (`lib/snapshot.sh`) uses `aq snapshot create` and `qemu-img` operations on qcow2 disks today. If Firecracker uses a different disk format (raw ext4), `lib/snapshot.sh` becomes backend-aware via a thin `snapshot_*` shim that delegates to either `qemu-img` or `firecracker`-native ops.
- Configuration: `aq` decides the backend automatically; `rlock` may surface `--backend qemu|firecracker` on `rl new` for forcing it.

### Benchmark gate

Phase 2 is justified only if measurements after Phase 1 show that **boot from snapshot** is a bottleneck. Target: `rl new` against a warm cache hit in under 1 second wall-clock. If QEMU + `aq snapshot` already meets this, Phase 2 deprioritizes.

---

## Known limitations

- **`docker-in-VM` requires nested-virt-friendly host acceleration** — KVM on Linux, HVF on macOS. Older hosts without these may see degraded performance.
- **Shared seed state for live services** — the `warm` snapshot captures live container memory and volume state. All VMs from the same `warm` start with identical DB content. User-installed seeds during a session do not propagate back to the cached `warm`.
- **`incremental` strategy accumulates orphans** — `bundle install` doesn't remove gems removed from `Gemfile.lock`. Over many incremental builds, `vendor/bundle` size grows. Periodic `cached`-style rebuild (manual `rl cache rebuild ruby-bundler`) clears this.
- **Cache disk usage** — until prune runs (or runs sufficiently), cache can grow large. `meta.json` records sizes for future analytics-driven warnings.
- **Linear chain** — qcow2 backing files are linear. Two sibling plugins (e.g., `ruby-bundler` and `npm` both depending only on `mise`) still serialize in load order. Acceptable tradeoff for v1.
- **Out-of-band Docker state** — `docker volume create` / images pulled by the user during an `rl code` session don't persist to the cached `warm` automatically. Use `rl warm rebuild` (future command) or accept the loss.

## Future TODOs

Tracked in `TODO.md`:

- Caddy-based language registry caching mirror.
- Snapshot analytics (`rl cache stats`).
- Subset-detection for additive-only key changes.
- Per-ecosystem layer ordering driven by observed churn.
