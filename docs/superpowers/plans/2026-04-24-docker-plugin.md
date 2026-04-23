# Docker Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `docker` plugin that translates Dockerfile and docker-compose.yml into Alpine provisioning commands, installing runtimes via mise and packages via apk.

**Architecture:** The plugin runs during the `provision` hook. On the host, it parses Dockerfile and docker-compose.yml, generating a shell script of Alpine-native commands. Then it executes that script in the guest via `aq exec`. Dockerfile parsing is pure bash; compose parsing uses `yq`.

**Tech Stack:** Bash 5.x, BATS (testing), yq (YAML parsing), mise (runtime management), ShellCheck

**Spec:** `docs/superpowers/specs/2026-04-24-docker-plugin-design.md`

---

## File Structure

**New:**
- `plugins/docker/plugin.toml` — plugin manifest
- `plugins/docker/plugin.sh` — provision hook (orchestrator)
- `plugins/docker/parse-dockerfile.sh` — Dockerfile parser (pure functions, testable)
- `plugins/docker/parse-compose.sh` — docker-compose.yml parser (uses yq)
- `plugins/docker/pkg-map.txt` — Debian → Alpine package mapping
- `test/docker_dockerfile.bats` — Dockerfile parser tests
- `test/docker_compose.bats` — compose parser tests

**Modified:**
- `KNOWN-LIMITATIONS.md` — add docker plugin limitations

---

### Task 1: Package Mapping Lookup

**Files:**
- Create: `plugins/docker/pkg-map.txt`
- Create: `plugins/docker/parse-dockerfile.sh` (just `pkg_map_lookup` for now)
- Create: `test/docker_dockerfile.bats`

- [ ] **Step 1: Create pkg-map.txt**

Create `plugins/docker/pkg-map.txt`:

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
libsqlite3-dev=sqlite-dev
libmysqlclient-dev=mariadb-dev
default-libmysqlclient-dev=mariadb-dev
libcurl4-openssl-dev=curl-dev
python3-dev=python3-dev
```

- [ ] **Step 2: Write failing tests for package mapping**

Create `test/docker_dockerfile.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker"
    source "$PLUGIN_DIR/parse-dockerfile.sh"
}

@test "pkg_map_lookup translates known package" {
    run pkg_map_lookup "build-essential"
    assert_success
    assert_output "build-base"
}

@test "pkg_map_lookup passes through unknown package" {
    run pkg_map_lookup "curl"
    assert_success
    assert_output "curl"
}

