# Known Limitations

## Plugin Architecture

- **No dynamic plugin activation** — plugins are determined at `rl new` time. Adding a plugin to a running airlock requires `rl rm` + `rl new`.
- **No `rl plugin install`** — third-party plugins must be manually placed in `~/.config/rl/plugins/`.
- **Flat TOML only** — plugin manifests support flat key-value pairs and simple arrays. No nested tables or complex structures.
- **No plugin versioning** — no version field, no compatibility checks between plugins.
- **No binary trigger detection** — triggers only match files/directories in the project root, not binaries on the host PATH.

## Docker Plugin

- **No incremental updates** — if Dockerfile or docker-compose.yml changes, `rl rm && rl new` is required.
- **Multi-stage Dockerfiles** — not supported. `FROM ... AS ...` lines are skipped.
- **COPY/ADD** — skipped. Source code is delivered via the git plugin.
- **Version pinning** — `FROM ruby:3.2.1` installs via mise, which may resolve to the closest available patch version.
- **Exotic compose services** — only postgres, redis, mysql/mariadb, and memcached are mapped. Custom images require manual installation.
- **RUN passthrough** — non-package-install RUN commands are executed as-is; some may fail on Alpine due to musl/glibc or missing tools.

## Branch Plugin

- **No automatic VM creation on branch switch** — `git checkout` doesn't create a VM. Run `rl branch` explicitly.
- **No git hooks** — branch plugin doesn't install post-checkout/post-merge hooks. Could be added later.
- **Manual changes lost in child branches** — child branches inherit the post-provisioning snapshot, not live VM state. Manual experiments don't propagate.
- **Conservative pruning** — orphan snapshots may accumulate. Mid-chain `qemu-img rebase` flattening only happens for clearly safe cases.
- **Detached HEAD not supported** — checkout a sha → no branch → no VM.
- **Worktrees** — each git worktree has its own current branch, so `rl branch` works correctly per worktree. Worktrees that share commits resolve to the same VM (by design).
- **`rl branch rm` does not prune chains in v1** — orphan snapshots persist until a future cleanup pass is implemented.

## Guest Environment

- **musl vs glibc** — Alpine uses musl libc. Some projects with native extensions compiled for glibc may fail at runtime even when packages install successfully.
- **Alpine-only guest OS** — all plugins provision against Alpine Linux. Debian/Ubuntu-based workflows are not supported.
