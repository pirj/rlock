# Layered Snapshots — Step 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the full layered-snapshots design from `docs/superpowers/specs/2026-05-11-layered-snapshots-design.md` inside the current monorepo. After this plan, `rl new` boots a Rails+Postgres project from a warm cache in under one second, and the snapshot mechanism is generalized so any plugin can declare a cached layer.

**Architecture:** Extend `plugin.toml` with a `[snapshot]` section and a `protocol_version` field. Add `snapshot_key` / `snapshot_build` hooks in `plugin.sh`. New `lib/snapshot.sh` orchestrates a qcow2 backing-file chain across plugins in `resolve_deps` order. Refactor the branch plugin onto the new protocol. Add `docker-engine` + `docker-compose` plugins that produce the warm layer. Wire it all into `cmd_new`.

**Tech Stack:** Bash 5, BATS (with bats-support + bats-assert), `qemu-img`, `aq` CLI, `yq` (already a docker plugin host_dep), `jq` (for `docker compose ps --format json`).

---

## File Structure

**New files:**
- `lib/snapshot.sh` — orchestration library (lookup, save, rebase, walk_chain, prune).
- `plugins/docker-engine/plugin.toml`, `plugins/docker-engine/plugin.sh` — installs Docker daemon inside guest.
- `plugins/docker-compose/plugin.toml`, `plugins/docker-compose/plugin.sh` — runs `docker compose build && up -d`, waits for healthchecks.
- `test/snapshot.bats` — unit tests for `lib/snapshot.sh` path/lookup/save/rebase helpers.
- `test/plugin_snapshot.bats` — tests for `[snapshot]` section parsing and protocol version handling.
- `test/branch_snapshot.bats` — tests for the refactored branch plugin's `snapshot_key`/`snapshot_build`.
- `test/docker_compose_warm.bats` — tests for the new docker-compose plugin's healthcheck-aware build.

**Modified files:**
- `lib/toml.sh` — add `toml_get_in_section` reader.
- `lib/plugin.sh` — add `plugin_snapshot_strategy`, `plugin_has_snapshot`, `plugin_protocol_version` helpers; add validation.
- `bin/rl` — restructure `cmd_new` to call `snapshot_walk_chain`; bump VM disk to 16G, RAM via aq; trigger background prune.
- `plugins/branch/plugin.toml` — add `[snapshot]` with `strategy = "cached"`.
- `plugins/branch/plugin.sh` — replace direct qcow2 logic with `snapshot_key`/`snapshot_build` hooks.
- `plugins/branch/commands/branch.sh` — collapse to a thin wrapper that delegates to `cmd_new` with branch plugin forced active.

**Untouched (intentional):**
- `plugins/docker/` — deprecated translator stays as is until Step 3 of the migration plan.

---

## Task 1: Add `toml_get_in_section` reader

**Files:**
- Modify: `lib/toml.sh`
- Test: `test/toml.bats`

- [ ] **Step 1: Write failing tests**

Append to `test/toml.bats`:

```bash
@test "toml_get_in_section reads string key under section" {
    local f="$BATS_TEST_TMPDIR/x.toml"
    cat > "$f" <<EOF
description = "Top-level"

[snapshot]
strategy = "cached"
order = "200"
EOF
    run toml_get_in_section "$f" "snapshot" "strategy"
    assert_success
    assert_output "cached"
}

@test "toml_get_in_section returns empty when key absent in section" {
    local f="$BATS_TEST_TMPDIR/x.toml"
    cat > "$f" <<EOF
[snapshot]
strategy = "cached"
EOF
    run toml_get_in_section "$f" "snapshot" "missing"
    assert_success
    assert_output ""
}

@test "toml_get_in_section returns empty when section absent" {
    local f="$BATS_TEST_TMPDIR/x.toml"
    echo 'description = "x"' > "$f"
    run toml_get_in_section "$f" "snapshot" "strategy"
    assert_success
    assert_output ""
}

@test "toml_get_in_section does not bleed across sections" {
    local f="$BATS_TEST_TMPDIR/x.toml"
    cat > "$f" <<EOF
[other]
strategy = "noop"

[snapshot]
strategy = "cached"
EOF
    run toml_get_in_section "$f" "snapshot" "strategy"
    assert_success
    assert_output "cached"
}
```

- [ ] **Step 2: Run and confirm failure**

```
bats test/toml.bats
```
Expected: 4 new tests FAIL with "command not found".

- [ ] **Step 3: Implement `toml_get_in_section`**

Append to `lib/toml.sh`:

```bash
# Parse a string value from a [section] in a TOML file.
# Usage: toml_get_in_section file section key
# Prints the value (unquoted) or empty string if section/key not found.
toml_get_in_section() {
    local file="$1" section="$2" key="$3"
    awk -v sec="[$section]" -v k="$key" '
        $0 == sec { in_sec = 1; next }
        /^\[/     { in_sec = 0; next }
        in_sec && $0 ~ "^" k " *= *\"" {
            sub("^" k " *= *\"", ""); sub("\".*", "")
            print; exit
        }
    ' "$file"
}
```

- [ ] **Step 4: Run tests to confirm pass**

```
bats test/toml.bats
```
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/toml.sh test/toml.bats
git commit -m "feat(toml): add toml_get_in_section reader"
```

---

## Task 2: Add `protocol_version` field + plugin protocol helpers

**Files:**
- Modify: `lib/plugin.sh`
- Test: `test/plugin_snapshot.bats` (new)

- [ ] **Step 1: Write failing tests**

Create `test/plugin_snapshot.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/plugin.sh"
}

_make_plugin() {
    local name="$1"; shift
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    printf '%s\n' "$@" > "$PLUGIN_CORE_DIR/$name/plugin.toml"
}

@test "plugin_has_snapshot is true when [snapshot] section exists" {
    _make_plugin "p1" 'description = "P"' '[snapshot]' 'strategy = "cached"'
    run plugin_has_snapshot "p1"
    assert_success
}

@test "plugin_has_snapshot is false when section missing" {
    _make_plugin "p2" 'description = "P"'
    run plugin_has_snapshot "p2"
    assert_failure
}

