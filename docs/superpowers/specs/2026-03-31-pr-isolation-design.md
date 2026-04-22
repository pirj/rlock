# PR Isolation with Dockerfile Translation & qcow2 Layering

**Date:** 2026-03-31
**Status:** Draft

## Problem

Running PRs in isolation requires full project dependency setup — language runtimes, libraries (`npm i`, `bundle install`), databases (postgres with `initdb`, user creation), and other services. This setup is typically described in Dockerfiles and docker-compose.yml. Running Docker inside the QEMU VM achieves isolation but feels like a half-measure that undermines the VM-first philosophy.

## Solution

Translate Dockerfiles and docker-compose.yml into native Alpine provisioning scripts, execute them inside the VM, and snapshot the result as a qcow2 layer. Per-branch overlays allow instant clean-slate testing without re-provisioning.

## qcow2 Layer Model

Three-layer chain using qcow2 backing files:

```
~/.local/share/aq/<vm>/base.qcow2    # aq's vanilla Alpine (shared across VMs)
  └── env.qcow2                       # Project environment snapshot
       └── live.qcow2                  # Active working overlay (per-branch)
```

- `rl new` creates the full chain: base -> env -> live
- `rl snapshot` freezes `env.qcow2` after provisioning (Dockerfile translation + services setup)
- Switching branches creates a new `live.qcow2` backed by the same `env.qcow2` — instant fork, no re-provisioning
- `rl snapshot --rebuild` re-translates the Dockerfile and replaces `env.qcow2` (when project deps change fundamentally)
- Destroying a branch overlay is cheap — delete `live.qcow2` and create a fresh one

qcow2 mechanics: `qemu-img create -f qcow2 -b env.qcow2 -F qcow2 live.qcow2` — writes go to the overlay, reads fall through to the backing file. No data duplication.

### Snapshot creation process

`rl snapshot` (and the snapshot step within `rl new`) works by:
1. Stop the VM if running
2. Create a fresh temporary qcow2 backed by `base.qcow2`
3. Boot VM from this temporary image
4. Run the translated provisioning script (Dockerfile + compose services)
5. Shut down the VM
6. Move the temporary image to `env.qcow2` (replacing any previous snapshot)
7. Create a new `live.qcow2` backed by the new `env.qcow2`
8. Boot the VM from `live.qcow2`

This ensures `env.qcow2` always represents a clean, reproducible environment — not accumulated drift from manual changes.

## Dockerfile Translation

A new `lib/translate.sh` module that parses Dockerfiles and emits an Alpine provisioning script.

### Supported directives

- **`FROM`** — ignored for OS selection (always Alpine), but used to detect language runtime needs (e.g., `FROM ruby:3.2` -> `apk add ruby`)
- **`RUN`** — command passthrough with package manager translation:
  - `apt-get install -y pkg` -> `apk add pkg` (with name mapping table)
  - `yum install pkg` -> `apk add pkg`
  - Non-package-install `RUN` commands pass through as-is
- **`ENV`** — translated to env vars in `mise.toml`
- **`WORKDIR`** — translated to `mkdir -p` + `cd`
- **`COPY` / `ADD`** — translated to file placement in the guest (via `aq exec`)
- **`EXPOSE`** — noted for QEMU port forwarding (`hostfwd` rules)

### Unsupported directives (bail with clear message)

- `FROM ... AS ...` (multi-stage builds)
- `HEALTHCHECK`, `STOPSIGNAL`, `SHELL`, `ONBUILD`
- `USER` (always provisions as `ai` user)

### Package mapping table

A lookup file (`lib/pkg-map.sh` or data file) mapping common Debian/Ubuntu package names to Alpine equivalents:

```
postgresql-client -> postgresql-client
libpq-dev -> libpq-dev
build-essential -> build-base
libssl-dev -> openssl-dev
python3-dev -> python3-dev
```

When a package has no known mapping, pass the name through as-is (Alpine's `apk` will error clearly if it doesn't exist) and warn the user.

## docker-compose.yml Service Translation

Parses `docker-compose.yml` and provisions services natively in Alpine.

### Supported service mappings