@test "pkg_map_lookup handles libssl-dev" {
    run pkg_map_lookup "libssl-dev"
    assert_success
    assert_output "openssl-dev"
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bats test/docker_dockerfile.bats`
Expected: FAIL — `parse-dockerfile.sh` does not exist.

- [ ] **Step 4: Implement pkg_map_lookup**

Create `plugins/docker/parse-dockerfile.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

DOCKER_PLUGIN_DIR="${DOCKER_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PKG_MAP_FILE="$DOCKER_PLUGIN_DIR/pkg-map.txt"

# Look up a Debian package name in the mapping file.
# Returns the Alpine equivalent, or the original name if not found.
pkg_map_lookup() {
    local pkg="$1"
    local mapped
    mapped=$(sed -n "s/^${pkg}=//p" "$PKG_MAP_FILE" 2>/dev/null) || true
    if [[ -n "$mapped" ]]; then
        echo "$mapped"
    else
        echo "$pkg"
    fi
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/docker_dockerfile.bats`
Expected: All 3 tests PASS.

- [ ] **Step 6: Run ShellCheck**

Run: `shellcheck plugins/docker/parse-dockerfile.sh`

- [ ] **Step 7: Commit**

```bash
git add plugins/docker/pkg-map.txt plugins/docker/parse-dockerfile.sh test/docker_dockerfile.bats
git commit -m "feat(docker): add package mapping lookup"
```

---

### Task 2: FROM Parsing

**Files:**
- Modify: `plugins/docker/parse-dockerfile.sh`
- Modify: `test/docker_dockerfile.bats`

- [ ] **Step 1: Write failing tests for FROM parsing**

Append to `test/docker_dockerfile.bats`:

```bash
@test "parse_from extracts ruby runtime" {
    run parse_from "FROM ruby:3.2"
    assert_success
    assert_output "mise use ruby@3.2"
}

@test "parse_from strips -alpine suffix" {
    run parse_from "FROM node:18-alpine"
    assert_success
    assert_output "mise use node@18"
}

@test "parse_from strips -slim suffix" {
    run parse_from "FROM python:3.11-slim"
    assert_success
    assert_output "mise use python@3.11"
}

@test "parse_from strips -bullseye suffix" {
    run parse_from "FROM ruby:3.2.1-bullseye"
    assert_success
    assert_output "mise use ruby@3.2.1"
}

@test "parse_from uses latest when no tag" {
    run parse_from "FROM ruby"
    assert_success
    assert_output "mise use ruby@latest"
}

@test "parse_from skips ubuntu base image" {
    run parse_from "FROM ubuntu:22.04"
    assert_success
    assert_output ""
}

@test "parse_from skips debian base image" {
    run parse_from "FROM debian:bookworm"
    assert_success
    assert_output ""
}

@test "parse_from skips alpine base image" {
    run parse_from "FROM alpine:3.21"
    assert_success
    assert_output ""
}

@test "parse_from handles golang image" {
    run parse_from "FROM golang:1.22"
    assert_success
    assert_output "mise use go@1.22"
}

@test "parse_from skips multi-stage FROM AS" {
    run parse_from "FROM ruby:3.2 AS builder"
    assert_success
    assert_output ""
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/docker_dockerfile.bats`
Expected: New tests FAIL.

- [ ] **Step 3: Implement parse_from**

Append to `plugins/docker/parse-dockerfile.sh`:

```bash
# Known OS base images (no runtime to install).
_OS_IMAGES="ubuntu debian alpine centos fedora amazonlinux busybox scratch"

# Map Docker image names to mise runtime names.
# Returns empty string for unknown/OS images.
_image_to_mise_runtime() {
    local image="$1"
    case "$image" in
        ruby)    echo "ruby" ;;
        node)    echo "node" ;;
        python)  echo "python" ;;
        golang)  echo "go" ;;
        go)      echo "go" ;;
        rust)    echo "rust" ;;
        elixir)  echo "elixir" ;;
        *)       echo "" ;;
    esac
}

# Strip known OS/variant suffixes from a Docker tag.
_strip_tag_suffix() {
    local tag="$1"
    echo "$tag" | sed -E 's/-(alpine|slim|bullseye|bookworm|buster|jammy|noble|focal)$//'
}