@test "plugin_snapshot_strategy defaults to cached when empty" {
    _make_plugin "p3" 'description = "P"' '[snapshot]'
    run plugin_snapshot_strategy "p3"
    assert_success
    assert_output "cached"
}

@test "plugin_snapshot_strategy reads explicit value" {
    _make_plugin "p4" 'description = "P"' '[snapshot]' 'strategy = "incremental"'
    run plugin_snapshot_strategy "p4"
    assert_success
    assert_output "incremental"
}

@test "plugin_snapshot_strategy rejects unknown value" {
    _make_plugin "p5" 'description = "P"' '[snapshot]' 'strategy = "garbage"'
    run plugin_snapshot_strategy "p5"
    assert_failure
    assert_output --partial "unknown snapshot strategy"
}

@test "plugin_protocol_version returns declared version" {
    _make_plugin "p6" 'protocol_version = "1"' 'description = "P"'
    run plugin_protocol_version "p6"
    assert_success
    assert_output "1"
}

@test "plugin_protocol_version defaults to 1 when absent" {
    _make_plugin "p7" 'description = "P"'
    run plugin_protocol_version "p7"
    assert_success
    assert_output "1"
}

@test "check_protocol_versions rejects future version" {
    _make_plugin "p8" 'protocol_version = "2"' 'description = "P"'
    run check_protocol_versions "p8"
    assert_failure
    assert_output --partial "requires protocol version 2"
}
```

- [ ] **Step 2: Run and confirm failure**

```
bats test/plugin_snapshot.bats
```
Expected: all 8 tests FAIL (functions not defined).

- [ ] **Step 3: Implement helpers**

Append to `lib/plugin.sh`:

```bash
# Maximum plugin protocol version supported by this framework.
PLUGIN_PROTOCOL_VERSION="1"

# Print the protocol version declared by a plugin, or "1" if unset.
plugin_protocol_version() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    local v
    v=$(toml_get "$pdir/plugin.toml" "protocol_version")
    echo "${v:-1}"
}

# Verify every named plugin declares a protocol version <= framework's max.
# Prints an error and returns 1 if any plugin requires a newer protocol.
check_protocol_versions() {
    local plugin v
    for plugin in "$@"; do
        v=$(plugin_protocol_version "$plugin")
        if [[ "$v" -gt "$PLUGIN_PROTOCOL_VERSION" ]]; then
            echo "Plugin '$plugin' requires protocol version $v, this framework supports up to $PLUGIN_PROTOCOL_VERSION" >&2
            return 1
        fi
    done
}

# Returns 0 if plugin declares a [snapshot] section, 1 otherwise.
plugin_has_snapshot() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    grep -q '^\[snapshot\]' "$pdir/plugin.toml"
}

# Print the snapshot strategy declared by a plugin.
# Defaults to "cached" when [snapshot] is present but strategy is unset.
# Returns 1 with an error on unknown strategy.
plugin_snapshot_strategy() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    local s
    s=$(toml_get_in_section "$pdir/plugin.toml" "snapshot" "strategy")
    s="${s:-cached}"
    case "$s" in
        cached|incremental|ephemeral) echo "$s" ;;
        *) echo "Plugin '$plugin' declares unknown snapshot strategy '$s'" >&2; return 1 ;;
    esac
}
```

- [ ] **Step 4: Run tests to confirm pass**

```
bats test/plugin_snapshot.bats
```
Expected: all 8 tests PASS. Also re-run the full suite to confirm nothing else regressed:
```
bats test/
```

- [ ] **Step 5: Commit**

```bash
git add lib/plugin.sh test/plugin_snapshot.bats
git commit -m "feat(plugin): protocol_version field + [snapshot] section helpers"
```

---

## Task 3: `lib/snapshot.sh` foundation (paths, lookup, save, rebase)

**Files:**
- Create: `lib/snapshot.sh`
- Test: `test/snapshot.bats` (new)

- [ ] **Step 1: Write failing tests**

Create `test/snapshot.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    export RL_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$RL_CACHE_DIR"
    source "$LIB_DIR/snapshot.sh"
}

@test "snapshot_cache_path returns plugin/key/snapshot.qcow2" {
    run snapshot_cache_path "ruby-bundler" "abc123"
    assert_success
    assert_output "$RL_CACHE_DIR/ruby-bundler/abc123/snapshot.qcow2"
}

@test "snapshot_lookup hits when file exists" {
    local p="$RL_CACHE_DIR/foo/k1"
    mkdir -p "$p"
    touch "$p/snapshot.qcow2"
    run snapshot_lookup "foo" "k1"
    assert_success
    assert_output "$p/snapshot.qcow2"
}

@test "snapshot_lookup misses when file absent" {
    run snapshot_lookup "foo" "k1"
    assert_failure
}

@test "snapshot_latest finds most-recent snapshot regardless of key" {
    mkdir -p "$RL_CACHE_DIR/foo/k1" "$RL_CACHE_DIR/foo/k2"
    touch "$RL_CACHE_DIR/foo/k1/snapshot.qcow2"
    sleep 0.05
    touch "$RL_CACHE_DIR/foo/k2/snapshot.qcow2"
    run snapshot_latest "foo"
    assert_success
    assert_output "$RL_CACHE_DIR/foo/k2/snapshot.qcow2"
}

@test "snapshot_latest fails when plugin has no snapshots" {
    run snapshot_latest "never-built"
    assert_failure
}

@test "snapshot_save creates qcow2 + meta.json" {
    local src="$BATS_TEST_TMPDIR/src.qcow2"
    qemu-img create -f qcow2 "$src" 1M >/dev/null
    run snapshot_save "$src" "demo" "key-xyz" "parent-plugin" "parent-key"
    assert_success
    [ -f "$RL_CACHE_DIR/demo/key-xyz/snapshot.qcow2" ]
    [ -f "$RL_CACHE_DIR/demo/key-xyz/meta.json" ]
    run jq -r '.parent_plugin' "$RL_CACHE_DIR/demo/key-xyz/meta.json"
    assert_output "parent-plugin"
}

