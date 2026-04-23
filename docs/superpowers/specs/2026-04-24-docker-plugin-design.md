# Docker Plugin for rlock

**Date:** 2026-04-24
**Status:** Draft

## Problem

Projects typically describe their environment in Dockerfiles and docker-compose.yml files. rlock runs in Alpine Linux VMs, not Docker containers. Users need their project dependencies (runtimes, libraries, databases) provisioned natively in the VM based on these existing Docker config files.

## Solution

A `docker` plugin that translates Dockerfile and docker-compose.yml into Alpine provisioning commands. Runs during the `provision` hook at `rl new` time. No separate commands — provisioning only.

## Plugin Structure

```
plugins/docker/
  plugin.toml
  plugin.sh          # provision hook: parses and executes
  pkg-map.txt        # debian → alpine package name mapping
```

### plugin.toml

```toml
description = "Docker environment translator (Dockerfile + docker-compose.yml)"
deps = []
host_deps = ["yq"]
triggers = ["Dockerfile", "docker-compose.yml", "docker-compose.yaml"]
commands = []
```

- No plugin dependencies.
- `yq` required on the host for docker-compose.yml parsing.
- Triggers on Dockerfile or docker-compose presence in repo root.
- No commands — provision hook only.

## Dockerfile Translation

Parsed in bash: `while IFS= read -r line` with `case` dispatch by directive. Handles continuation lines (`\`) and comments (`#`).

### Supported Directives

| Directive | Translation |
|---|---|
| `FROM ruby:3.2` | `mise use ruby@3.2` (parse image name as runtime, tag as version) |
| `FROM node:18-alpine` | `mise use node@18` (strip suffixes like `-alpine`, `-slim`, `-bullseye`) |
| `FROM ubuntu:22.04` | Skip — no runtime to install (base OS image) |
| `RUN apt-get install -y pkg1 pkg2` | `apk add` with package name mapping via `pkg-map.txt` |
| `RUN yum install pkg` / `RUN dnf install pkg` | `apk add` with mapping via `pkg-map.txt` |
| `RUN` (other commands) | Passthrough — execute as-is |
| `ENV FOO=bar` | Set in `~/.profile` via `export` |
| `WORKDIR /app` | `mkdir -p /app` (sets working directory for subsequent RUN commands) |
| `EXPOSE 3000` | Warn — informational only, QEMU hostfwd must be configured manually |
| `COPY` / `ADD` | Warn — skipped (source code is delivered via git plugin) |

### Unsupported Directives (warn and skip)

- `FROM ... AS ...` (multi-stage builds)
- `HEALTHCHECK`, `STOPSIGNAL`, `SHELL`, `ONBUILD`, `USER`, `ENTRYPOINT`, `CMD`

### FROM Parsing Logic

The `FROM` image name is parsed to detect a runtime for mise:

1. Extract image name and tag: `FROM image:tag` → name=`image`, version=`tag`
2. Strip known suffixes from tag: `-alpine`, `-slim`, `-bullseye`, `-bookworm`, `-jammy`
3. Map image name to mise runtime:
   - `ruby` → `mise use ruby@{version}`
   - `node` → `mise use node@{version}`
   - `python` → `mise use python@{version}`
   - `golang` / `go` → `mise use go@{version}`
   - `rust` → `mise use rust@{version}`
   - `elixir` → `mise use elixir@{version}`
4. Unknown image names (e.g., `ubuntu`, `debian`, `alpine`) → skip, no mise command
5. No tag → install latest: `mise use ruby@latest`

### RUN Package Manager Detection

When a `RUN` line contains a package install command, translate it:

1. Detect pattern: `apt-get install`, `apt install`, `yum install`, `dnf install`
2. Strip flags: `-y`, `--no-install-recommends`, `-q`, etc.
3. Extract package names
4. For each package: look up in `pkg-map.txt`. If found, use mapped name. If not, pass through as-is (warn).
5. Run `apk add` with the translated package list

Non-package-install `RUN` commands are passed through and executed as-is in the guest.

## docker-compose.yml Translation

Parsed via `yq` on the host. Iterates over `services`, maps known images to Alpine packages with init scripts.

### Service Mapping

| Compose image | Alpine packages | Init |
|---|---|---|
| `postgres` / `postgres:*` | `postgresql postgresql-client` | `initdb -D /var/lib/postgresql/data`, create user/db from `POSTGRES_USER`/`POSTGRES_DB` env vars, `rc-update add postgresql`, `rc-service postgresql start` |
| `redis` / `redis:*` | `redis` | `rc-update add redis`, `rc-service redis start` |
| `mysql` / `mariadb` | `mariadb mariadb-client` | `mysql_install_db`, create user/db from `MYSQL_USER`/`MYSQL_DATABASE`, `rc-update add mariadb`, `rc-service mariadb start` |
| `memcached` | `memcached` | `rc-update add memcached`, `rc-service memcached start` |

### Compose Fields Handled

- `image` — mapped via the service table above
- `environment` — applied as service configuration (e.g., `POSTGRES_USER` → `createuser`)
- `build` — if a Dockerfile path is specified, translate that Dockerfile too

### Compose Fields Skipped (with warning)

- `volumes` (no host mounts in VM)
- `networks` (everything runs on localhost in the VM)
- `depends_on`, `healthcheck`, `ports`

### Unknown Images

Warn: `"Service 'foo' uses image 'some/custom:latest' — no Alpine mapping. Install manually via rl ssh."`

All services run on localhost inside the guest — no inter-container networking needed.

## Package Mapping File (pkg-map.txt)

Simple `debian_name=alpine_name` format, one mapping per line:

```
build-essential=build-base
libpq-dev=libpq-dev
libssl-dev=openssl-dev
libffi-dev=libffi-dev
libxml2-dev=libxml2-dev
libxslt-dev=libxslt-dev
libyaml-dev=yaml-dev
zlib1g-dev=zlib-dev
libreadline-dev=readline-dev
imagemagick=imagemagick
```

If a package is not found in the mapping, pass the name as-is to `apk add` (names often match) and warn the user.

## Provisioning Flow

During `rl new` with docker plugin activated:

```
1. Check for Dockerfile in repo root
2. If found: parse and generate Alpine provisioning commands
   a. Process FROM → mise use
   b. Process RUN → translate package managers, passthrough others
   c. Process ENV → add to ~/.profile
   d. Process WORKDIR → mkdir -p
   e. Warn on COPY/ADD/EXPOSE/unsupported
3. Execute generated commands in guest via aq exec
4. Check for docker-compose.yml / docker-compose.yaml in repo root
5. If found and yq available: parse with yq
   a. For each service: map image → apk add + init
   b. Apply environment vars to service config
   c. Warn on unknown images
6. Execute service setup commands in guest via aq exec
```

## Error Handling

- **Unparseable Dockerfile line** → warn and skip, continue with next line
- **Unknown directive** → warn and skip
- **`apk add` fails for a package** → log, continue (don't abort entire provisioning)
- **`mise use` fails** → warn, continue
- **No Dockerfile and no compose file** → provision hook does nothing
- **Unknown compose service image** → warn, skip, list skipped services at the end
- **`yq` missing but Dockerfile present without compose** → process Dockerfile, skip compose with warning
- **`yq` missing and only compose file present** → warn: "Install yq to process docker-compose.yml"

## Re-provisioning

If the Dockerfile or docker-compose.yml changes after `rl new`, the user must `rl rm && rl new` to re-provision. Incremental updates are not supported in v1.

## Known Limitations

Written to `KNOWN-LIMITATIONS.md` in the project root during implementation.