# Parse a FROM line and emit a mise use command, or nothing.
# Usage: parse_from "FROM image:tag [AS name]"
parse_from() {
    local line="$1"

    # Skip multi-stage: FROM ... AS ...
    if [[ "$line" =~ [Aa][Ss][[:space:]] ]]; then
        return 0
    fi

    # Extract image:tag
    local image_tag
    image_tag=$(echo "$line" | awk '{print $2}')

    local image tag
    if [[ "$image_tag" == *:* ]]; then
        image="${image_tag%%:*}"
        tag="${image_tag#*:}"
    else
        image="$image_tag"
        tag=""
    fi

    # Strip org prefix (e.g., library/ruby → ruby)
    image="${image##*/}"

    # Skip OS base images
    local os
    for os in $_OS_IMAGES; do
        if [[ "$image" == "$os" ]]; then
            return 0
        fi
    done

    # Map to mise runtime
    local runtime
    runtime=$(_image_to_mise_runtime "$image")
    if [[ -z "$runtime" ]]; then
        return 0
    fi

    # Clean up version tag
    local version
    if [[ -n "$tag" ]]; then
        version=$(_strip_tag_suffix "$tag")
    else
        version="latest"
    fi

    echo "mise use ${runtime}@${version}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/docker_dockerfile.bats`
Expected: All 13 tests PASS.

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck plugins/docker/parse-dockerfile.sh`

- [ ] **Step 6: Commit**

```bash
git add plugins/docker/parse-dockerfile.sh test/docker_dockerfile.bats
git commit -m "feat(docker): parse FROM for mise runtime detection"
```

---

### Task 3: RUN Translation

**Files:**
- Modify: `plugins/docker/parse-dockerfile.sh`
- Modify: `test/docker_dockerfile.bats`

- [ ] **Step 1: Write failing tests for RUN translation**

Append to `test/docker_dockerfile.bats`:

```bash
@test "parse_run translates apt-get install" {
    run parse_run "RUN apt-get install -y build-essential libpq-dev curl"
    assert_success
    assert_output "apk add build-base libpq-dev curl"
}

@test "parse_run translates apt install" {
    run parse_run "RUN apt install -y git"
    assert_success
    assert_output "apk add git"
}

@test "parse_run translates yum install" {
    run parse_run "RUN yum install -y libssl-dev"
    assert_success
    assert_output "apk add openssl-dev"
}

@test "parse_run translates dnf install" {
    run parse_run "RUN dnf install -y zlib1g-dev"
    assert_success
    assert_output "apk add zlib-dev"
}

@test "parse_run strips --no-install-recommends" {
    run parse_run "RUN apt-get install -y --no-install-recommends curl wget"
    assert_success
    assert_output "apk add curl wget"
}

@test "parse_run passes through non-install commands" {
    run parse_run "RUN echo hello world"
    assert_success
    assert_output "echo hello world"
}

@test "parse_run passes through pip install" {
    run parse_run "RUN pip install flask gunicorn"
    assert_success
    assert_output "pip install flask gunicorn"
}

@test "parse_run strips apt-get update prefix" {
    run parse_run "RUN apt-get update && apt-get install -y curl"
    assert_success
    assert_output "apk add curl"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/docker_dockerfile.bats`

- [ ] **Step 3: Implement parse_run**

Append to `plugins/docker/parse-dockerfile.sh`:

```bash
# Parse a RUN line. If it's a package install, translate to apk add.
# Otherwise, pass through the command as-is.
# Usage: parse_run "RUN command..."
parse_run() {
    local line="$1"

    # Strip "RUN " prefix
    local cmd="${line#RUN }"

    # Strip "apt-get update && " prefix if present
    cmd=$(echo "$cmd" | sed 's/apt-get update *&& *//g; s/apt update *&& *//g')

    # Detect package install patterns
    local pkg_install_pattern='(apt-get|apt|yum|dnf) install'
    if [[ "$cmd" =~ $pkg_install_pattern ]]; then
        # Extract everything after "install"
        local args="${cmd#*install}"

        # Strip flags (-y, -q, --no-install-recommends, etc.)
        local packages=""
        local word
        for word in $args; do
            case "$word" in
                -*) continue ;;   # skip flags
                *)  # Map package name
                    local mapped
                    mapped=$(pkg_map_lookup "$word")
                    packages="$packages $mapped"
                    ;;
            esac
        done

        # Trim leading space
        packages="${packages# }"
        if [[ -n "$packages" ]]; then
            echo "apk add $packages"
        fi
    else
        # Passthrough
        echo "$cmd"
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/docker_dockerfile.bats`
Expected: All 21 tests PASS.

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck plugins/docker/parse-dockerfile.sh`

- [ ] **Step 6: Commit**

```bash
git add plugins/docker/parse-dockerfile.sh test/docker_dockerfile.bats
git commit -m "feat(docker): translate RUN package installs to apk add"
```

---

### Task 4: ENV, WORKDIR, and Full Dockerfile Parser

**Files:**
- Modify: `plugins/docker/parse-dockerfile.sh`
- Modify: `test/docker_dockerfile.bats`

- [ ] **Step 1: Write failing tests**

Append to `test/docker_dockerfile.bats`:

```bash
@test "parse_env outputs export" {
    run parse_env "ENV RAILS_ENV=production"
    assert_success
    assert_output 'export RAILS_ENV="production"'
}

@test "parse_env handles space-separated format" {
    run parse_env "ENV RAILS_ENV production"
    assert_success
    assert_output 'export RAILS_ENV="production"'
}

@test "parse_workdir outputs mkdir" {
    run parse_workdir "WORKDIR /app"
    assert_success
    assert_output "mkdir -p /app"
}

@test "translate_dockerfile handles full Dockerfile" {
    local dockerfile="$BATS_TEST_TMPDIR/Dockerfile"
    cat > "$dockerfile" <<'EOF'
FROM ruby:3.2
RUN apt-get update && apt-get install -y build-essential libpq-dev
ENV RAILS_ENV=production
WORKDIR /app
COPY . .
EXPOSE 3000
RUN bundle install
EOF
    run translate_dockerfile "$dockerfile"
    assert_success
    assert_line --index 0 "mise use ruby@3.2"
    assert_line --index 1 "apk add build-base libpq-dev"
    assert_line --index 2 'export RAILS_ENV="production"'
    assert_line --index 3 "mkdir -p /app"
    assert_line --index 4 "bundle install"
}

@test "translate_dockerfile handles continuation lines" {
    local dockerfile="$BATS_TEST_TMPDIR/Dockerfile"
    cat > "$dockerfile" <<'EOF'
FROM node:18
RUN apt-get install -y \
    curl \
    wget
EOF
    run translate_dockerfile "$dockerfile"
    assert_success
    assert_line --index 0 "mise use node@18"
    assert_line --index 1 "apk add curl wget"
}

@test "translate_dockerfile skips comments" {
    local dockerfile="$BATS_TEST_TMPDIR/Dockerfile"
    cat > "$dockerfile" <<'EOF'
# This is a comment
FROM ruby:3.2
# Another comment
RUN echo hello
EOF
    run translate_dockerfile "$dockerfile"
    assert_success
    assert_line --index 0 "mise use ruby@3.2"
    assert_line --index 1 "echo hello"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/docker_dockerfile.bats`

- [ ] **Step 3: Implement parse_env, parse_workdir, translate_dockerfile**

Append to `plugins/docker/parse-dockerfile.sh`:

```bash
# Parse an ENV line into an export statement.
# Handles both "ENV KEY=value" and "ENV KEY value" formats.
parse_env() {
    local line="$1"
    local rest="${line#ENV }"

    local key value
    if [[ "$rest" == *=* ]]; then
        key="${rest%%=*}"
        value="${rest#*=}"
    else
        key="${rest%% *}"
        value="${rest#* }"
    fi

    echo "export ${key}=\"${value}\""
}

# Parse a WORKDIR line into a mkdir command.
parse_workdir() {
    local line="$1"
    local dir="${line#WORKDIR }"
    echo "mkdir -p $dir"
}

# Translate a full Dockerfile into a sequence of Alpine provisioning commands.
# Usage: translate_dockerfile /path/to/Dockerfile
# Outputs one command per line to stdout. Warnings go to stderr.
translate_dockerfile() {
    local dockerfile="$1"
    local continued=""

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        # Strip leading/trailing whitespace
        local line
        line=$(echo "$raw_line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        # Handle continuation lines
        if [[ "$line" == *\\ ]]; then
            continued="$continued ${line%\\}"
            continue
        fi
        if [[ -n "$continued" ]]; then
            line="$continued $line"
            continued=""
        fi

        # Strip leading whitespace again after joining
        line=$(echo "$line" | sed 's/^[[:space:]]*//')

        # Parse directive
        local directive
        directive=$(echo "$line" | awk '{print toupper($1)}')

        case "$directive" in
            FROM)
                local result
                result=$(parse_from "$line")
                [[ -n "$result" ]] && echo "$result"
                ;;
            RUN)
                local result
                result=$(parse_run "$line")
                [[ -n "$result" ]] && echo "$result"
                ;;
            ENV)
                parse_env "$line"
                ;;
            WORKDIR)
                parse_workdir "$line"
                ;;
            COPY|ADD)
                echo "Warning: $directive skipped (source code delivered via git)" >&2
                ;;
            EXPOSE)
                local port="${line#EXPOSE }"
                echo "Warning: EXPOSE $port noted — configure QEMU hostfwd manually if needed" >&2
                ;;
            HEALTHCHECK|STOPSIGNAL|SHELL|ONBUILD|USER|ENTRYPOINT|CMD)
                echo "Warning: $directive not supported, skipped" >&2
                ;;
        esac
    done < "$dockerfile"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/docker_dockerfile.bats`
Expected: All 28 tests PASS.

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck plugins/docker/parse-dockerfile.sh`

- [ ] **Step 6: Commit**

```bash
git add plugins/docker/parse-dockerfile.sh test/docker_dockerfile.bats
git commit -m "feat(docker): full Dockerfile translator with ENV, WORKDIR, continuation lines"
```

---

### Task 5: docker-compose.yml Parser

**Files:**
- Create: `plugins/docker/parse-compose.sh`
- Create: `test/docker_compose.bats`

- [ ] **Step 1: Write failing tests**

Create `test/docker_compose.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker"
    source "$PLUGIN_DIR/parse-compose.sh"
}