@test "snapshot_rebase creates qcow2 with given backing" {
    local backing="$BATS_TEST_TMPDIR/backing.qcow2"
    qemu-img create -f qcow2 "$backing" 1M >/dev/null
    local out="$BATS_TEST_TMPDIR/top.qcow2"
    run snapshot_rebase "$out" "$backing"
    assert_success
    [ -f "$out" ]
    qemu-img info "$out" | grep -q "backing file: $backing"
}
```

- [ ] **Step 2: Run and confirm failure**

```
bats test/snapshot.bats
```
Expected: all 7 tests FAIL (lib not found / functions not defined).

- [ ] **Step 3: Implement `lib/snapshot.sh`**

Create `lib/snapshot.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Cache root for snapshot layers. Defaults to ~/.local/share/aq/cache.
# Overridable for tests via RL_CACHE_DIR.
RL_CACHE_DIR="${RL_CACHE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aq/cache}"

# Resolve the cache path for a given (plugin, key) pair.
# Usage: snapshot_cache_path plugin key
snapshot_cache_path() {
    local plugin="$1" key="$2"
    echo "$RL_CACHE_DIR/$plugin/$key/snapshot.qcow2"
}

# If a snapshot exists for (plugin, key), print its path and return 0.
# Otherwise return non-zero with no output.
snapshot_lookup() {
    local plugin="$1" key="$2"
    local p
    p=$(snapshot_cache_path "$plugin" "$key")
    [[ -f "$p" ]] && { echo "$p"; return 0; } || return 1
}

# Print the path of the most recently built snapshot for a plugin
# (any key). Returns non-zero if the plugin has no snapshots.
snapshot_latest() {
    local plugin="$1"
    local dir="$RL_CACHE_DIR/$plugin"
    [[ -d "$dir" ]] || return 1
    local newest
    newest=$(find "$dir" -name snapshot.qcow2 -type f -print 2>/dev/null \
        | xargs -r ls -t 2>/dev/null \
        | head -1)
    [[ -n "$newest" ]] && { echo "$newest"; return 0; } || return 1
}

# Save a VM's current qcow2 disk as a cached layer snapshot.
# Usage: snapshot_save src_qcow2 plugin key parent_plugin parent_key
# parent_plugin / parent_key may be empty strings.
snapshot_save() {
    local src="$1" plugin="$2" key="$3" parent_plugin="${4:-}" parent_key="${5:-}"
    local dir="$RL_CACHE_DIR/$plugin/$key"
    mkdir -p "$dir"
    qemu-img convert -O qcow2 "$src" "$dir/snapshot.qcow2"
    cat > "$dir/meta.json" <<META
{
  "plugin": "$plugin",
  "key": "$key",
  "parent_plugin": "$parent_plugin",
  "parent_key": "$parent_key",
  "built_at": "$(date -u +%FT%TZ)"
}
META
}

# Create a new qcow2 with the given file as its backing.
# Usage: snapshot_rebase output_qcow2 backing_qcow2
snapshot_rebase() {
    local out="$1" backing="$2"
    qemu-img create -f qcow2 -b "$backing" -F qcow2 "$out" >/dev/null
}
```

- [ ] **Step 4: Run tests to confirm pass**

```
bats test/snapshot.bats
```
Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/snapshot.sh test/snapshot.bats
git commit -m "feat(snapshot): foundation for cached layer chains"
```

---

## Task 4: `snapshot_walk_chain` orchestrator — cached strategy

**Files:**
- Modify: `lib/snapshot.sh`
- Test: `test/snapshot.bats`

- [ ] **Step 1: Write failing tests**

Append to `test/snapshot.bats`:

```bash
# --- snapshot_walk_chain ---

_setup_fake_plugin() {
    # Args: name strategy key build_cmd
    local name="$1" strategy="$2" key="$3" build_cmd="$4"
    mkdir -p "$BATS_TEST_TMPDIR/core/$name"
    cat > "$BATS_TEST_TMPDIR/core/$name/plugin.toml" <<EOF
description = "Fake $name"

[snapshot]
strategy = "$strategy"
EOF
    cat > "$BATS_TEST_TMPDIR/core/$name/plugin.sh" <<SH
#!/usr/bin/env bash
snapshot_key()  { echo "$key"; }
snapshot_build() { echo "BUILT:$name" >> "$BATS_TEST_TMPDIR/built.log"; $build_cmd; }
[[ -n "\${1:-}" ]] && "\$1" "\${@:2}"
SH
    chmod +x "$BATS_TEST_TMPDIR/core/$name/plugin.sh"
}

@test "snapshot_walk_chain cached: cache hit skips build" {
    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core" PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user"
    source "$LIB_DIR/plugin.sh"

    _setup_fake_plugin "p1" "cached" "k1" "true"
    mkdir -p "$RL_CACHE_DIR/p1/k1"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/p1/k1/snapshot.qcow2" 1M >/dev/null

    # Stub VM ops so walk_chain can run without real VM
    aq_stop() { :; }
    snapshot_walk_vm_boot() { :; }
    snapshot_walk_vm_disk() { echo "$BATS_TEST_TMPDIR/fake.qcow2"; }
    export -f aq_stop snapshot_walk_vm_boot snapshot_walk_vm_disk

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "p1"
    assert_success
    [ ! -s "$BATS_TEST_TMPDIR/built.log" ]
}

@test "snapshot_walk_chain cached: miss triggers build + save" {
    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core" PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user"
    source "$LIB_DIR/plugin.sh"

    _setup_fake_plugin "p2" "cached" "k2" "true"

    # Stub VM disk handle: writable qcow2 the orchestrator copies on save
    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot() { :; }
    snapshot_walk_vm_stop() { :; }
    snapshot_walk_vm_disk() { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }
    export -f snapshot_walk_vm_boot snapshot_walk_vm_stop snapshot_walk_vm_disk snapshot_walk_vm_rebase

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "p2"
    assert_success
    grep -q "BUILT:p2" "$BATS_TEST_TMPDIR/built.log"
    [ -f "$RL_CACHE_DIR/p2/k2/snapshot.qcow2" ]
}
```

- [ ] **Step 2: Run to confirm failure**

```
bats test/snapshot.bats
```
Expected: the two new tests FAIL (`snapshot_walk_chain` undefined).

- [ ] **Step 3: Implement `snapshot_walk_chain` + VM seam functions**

Append to `lib/snapshot.sh`:

```bash
# --- VM seam ---
# Thin wrappers around aq / qemu-img so tests can stub them.

snapshot_walk_vm_disk() {
    # Print the path of the current VM disk.
    local vm="$1"
    echo "$AQ_STATE_DIR/$vm/storage.qcow2"
}

snapshot_walk_vm_boot() {
    local vm="$1"
    aq start "$vm" >/dev/null
}

snapshot_walk_vm_stop() {
    local vm="$1"
    aq stop "$vm" >/dev/null 2>&1 || true
}

snapshot_walk_vm_rebase() {
    # Replace VM disk with a new qcow2 backed by the given file.
    local vm="$1" backing="$2"
    local disk
    disk=$(snapshot_walk_vm_disk "$vm")
    rm -f "$disk"
    snapshot_rebase "$disk" "$backing"
}

# Walk the layer chain for an ordered plugin list.
# Usage: snapshot_walk_chain vm plugin1 [plugin2 ...]
# For each plugin with [snapshot]:
#   * cached: lookup by current key; on miss, boot on parent, run snapshot_build, save.
#   * incremental: lookup by current key; on miss, boot on latest-of-plugin (if any),
#                  else parent, run snapshot_build, save under current key.
#   * ephemeral: never cached. Boot on parent, run snapshot_build, do not save.
# Plugins without [snapshot] are skipped here (provision is run elsewhere).
snapshot_walk_chain() {
    local vm="$1"; shift
    local parent_plugin="" parent_key="" parent_path=""

    local plugin strategy key cache_path latest
    for plugin in "$@"; do
        plugin_has_snapshot "$plugin" || continue
        strategy=$(plugin_snapshot_strategy "$plugin")
        key=$(run_hook "$plugin" "snapshot_key")

        # Cache hit (cached + incremental only)
        if [[ "$strategy" != "ephemeral" ]] && cache_path=$(snapshot_lookup "$plugin" "$key"); then
            snapshot_walk_vm_rebase "$vm" "$cache_path"
            parent_plugin="$plugin"; parent_key="$key"; parent_path="$cache_path"
            continue
        fi

        # Miss: pick the right backing
        if [[ "$strategy" == "incremental" ]]; then
            if latest=$(snapshot_latest "$plugin" 2>/dev/null); then
                snapshot_walk_vm_rebase "$vm" "$latest"
            elif [[ -n "$parent_path" ]]; then
                snapshot_walk_vm_rebase "$vm" "$parent_path"
            fi
        fi
        # For cached: VM is already on parent's qcow2 (or initial base).
        # For ephemeral: same — run on whatever the VM disk currently is.

        snapshot_walk_vm_boot "$vm"
        run_hook "$plugin" "snapshot_build" "$vm"
        snapshot_walk_vm_stop "$vm"

        if [[ "$strategy" != "ephemeral" ]]; then
            local disk
            disk=$(snapshot_walk_vm_disk "$vm")
            snapshot_save "$disk" "$plugin" "$key" "$parent_plugin" "$parent_key"
            parent_plugin="$plugin"; parent_key="$key"
            parent_path=$(snapshot_cache_path "$plugin" "$key")
        fi
    done
}
```

Note: `lib/snapshot.sh` is sourced from `bin/rl` in Task 8, not from `lib/plugin.sh`. Plugin hooks run as subprocesses (`bash plugin.sh hook-name`) and can source the lib themselves via `RL_LIB_DIR` if they need its helpers.

- [ ] **Step 4: Run tests to confirm pass**