| Compose image | Alpine packages | Init commands |
|---|---|---|
| `postgres` / `postgres:*` | `postgresql postgresql-client` | `initdb -D /var/lib/postgresql/data`, create user/db from `POSTGRES_USER`/`POSTGRES_DB` env vars, `rc-update add postgresql` |
| `redis` / `redis:*` | `redis` | `rc-update add redis` |
| `mysql` / `mariadb` | `mariadb mariadb-client` | `mysql_install_db`, create user/db, `rc-update add mariadb` |
| `memcached` | `memcached` | `rc-update add memcached` |
| `elasticsearch` | Skip with warning (too complex for Alpine native) | — |

### Compose fields handled

- **`image`** — mapped via the table above
- **`environment`** — applied as service config (e.g., `POSTGRES_USER` -> `createuser`)
- **`ports`** — noted for QEMU `hostfwd` if the app needs to reach the service

### Compose fields ignored (with warning)

- `volumes` (no host mounts in VM)
- `networks` (everything runs on localhost inside the VM)
- `depends_on`, `healthcheck`, `build` (the Dockerfile path gets translated separately)

### Unknown images

Warn the user: `"Service 'foo' uses image 'some/custom:latest' -- no Alpine mapping available. You can install it manually after 'rl code'."`

All services run on localhost inside the guest — no inter-container networking needed since everything shares the same VM.

## CLI Commands

### New and modified commands

| Command | Purpose |
|---|---|
| `rl new` (enhanced) | Detects `Dockerfile` / `docker-compose.yml` in repo root, auto-translates and provisions, then snapshots `env.qcow2` |
| `rl snapshot` | Manually (re)create the environment snapshot — re-translates Dockerfile, rebuilds `env.qcow2` |
| `rl branch <name>` | Create a fresh `live.qcow2` overlay from `env.qcow2` for a specific branch, checkout that branch inside the guest |
| `rl reset` | Discard current `live.qcow2` and create a fresh one from `env.qcow2` — clean slate without re-provisioning |

### Typical PR testing workflow

```bash
$ cd my-project
$ rl new                          # First time: translates Dockerfile, provisions, snapshots
$ rl code                         # Attach, poke around, verify base env works
# ... later, a PR comes in ...
$ rl branch feat/new-widget       # Fresh overlay, fetches & checks out the PR branch
$ rl code                         # Attach, run tests, inspect
$ rl reset                        # Done — discard branch state, back to clean env
```

### How `rl new` changes

1. Everything it does today (create VM, Caddy, agents, git bridge)
2. Detect `Dockerfile` / `docker-compose.yml` in repo root
3. Translate -> provision -> snapshot `env.qcow2`
4. If no Dockerfile found, behaves exactly as today (no snapshot, flat qcow2)

## Error Handling

### Translation failures

- Unsupported Dockerfile directive -> warn and skip, continue with the rest
- Unknown package mapping -> pass through to `apk` as-is, warn user. If `apk add` fails, log the package name and continue (don't abort the whole provisioning)
- Unknown compose service image -> warn and skip, list skipped services at the end

### Snapshot management

- `rl snapshot` when VM is running -> stop VM first, snapshot, restart
- `rl snapshot` when no Dockerfile exists -> error: "No Dockerfile or docker-compose.yml found"
- `rl branch` when target branch doesn't exist in git -> error before creating overlay
- `rl reset` with unsaved work -> warn: "This discards all changes in the current overlay. Continue? [y/N]"

### qcow2 chain integrity

- If `env.qcow2` is missing but `live.qcow2` exists -> error: "Environment snapshot missing. Run `rl snapshot` to rebuild."
- `rl rm` cleans up the entire chain (all layers)

### Dockerfile location

- Check repo root for `Dockerfile`, then `docker-compose.yml`, then `docker-compose.yaml`
- No support for custom paths in v1 (could add `--dockerfile path` later)

### musl/glibc incompatibility

- Not detectable at translate time
- If a user hits runtime failures due to musl, the error is on them
- Document as a known limitation

## Known Limitations

- **musl vs glibc:** Alpine uses musl libc. Some projects with native extensions compiled for glibc may fail at runtime even when packages install successfully.
- **Multi-stage Dockerfiles:** Not supported. Only single-stage builds are translated.
- **Custom Dockerfile paths:** Only repo root is checked. `--dockerfile` flag deferred to future version.
- **Exotic compose services:** Only well-known database/cache images are mapped. Custom or niche images require manual installation.
- **Version pinning:** `FROM ruby:3.2.1` will install whatever Ruby version Alpine's repos provide, not necessarily 3.2.1 exactly.