@test "translate_compose_service generates postgres setup" {
    run translate_compose_service "postgres" "postgres:15" "POSTGRES_USER=myuser POSTGRES_DB=mydb POSTGRES_PASSWORD=secret"
    assert_success
    assert_line "apk add postgresql postgresql-client"
    assert_line --partial "initdb"
    assert_line --partial "createuser"
    assert_line --partial "createdb"
    assert_line --partial "rc-update add postgresql"
}

@test "translate_compose_service generates redis setup" {
    run translate_compose_service "cache" "redis:7" ""
    assert_success
    assert_line "apk add redis"
    assert_line "rc-update add redis"
    assert_line "rc-service redis start"
}

@test "translate_compose_service generates mariadb setup" {
    run translate_compose_service "db" "mariadb:10" "MYSQL_USER=app MYSQL_DATABASE=appdb MYSQL_ROOT_PASSWORD=secret"
    assert_success
    assert_line "apk add mariadb mariadb-client"
    assert_line --partial "mysql_install_db"
    assert_line --partial "rc-update add mariadb"
}

@test "translate_compose_service generates memcached setup" {
    run translate_compose_service "mem" "memcached:latest" ""
    assert_success
    assert_line "apk add memcached"
    assert_line "rc-update add memcached"
}

@test "translate_compose_service warns on unknown image" {
    run translate_compose_service "search" "elasticsearch:8" ""
    assert_success
    assert_output --partial "no Alpine mapping"
}