```
bats test/snapshot.bats
```
Expected: all tests in the file PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/snapshot.sh test/snapshot.bats
git commit -m "feat(snapshot): cached strategy orchestrator (walk_chain)"
```

---

## Task 5: `incremental` strategy in `snapshot_walk_chain`

**Files:**
- Test: `test/snapshot.bats`
- (Implementation already drafted in Task 4 — this task verifies behavior explicitly.)

- [ ] **Step 1: Write failing tests**

Append to `test/snapshot.bats`:

```bash
@test "snapshot_walk_chain incremental: miss boots from latest-of-plugin" {
    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core" PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user"
    source "$LIB_DIR/plugin.sh"

    _setup_fake_plugin "p3" "incremental" "new-key" "true"
    # Existing snapshot for an older key
    mkdir -p "$RL_CACHE_DIR/p3/old-key"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/p3/old-key/snapshot.qcow2" 1M >/dev/null

    local rebased_to=""
    snapshot_walk_vm_rebase() { rebased_to="$2"; }
    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot() { :; }
    snapshot_walk_vm_stop() { :; }
    snapshot_walk_vm_disk() { echo "$fakedisk"; }
    export -f snapshot_walk_vm_rebase snapshot_walk_vm_boot snapshot_walk_vm_stop snapshot_walk_vm_disk

    snapshot_walk_chain "fakevm" "p3"
    [ "$rebased_to" = "$RL_CACHE_DIR/p3/old-key/snapshot.qcow2" ]
    [ -f "$RL_CACHE_DIR/p3/new-key/snapshot.qcow2" ]
}
```

- [ ] **Step 2: Run to confirm failure / success**

```
bats test/snapshot.bats
```
Expected: if Task 4 was complete, this should already PASS. If it fails, fix the orchestrator until it passes.

- [ ] **Step 3: No new implementation; verify and commit**

```bash
git add test/snapshot.bats
git commit -m "test(snapshot): incremental strategy boots from latest"
```

---

## Task 6: `ephemeral` strategy in `snapshot_walk_chain`

**Files:**
- Test: `test/snapshot.bats`

- [ ] **Step 1: Write failing tests**

Append to `test/snapshot.bats`:

```bash
@test "snapshot_walk_chain ephemeral: runs build but does not save" {
    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core" PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user"
    source "$LIB_DIR/plugin.sh"

    _setup_fake_plugin "p4" "ephemeral" "k4" "true"

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot() { :; }
    snapshot_walk_vm_stop() { :; }
    snapshot_walk_vm_disk() { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }
    export -f snapshot_walk_vm_boot snapshot_walk_vm_stop snapshot_walk_vm_disk snapshot_walk_vm_rebase

    : > "$BATS_TEST_TMPDIR/built.log"
    snapshot_walk_chain "fakevm" "p4"
    grep -q "BUILT:p4" "$BATS_TEST_TMPDIR/built.log"
    [ ! -d "$RL_CACHE_DIR/p4" ]
}
```

- [ ] **Step 2: Run to confirm pass**

```
bats test/snapshot.bats
```
Expected: PASS (orchestrator already handles ephemeral). If not, fix and re-run.

- [ ] **Step 3: Commit**

```bash
git add test/snapshot.bats
git commit -m "test(snapshot): ephemeral strategy never persists"
```

---

## Task 7: Bump VM disk to 16G in `bin/rl`

**Files:**
- Modify: `bin/rl` (line ~103)

- [ ] **Step 1: Locate the current resize**

In `bin/rl`, the current call is:
```bash
qemu-img resize "$AQ_STATE_DIR/$vm_name/storage.qcow2" 4G >/dev/null 2>&1 || true
```

- [ ] **Step 2: Replace with 16G**

```bash
qemu-img resize "$AQ_STATE_DIR/$vm_name/storage.qcow2" 16G >/dev/null 2>&1 || true
```

- [ ] **Step 3: Verify by smoke test**

```
shellcheck bin/rl
```
Expected: no new findings.

- [ ] **Step 4: Commit**

```bash
git add bin/rl
git commit -m "feat(rl): bump VM disk to 16G for docker-in-VM workloads"
```

Note: RAM is set by `aq` defaults. If raising RAM requires aq changes, file an issue in pirj/aq and revisit; do not block this plan on it.

---

## Task 8: Wire `snapshot_walk_chain` into `cmd_new`

**Files:**
- Modify: `bin/rl` (within `cmd_new`)

- [ ] **Step 1: Read current cmd_new structure**

Confirm the existing flow in `bin/rl` lines 30-184:
- detect/resolve plugins
- `aq new`, `qemu-img resize`, `aq start`
- wait for SSH
- base provisioning (sshd + rlock user)
- plugin provision hooks
- plugin start hooks

- [ ] **Step 2: Insert snapshot walk after base provisioning**

Add `source "$LIB_DIR/snapshot.sh"` near the top of `bin/rl` after the other `source` statements.

After the "Base environment ready" spinner_stop block (around line 157) and before "Run plugin provision hooks", insert:

```bash
    # Walk the snapshot layer chain.
    # Plugins with [snapshot] participate; others are skipped here.
    spinner_start "Walking snapshot layers"
    if [[ ${#resolved[@]} -gt 0 ]]; then
        snapshot_walk_chain "$vm_name" "${resolved[@]}"
    fi
    spinner_stop "Layers ready"
```

The subsequent `provision` hook loop (line 161-168) handles plugins without `[snapshot]`. To avoid running `provision` for plugins that already produced a layer via `snapshot_build`, change the loop body:

```bash
    # Run provision hooks for non-snapshot plugins (legacy + side-effect-only)
    for plugin in "${resolved[@]}"; do
        if plugin_has_snapshot "$plugin"; then
            continue
        fi
        spinner_start "Provisioning: $plugin"
        if ! run_hook "$plugin" "provision" "$vm_name"; then
            spinner_stop "FAILED: $plugin"
            die "Plugin '$plugin' provisioning failed."
        fi
        spinner_stop "Provisioned: $plugin"
    done
```

Add the protocol check right after `resolve_deps`:

```bash
    if [[ ${#resolved[@]} -gt 0 ]]; then
        check_protocol_versions "${resolved[@]}" || die "Plugin protocol incompatible."
        check_host_deps "${resolved[@]}"
        check_command_conflicts "${resolved[@]}"
    fi
```

- [ ] **Step 3: Add SSH wait after each layer**

`snapshot_walk_vm_boot` calls `aq start` but the VM needs SSH ready before `snapshot_build` runs `aq exec` over SSH. Replace `snapshot_walk_vm_boot` body in `lib/snapshot.sh`:

```bash
snapshot_walk_vm_boot() {
    local vm="$1"
    aq start "$vm" >/dev/null
    wait_for_ssh "$vm" 60 >/dev/null
}
```

`wait_for_ssh` lives in `lib/util.sh` — confirm by `grep -n wait_for_ssh lib/util.sh`. If absent, add it:

```bash
wait_for_ssh() {
    local vm="$1" timeout="${2:-60}"
    local i
    for ((i=0; i<timeout; i++)); do
        aq exec "$vm" true >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
```

- [ ] **Step 4: Smoke-test by running the existing test suite**

```
bats test/
```
Expected: all tests PASS. No regressions in `activation.bats`, `dependency_resolution.bats`, etc.

- [ ] **Step 5: Commit**

```bash
git add bin/rl lib/snapshot.sh lib/util.sh
git commit -m "feat(rl): integrate snapshot_walk_chain into cmd_new"
```

---

## Task 9: Refactor `branch` plugin onto the new protocol

**Files:**
- Modify: `plugins/branch/plugin.toml`
- Modify: `plugins/branch/plugin.sh`
- Modify: `plugins/branch/commands/branch.sh`
- Test: `test/branch_snapshot.bats` (new)

- [ ] **Step 1: Write failing tests**

Create `test/branch_snapshot.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_DIR="$PROJECT_ROOT/plugins/branch"
    source "$PLUGIN_DIR/lib.sh"

    cd "$BATS_TEST_TMPDIR"
    git init -q -b main testrepo
    cd testrepo
    git config user.email t@t
    git config user.name t
    echo init > a; git add a
    git -c commit.gpgsign=false commit -qm init
}

@test "branch plugin declares [snapshot] cached strategy in toml" {
    run grep -q '^\[snapshot\]' "$PROJECT_ROOT/plugins/branch/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"cached"' "$PROJECT_ROOT/plugins/branch/plugin.toml"
    assert_success
}

@test "branch snapshot_key returns sanitized@base-sha" {
    git checkout -qb feature/foo
    local sha
    sha=$(git rev-parse --short=7 main)
    run bash "$PROJECT_ROOT/plugins/branch/plugin.sh" snapshot_key
    assert_success
    assert_output "feature_foo@${sha}"
}
```

- [ ] **Step 2: Run to confirm failure**

```
bats test/branch_snapshot.bats
```
Expected: tests FAIL (toml lacks section, hook missing).

- [ ] **Step 3: Update `plugins/branch/plugin.toml`**

Replace the file:

```toml
description = "Per-branch VM isolation with qcow2 snapshot inheritance"
protocol_version = "1"
deps = ["git"]
host_deps = ["qemu-img", "git"]
triggers = []
commands = ["branch"]

[snapshot]
strategy = "cached"
```

- [ ] **Step 4: Update `plugins/branch/plugin.sh`**

Replace the file:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

BRANCH_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BRANCH_PLUGIN_DIR/lib.sh"

# Resolve the active VM from the current git branch.
resolve_vm() {
    git rev-parse --is-inside-work-tree > /dev/null 2>&1 || return 0
    _branch_vm_name 2>/dev/null || true
}

# Snapshot layer identity = sanitized-branch@base-sha (current logic).
snapshot_key() {
    _branch_vm_name 2>/dev/null
}

# Snapshot layer build = push the current branch into the guest repo and
# set the hostname. The qcow2 mechanics are framework's responsibility.
snapshot_build() {
    local vm="$1"
    local branch hostname
    branch=$(_branch_current) || return 0
    [[ -n "$branch" ]] || return 0
    hostname=$(_branch_sanitize "$branch")
    aq exec "$vm" sh -c "hostname '$hostname' && echo '$hostname' > /etc/hostname" || true

    # Push code (host-as-remote pattern).
    if git remote get-url rl > /dev/null 2>&1; then
        git remote remove rl
    fi
    local port
    port=$(get_ssh_port "$vm")
    git remote add rl "ssh://rlock@localhost:$port/home/rlock/repo"
    git config core.sshCommand "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p $port"
    git push rl "$branch" >/dev/null 2>&1 || warn "Push failed — try manually: git push rl $branch"
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

- [ ] **Step 5: Shrink `plugins/branch/commands/branch.sh`**

Replace it with a thin wrapper that re-uses the framework's `cmd_new`. For now, keep the user-facing command but delegate qcow2 work to the framework. Concretely, replace the file with:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

subcommand="${1:-create}"
shift || true

if [[ "$subcommand" == "rm" ]]; then
    # Delegate to standard rl rm — the active VM is resolved by branch's resolve_vm hook.
    exec "$RL_BIN_DIR/rl" rm "$@"
fi

# create: just run `rl new` — snapshot_walk_chain handles the layer chain,
# including branch's [snapshot] participation.
exec "$RL_BIN_DIR/rl" new "$@"
```

If `RL_BIN_DIR` is not exported by `bin/rl`, add this near the top of `bin/rl`:

```bash
export RL_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

- [ ] **Step 6: Run all branch tests**

```
bats test/branch_snapshot.bats test/branch_lib.bats test/branch_resolve.bats
```
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add plugins/branch/ test/branch_snapshot.bats bin/rl
git commit -m "refactor(branch): move qcow2 logic into framework, expose snapshot hooks"
```

---

## Task 10: `docker-engine` plugin

**Files:**
- Create: `plugins/docker-engine/plugin.toml`
- Create: `plugins/docker-engine/plugin.sh`
- Test: `test/docker_engine.bats` (new)

- [ ] **Step 1: Write failing tests**

Create `test/docker_engine.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker-engine"
}

@test "docker-engine plugin declares cached snapshot" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"cached"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "docker-engine plugin protocol_version is 1" {
    run grep -q 'protocol_version *= *"1"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "docker-engine snapshot_key is stable for same input" {
    local k1 k2
    k1=$(RL_LIB_DIR="$PROJECT_ROOT/lib" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$PROJECT_ROOT/lib" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]
    [ "$k1" = "$k2" ]
}
```

- [ ] **Step 2: Confirm failure**

```
bats test/docker_engine.bats
```
Expected: FAIL (plugin doesn't exist).

- [ ] **Step 3: Create `plugins/docker-engine/plugin.toml`**

```toml
description = "Install Docker daemon inside the VM"
protocol_version = "1"
deps = []
host_deps = []
triggers = ["Dockerfile", "docker-compose.yml", "docker-compose.yaml"]
commands = []

[snapshot]
strategy = "cached"
```

- [ ] **Step 4: Create `plugins/docker-engine/plugin.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Snapshot key = pinned identifier for this installation recipe.
# Bump it (or include external inputs) when the recipe changes.
snapshot_key() {
    printf 'docker-engine-recipe-v1' | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    aq exec "$vm" sh <<'SH'
set -eu
apk add docker docker-cli-compose
rc-update add docker boot
service docker start
# Wait up to 30s for the daemon socket
for i in $(seq 1 30); do
    [ -S /var/run/docker.sock ] && exit 0
    sleep 1
done
echo "docker.sock did not appear" >&2
exit 1
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

- [ ] **Step 5: Run tests**

```
bats test/docker_engine.bats
```
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add plugins/docker-engine/ test/docker_engine.bats
git commit -m "feat(docker-engine): plugin that installs dockerd inside the VM"
```

---

## Task 11: `docker-compose` plugin with healthcheck waiting

**Files:**
- Create: `plugins/docker-compose/plugin.toml`
- Create: `plugins/docker-compose/plugin.sh`
- Test: `test/docker_compose_warm.bats` (new)

- [ ] **Step 1: Write failing tests**

Create `test/docker_compose_warm.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker-compose"
    cd "$BATS_TEST_TMPDIR"
}

@test "docker-compose plugin declares cached snapshot + deps on docker-engine" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'deps *= *\["docker-engine"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "docker-compose snapshot_key hashes Dockerfile + compose + .dockerignore" {
    cat > Dockerfile <<EOF
FROM alpine
EOF
    cat > docker-compose.yml <<EOF
services:
  db: {image: postgres:16}
EOF
    cat > .dockerignore <<EOF
*.log
EOF
    local k1
    k1=$(RL_LIB_DIR="$PROJECT_ROOT/lib" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]

    echo "FROM debian" > Dockerfile
    local k2
    k2=$(RL_LIB_DIR="$PROJECT_ROOT/lib" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "docker-compose snapshot_key is stable when files unchanged" {
    echo "FROM alpine" > Dockerfile
    local k1 k2
    k1=$(RL_LIB_DIR="$PROJECT_ROOT/lib" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$PROJECT_ROOT/lib" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" = "$k2" ]
}
```

- [ ] **Step 2: Confirm failure**

```
bats test/docker_compose_warm.bats
```
Expected: FAIL (plugin doesn't exist).

- [ ] **Step 3: Create `plugins/docker-compose/plugin.toml`**

```toml
description = "Build and warm up docker-compose services inside the VM"
protocol_version = "1"
deps = ["docker-engine"]
host_deps = []
triggers = ["docker-compose.yml", "docker-compose.yaml"]
commands = []

[snapshot]
strategy = "cached"
```

- [ ] **Step 4: Create `plugins/docker-compose/plugin.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Hash all files that influence the warm state.
snapshot_key() {
    {
        for f in Dockerfile docker-compose.yml docker-compose.yaml \
                 docker-compose.override.yml docker-compose.override.yaml \
                 .dockerignore; do
            [[ -f "$f" ]] && { echo "=== $f ==="; cat "$f"; }
        done
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"

    # Copy compose context into the VM. /home/rlock/repo is the project mount point;
    # the git plugin's snapshot_build delivers code via push, but here we need
    # the Dockerfile/compose files present BEFORE git push, so we scp them.
    local compose_file=""
    for cand in docker-compose.yml docker-compose.yaml; do
        [[ -f "$cand" ]] && { compose_file="$cand"; break; }
    done

    aq exec "$vm" sh <<'SH'
mkdir -p /home/rlock/repo
chown rlock:rlock /home/rlock/repo
SH

    for f in Dockerfile "$compose_file" docker-compose.override.yml \
             docker-compose.override.yaml .dockerignore; do
        [[ -n "$f" && -f "$f" ]] && aq scp "$f" "$vm:/home/rlock/repo/$f"
    done

    # Build + up + wait for healthy
    aq exec "$vm" sh <<'SH'
set -eu
cd /home/rlock/repo
docker compose build
docker compose up -d

# Wait up to 5 minutes for all services to be running and (if declared) healthy.
for i in $(seq 1 60); do
    pending=$(docker compose ps --format json | \
        jq -s '[.[] | select(.State != "running" or (.Health != null and .Health != "healthy"))] | length')
    [ "$pending" = "0" ] && exit 0
    sleep 5
done

echo "compose services failed to become healthy within 5 minutes:" >&2
docker compose ps >&2
docker compose logs --tail=50 >&2
exit 1
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

- [ ] **Step 5: Add `jq` to docker-compose host_deps if needed in guest**

The `jq` is invoked inside the VM (Alpine). Add to the snapshot_build script before the polling loop:

```bash
command -v jq >/dev/null 2>&1 || apk add jq
```

Replace the relevant section in `plugins/docker-compose/plugin.sh` accordingly.

- [ ] **Step 6: Run tests**

```
bats test/docker_compose_warm.bats
```
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add plugins/docker-compose/ test/docker_compose_warm.bats
git commit -m "feat(docker-compose): warm-up plugin with healthcheck polling"
```

---

## Task 12: Background prune of stale cache entries

**Files:**
- Modify: `lib/snapshot.sh`
- Modify: `bin/rl` (kick prune at end of cmd_new)
- Test: `test/snapshot.bats`

- [ ] **Step 1: Write failing tests**

Append to `test/snapshot.bats`:

```bash
@test "snapshot_prune removes entries older than threshold + not in live set" {
    mkdir -p "$RL_CACHE_DIR/foo/k_old" "$RL_CACHE_DIR/foo/k_recent" "$RL_CACHE_DIR/foo/k_live"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/foo/k_old/snapshot.qcow2" 1M >/dev/null
    qemu-img create -f qcow2 "$RL_CACHE_DIR/foo/k_recent/snapshot.qcow2" 1M >/dev/null
    qemu-img create -f qcow2 "$RL_CACHE_DIR/foo/k_live/snapshot.qcow2" 1M >/dev/null

    # Backdate the "old" entry
    touch -t 202401010000 "$RL_CACHE_DIR/foo/k_old/snapshot.qcow2"

    # Live set excludes k_live from pruning
    snapshot_prune --max-age-days=30 --live "$RL_CACHE_DIR/foo/k_live/snapshot.qcow2"
    [ ! -f "$RL_CACHE_DIR/foo/k_old/snapshot.qcow2" ]
    [ -f "$RL_CACHE_DIR/foo/k_recent/snapshot.qcow2" ]
    [ -f "$RL_CACHE_DIR/foo/k_live/snapshot.qcow2" ]
}
```

- [ ] **Step 2: Confirm failure**

```
bats test/snapshot.bats
```
Expected: FAIL (snapshot_prune undefined).

- [ ] **Step 3: Implement `snapshot_prune`**

Append to `lib/snapshot.sh`:

```bash
# Remove cached snapshots that are stale.
# Usage: snapshot_prune [--max-age-days=N] [--live path ...]
# A snapshot is removed when ALL conditions hold:
#   * its file mtime is older than N days (default 30)
#   * its path is not in the live set
snapshot_prune() {
    local max_age=30
    local -a live=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-age-days=*) max_age="${1#--max-age-days=}"; shift ;;
            --live) shift; live+=("$1"); shift ;;
            *) shift ;;
        esac
    done

    local removed=0 freed_bytes=0
    local snap
    while IFS= read -r snap; do
        # Skip if in live set
        local keep=0 l
        for l in "${live[@]:-}"; do
            [[ "$snap" == "$l" ]] && keep=1 && break
        done
        [[ $keep -eq 1 ]] && continue

        # Skip if recent
        if [[ -n "$(find "$snap" -mtime "-$max_age" -print 2>/dev/null)" ]]; then
            continue
        fi

        local size
        size=$(stat -f%z "$snap" 2>/dev/null || stat -c%s "$snap" 2>/dev/null || echo 0)
        rm -f "$snap" "$(dirname "$snap")/meta.json"
        rmdir "$(dirname "$snap")" 2>/dev/null || true
        removed=$((removed + 1))
        freed_bytes=$((freed_bytes + size))
    done < <(find "$RL_CACHE_DIR" -name snapshot.qcow2 -type f 2>/dev/null)

    if [[ $removed -gt 0 ]]; then
        local mb=$((freed_bytes / 1024 / 1024))
        echo "Pruned $removed stale snapshots (${mb} MB)" > "${RL_CACHE_DIR}/.last-prune.log"
    fi
}
```

- [ ] **Step 4: Hook prune into `cmd_new` (background)**

In `bin/rl`, at the very end of `cmd_new` (after `info "Active plugins"` line), add:

```bash
    # Background prune; surface results on the next rl new
    if [[ -f "${RL_CACHE_DIR:-$HOME/.local/share/aq/cache}/.last-prune.log" ]]; then
        info "$(cat "${RL_CACHE_DIR:-$HOME/.local/share/aq/cache}/.last-prune.log")"
        rm -f "${RL_CACHE_DIR:-$HOME/.local/share/aq/cache}/.last-prune.log"
    fi
    # Compute current live set from all VMs' qcow2 backing chains
    (
        live_args=()
        for d in "$AQ_STATE_DIR"/*/storage.qcow2; do
            [[ -f "$d" ]] || continue
            while IFS= read -r b; do
                [[ -n "$b" ]] && live_args+=("--live" "$b")
            done < <(qemu-img info --backing-chain "$d" 2>/dev/null \
                | sed -n 's/^backing file: //p')
        done
        snapshot_prune "${live_args[@]}"
    ) &
    disown
```

- [ ] **Step 5: Run tests**

```
bats test/snapshot.bats
```
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/snapshot.sh bin/rl test/snapshot.bats
git commit -m "feat(snapshot): background prune of stale cache entries"
```

---

## Task 13: Integration smoke test on a Rails+Postgres sample project

**Files:**
- Create: `test/fixtures/rails-pg-sample/Dockerfile`
- Create: `test/fixtures/rails-pg-sample/docker-compose.yml`
- Create: `test/integration_layered.sh` (a shell script, not a BATS test, because it shells out to real `aq`)

- [ ] **Step 1: Create fixture**

`test/fixtures/rails-pg-sample/Dockerfile`:

```dockerfile
FROM ruby:3.2-alpine
RUN apk add --no-cache build-base postgresql-dev tzdata git
WORKDIR /app
COPY . .
CMD ["sh", "-c", "tail -f /dev/null"]
```

`test/fixtures/rails-pg-sample/docker-compose.yml`:

```yaml
services:
  db:
    image: postgres:16-alpine
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      timeout: 2s
      retries: 10
    environment:
      POSTGRES_PASSWORD: pass
  app:
    build: .
    depends_on:
      db:
        condition: service_healthy
```

- [ ] **Step 2: Create `test/integration_layered.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
FIXTURE="$ROOT/test/fixtures/rails-pg-sample"

work=$(mktemp -d)
trap 'rl rm 2>/dev/null || true; rm -rf "$work"' EXIT
cp -r "$FIXTURE"/. "$work/"
cd "$work"
git init -q -b main
git -c commit.gpgsign=false -c user.email=t -c user.name=t add . && git -c commit.gpgsign=false -c user.email=t -c user.name=t commit -qm init

echo ">>> Cold rl new (expect 5+ min)"
t0=$(date +%s)
yes | rl new docker-compose
t_cold=$(( $(date +%s) - t0 ))
echo "Cold: ${t_cold}s"

rl rm

echo ">>> Warm rl new (expect <5s)"
t0=$(date +%s)
yes | rl new docker-compose
t_warm=$(( $(date +%s) - t0 ))
echo "Warm: ${t_warm}s"

if [ "$t_warm" -gt 5 ]; then
    echo "FAIL: warm boot took ${t_warm}s, expected < 5s"
    exit 1
fi
echo "PASS"
```

Make it executable: `chmod +x test/integration_layered.sh`.

- [ ] **Step 3: Run it once locally**

```
test/integration_layered.sh
```

This is a long-running test (cold path ~5min). Do NOT add it to the BATS suite. It is a manual gate — recorded in the benchmark doc.

- [ ] **Step 4: Commit**

```bash
git add test/fixtures/rails-pg-sample/ test/integration_layered.sh
git commit -m "test(integration): rails+pg smoke test for layered snapshots"
```

---

## Task 14: Record benchmark in docs

**Files:**
- Create: `docs/superpowers/benchmarks/2026-05-XX-docker-in-vm.md` (substitute today's date)

- [ ] **Step 1: Run benchmark**

Execute `test/integration_layered.sh` and capture `cold` and `warm` timings.

- [ ] **Step 2: Author benchmark doc**

```markdown
# Docker-in-VM Layered Snapshots — Benchmark

Date: 2026-05-DD
Hardware: <host details — uname -a + brief CPU/RAM>
Fixture: test/fixtures/rails-pg-sample (Rails-style app + Postgres 16)

| Scenario                | Time    |
|-------------------------|---------|
| Cold rl new (no cache)  | <X> s   |
| Warm rl new (cache hit) | <Y> s   |
| Old translator (cold)   | <Z> s   |

Notes:
- <Observations about cache hit ratio, prune output, any flakes.>

Decision per migration plan Step 0 exit gate:
- Required: warm rl new < cold-translator / 5
- Actual: <pass/fail>
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/benchmarks/2026-05-*-docker-in-vm.md
git commit -m "docs(benchmark): record initial docker-in-VM timings"
```

---

## Self-Review Checklist

After all tasks land:

- [ ] `bats test/` passes end to end (no flaky tests).
- [ ] `shellcheck bin/rl lib/*.sh plugins/*/plugin.sh` is clean.
- [ ] `rl new docker-compose` on a fresh Rails+PG project warms the cache; second run is <5s.
- [ ] Deprecated `plugins/docker/` still works for existing users (warning logged, behavior unchanged).
- [ ] Benchmark doc committed; warm-vs-cold ratio meets the >=5× gate.

## Out of Scope for this Plan

These are tracked in `TODO.md` and `docs/superpowers/specs/2026-05-11-layered-snapshots-design.md`:

- Caddy-based language registry mirror.
- Snapshot analytics (cache hit rates, `rl cache stats`).
- Subset-detection for additive-only key changes.
- Per-ecosystem layer ordering driven by churn.
- Firecracker backend (Phase 2, lives in pirj/aq).
- Repo split into `rlock` / `ai.rlock` / `<bake>` (covered by the migration plan, executed after Step 0 lands).