@test "translate_compose skips yq missing gracefully" {
    # Override yq to simulate missing
    yq() { return 127; }
    export -f yq
    local composefile="$BATS_TEST_TMPDIR/docker-compose.yml"
    echo "services:" > "$composefile"
    run translate_compose "$composefile"
    assert_success
    assert_output --partial "yq required"
}

@test "translate_compose parses full compose file" {
    local composefile="$BATS_TEST_TMPDIR/docker-compose.yml"
    cat > "$composefile" <<'EOF'
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_USER: myuser
      POSTGRES_DB: mydb
      POSTGRES_PASSWORD: secret
  cache:
    image: redis:7
EOF
    # Only run if yq is available
    if ! command -v yq > /dev/null 2>&1; then
        skip "yq not installed"
    fi
    run translate_compose "$composefile"
    assert_success
    assert_line --partial "apk add postgresql"
    assert_line --partial "apk add redis"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/docker_compose.bats`

- [ ] **Step 3: Implement compose parser**

Create `plugins/docker/parse-compose.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Translate a known compose service image to Alpine provisioning commands.
# Usage: translate_compose_service service_name image env_string
# env_string is space-separated KEY=VALUE pairs.
# Outputs provisioning commands to stdout, one per line.
translate_compose_service() {
    local name="$1"
    local image="$2"
    local env_str="$3"

    # Strip tag from image name
    local base_image="${image%%:*}"
    # Strip org prefix
    base_image="${base_image##*/}"

    case "$base_image" in
        postgres|postgresql)
            echo "apk add postgresql postgresql-client"
            echo "rc-update add postgresql"
            # Extract env vars
            local pg_user="" pg_db="" pg_pass=""
            local kv
            for kv in $env_str; do
                case "$kv" in
                    POSTGRES_USER=*)     pg_user="${kv#*=}" ;;
                    POSTGRES_DB=*)       pg_db="${kv#*=}" ;;
                    POSTGRES_PASSWORD=*) pg_pass="${kv#*=}" ;;
                esac
            done
            cat <<PGSCRIPT
su -l postgres -c "initdb -D /var/lib/postgresql/data"
rc-service postgresql start
PGSCRIPT
            if [[ -n "$pg_user" ]]; then
                echo "su -l postgres -c \"createuser ${pg_user}\""
            fi
            if [[ -n "$pg_db" ]]; then
                local owner_flag=""
                [[ -n "$pg_user" ]] && owner_flag=" -O ${pg_user}"
                echo "su -l postgres -c \"createdb${owner_flag} ${pg_db}\""
            fi
            if [[ -n "$pg_user" && -n "$pg_pass" ]]; then
                echo "su -l postgres -c \"psql -c \\\"ALTER USER ${pg_user} PASSWORD '${pg_pass}';\\\"\""
            fi
            ;;
        redis)
            echo "apk add redis"
            echo "rc-update add redis"
            echo "rc-service redis start"
            ;;
        mysql|mariadb)
            echo "apk add mariadb mariadb-client"
            echo "rc-update add mariadb"
            cat <<'MYINIT'
/etc/init.d/mariadb setup
rc-service mariadb start
MYINIT
            local my_user="" my_db="" my_pass=""
            for kv in $env_str; do
                case "$kv" in
                    MYSQL_USER=*)          my_user="${kv#*=}" ;;
                    MYSQL_DATABASE=*)      my_db="${kv#*=}" ;;
                    MYSQL_ROOT_PASSWORD=*) my_pass="${kv#*=}" ;;
                esac
            done
            if [[ -n "$my_db" ]]; then
                echo "mysql -u root -e \"CREATE DATABASE IF NOT EXISTS ${my_db};\""
            fi
            if [[ -n "$my_user" ]]; then
                local grant_db="${my_db:-*}"
                echo "mysql -u root -e \"CREATE USER IF NOT EXISTS '${my_user}'@'localhost'; GRANT ALL ON ${grant_db}.* TO '${my_user}'@'localhost';\""
            fi
            ;;
        memcached)
            echo "apk add memcached"
            echo "rc-update add memcached"
            echo "rc-service memcached start"
            ;;
        *)
            echo "Warning: Service '$name' uses image '$image' — no Alpine mapping. Install manually via rl ssh." >&2
            ;;
    esac
}

# Translate a docker-compose.yml file to provisioning commands.
# Usage: translate_compose /path/to/docker-compose.yml
# Requires yq on the host.
translate_compose() {
    local composefile="$1"

    if ! command -v yq > /dev/null 2>&1; then
        echo "Warning: yq required to process docker-compose.yml. Install: brew install yq" >&2
        return 0
    fi

    # Get list of service names
    local services
    services=$(yq '.services | keys | .[]' "$composefile" 2>/dev/null) || return 0

    local service
    for service in $services; do
        local image
        image=$(yq ".services.${service}.image // \"\"" "$composefile")
        if [[ -z "$image" ]]; then
            # Check for build directive
            local build_path
            build_path=$(yq ".services.${service}.build // \"\"" "$composefile")
            if [[ -n "$build_path" ]]; then
                echo "Warning: Service '$service' uses build — translate its Dockerfile separately" >&2
            fi
            continue
        fi

        # Collect environment variables
        local env_str=""
        local env_format
        env_format=$(yq ".services.${service}.environment | type" "$composefile" 2>/dev/null) || true

        if [[ "$env_format" == "!!map" ]]; then
            # Map format: KEY: value
            local env_keys
            env_keys=$(yq ".services.${service}.environment | keys | .[]" "$composefile" 2>/dev/null) || true
            local k
            for k in $env_keys; do
                local v
                v=$(yq ".services.${service}.environment.${k}" "$composefile")
                env_str="$env_str ${k}=${v}"
            done
        elif [[ "$env_format" == "!!seq" ]]; then
            # Array format: - KEY=value
            local entries
            entries=$(yq ".services.${service}.environment[]" "$composefile" 2>/dev/null) || true
            env_str="$entries"
        fi

        translate_compose_service "$service" "$image" "${env_str# }"
    done
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/docker_compose.bats`
Expected: All 7 tests PASS (or 6 if yq not installed — last test skips).

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck plugins/docker/parse-compose.sh`

- [ ] **Step 6: Commit**

```bash
git add plugins/docker/parse-compose.sh test/docker_compose.bats
git commit -m "feat(docker): docker-compose.yml translator with service mapping"
```

---

### Task 6: Plugin Shell and Integration

**Files:**
- Create: `plugins/docker/plugin.toml`
- Create: `plugins/docker/plugin.sh`
- Modify: `KNOWN-LIMITATIONS.md`

- [ ] **Step 1: Create plugin.toml**

Create `plugins/docker/plugin.toml`:

```toml
description = "Docker environment translator (Dockerfile + docker-compose.yml)"
deps = []
host_deps = ["yq"]
triggers = ["Dockerfile", "docker-compose.yml", "docker-compose.yaml"]
commands = []
```

- [ ] **Step 2: Create plugin.sh**

Create `plugins/docker/plugin.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

DOCKER_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DOCKER_PLUGIN_DIR
source "$DOCKER_PLUGIN_DIR/parse-dockerfile.sh"
source "$DOCKER_PLUGIN_DIR/parse-compose.sh"

provision() {
    local vm="$1"

    # Find project root (where Dockerfile/compose live)
    # The repo was pushed via git plugin, so files are at ~/repo in guest.
    # But we parse on the host, where we have the files.
    local project_dir
    project_dir=$(pwd)

    local script=""

    # Step 1: Translate Dockerfile
    local dockerfile="$project_dir/Dockerfile"
    if [[ -f "$dockerfile" ]]; then
        info "Translating Dockerfile..."
        local dockerfile_commands
        dockerfile_commands=$(translate_dockerfile "$dockerfile" 2>&1 1>/dev/null)
        # Capture stdout (commands) and stderr (warnings) separately
        local commands warnings
        commands=$(translate_dockerfile "$dockerfile" 2>/dev/null) || true
        warnings=$(translate_dockerfile "$dockerfile" 2>&1 1>/dev/null) || true

        if [[ -n "$warnings" ]]; then
            echo "$warnings" | while IFS= read -r w; do
                [[ -n "$w" ]] && warn "$w"
            done
        fi

        if [[ -n "$commands" ]]; then
            script="$commands"
        fi
    fi

    # Step 2: Translate docker-compose.yml
    local composefile=""
    for candidate in "$project_dir/docker-compose.yml" "$project_dir/docker-compose.yaml"; do
        if [[ -f "$candidate" ]]; then
            composefile="$candidate"
            break
        fi
    done

    if [[ -n "$composefile" ]]; then
        info "Translating $(basename "$composefile")..."
        local compose_commands compose_warnings
        compose_commands=$(translate_compose "$composefile" 2>/dev/null) || true
        compose_warnings=$(translate_compose "$composefile" 2>&1 1>/dev/null) || true

        if [[ -n "$compose_warnings" ]]; then
            echo "$compose_warnings" | while IFS= read -r w; do
                [[ -n "$w" ]] && warn "$w"
            done
        fi

        if [[ -n "$compose_commands" ]]; then
            script="${script:+$script
}$compose_commands"
        fi
    fi

    # Step 3: Execute in guest
    if [[ -z "$script" ]]; then
        info "No Docker provisioning needed"
        return 0
    fi

    info "Provisioning from Docker config..."
    # Run as root (packages/services need root), env exports go to rlock's profile
    local env_exports=""
    local pkg_commands=""

    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        if [[ "$cmd" == export* ]]; then
            env_exports="${env_exports:+$env_exports
}$cmd"
        else
            pkg_commands="${pkg_commands:+$pkg_commands
}$cmd"
        fi
    done <<< "$script"

    # Execute package/service commands as root
    if [[ -n "$pkg_commands" ]]; then
        echo "$pkg_commands" | aq exec "$vm" sh -s
    fi

    # Add env exports to rlock's profile
    if [[ -n "$env_exports" ]]; then
        echo "$env_exports" | aq exec "$vm" sh -c 'cat >> /home/rlock/.profile'
    fi
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

- [ ] **Step 3: Update KNOWN-LIMITATIONS.md**

Append to `KNOWN-LIMITATIONS.md`:

```markdown

## Docker Plugin

- **No incremental updates** — if Dockerfile or docker-compose.yml changes, `rl rm && rl new` is required.
- **Multi-stage Dockerfiles** — not supported. `FROM ... AS ...` lines are skipped.
- **COPY/ADD** — skipped. Source code is delivered via the git plugin.
- **Version pinning** — `FROM ruby:3.2.1` installs via mise, which may resolve to the closest available patch version.
- **Exotic compose services** — only postgres, redis, mysql/mariadb, and memcached are mapped. Custom images require manual installation.
- **RUN passthrough** — non-package-install RUN commands are executed as-is; some may fail on Alpine due to musl/glibc or missing tools.
```

- [ ] **Step 4: Run all tests**

Run: `bats test/`
Expected: All tests pass (previous 35 + new dockerfile + compose tests).

- [ ] **Step 5: Run ShellCheck on all docker plugin files**

Run: `shellcheck plugins/docker/plugin.sh plugins/docker/parse-dockerfile.sh plugins/docker/parse-compose.sh`

- [ ] **Step 6: Commit**

```bash
git add plugins/docker/ KNOWN-LIMITATIONS.md
git commit -m "feat(docker): complete docker plugin with provision hook"
```

---

## Self-Review

**Spec coverage:**
- Plugin structure (plugin.toml, plugin.sh, pkg-map.txt) → Task 1, 6
- Dockerfile FROM parsing → Task 2
- Dockerfile RUN translation → Task 3
- Dockerfile ENV, WORKDIR, full parser, continuation lines → Task 4
- docker-compose.yml translation → Task 5
- Provisioning flow → Task 6
- Error handling → spread across all tasks (passthrough, warn, continue)
- Re-provisioning (rl rm && rl new) → documented in KNOWN-LIMITATIONS.md (Task 6)
- pkg-map.txt → Task 1

**Placeholder scan:** No TBDs, TODOs, or "similar to Task N" references.

**Type consistency:**
- `pkg_map_lookup` — consistent across Task 1 and Task 3
- `parse_from` — defined Task 2, used in `translate_dockerfile` Task 4
- `parse_run` — defined Task 3, used in `translate_dockerfile` Task 4
- `parse_env`, `parse_workdir` — defined and used in Task 4
- `translate_dockerfile` — defined Task 4, used in Task 6
- `translate_compose_service`, `translate_compose` — defined Task 5, used in Task 6
