#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    export RL_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$RL_CACHE_DIR"
    source "$LIB_DIR/toml.sh"
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
    sleep 1
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

# --- snapshot_walk_chain ---

_setup_fake_plugin() {
    # Args: name strategy key
    local name="$1" strategy="$2" key="$3"
    export PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core"
    export PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user"
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
description = "Fake $name"

[snapshot]
strategy = "$strategy"
EOF
    cat > "$PLUGIN_CORE_DIR/$name/plugin.sh" <<SH
#!/usr/bin/env bash
snapshot_key()  { echo "$key"; }
snapshot_build() { echo "BUILT:$name" >> "$BATS_TEST_TMPDIR/built.log"; }
if declare -f "\$1" > /dev/null 2>&1; then "\$1" "\${@:2}"; fi
SH
    chmod +x "$PLUGIN_CORE_DIR/$name/plugin.sh"
}

@test "snapshot_walk_chain cached: cache hit skips build" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p1" "cached" "k1"
    mkdir -p "$RL_CACHE_DIR/p1/k1"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/p1/k1/snapshot.qcow2" 1M >/dev/null

    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$BATS_TEST_TMPDIR/fake.qcow2"; }
    snapshot_walk_vm_rebase() { :; }

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "p1"
    assert_success
    [ ! -s "$BATS_TEST_TMPDIR/built.log" ]
}

@test "snapshot_walk_chain cached: miss triggers build + save" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p2" "cached" "k2"

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "p2"
    assert_success
    grep -q "BUILT:p2" "$BATS_TEST_TMPDIR/built.log"
    [ -f "$RL_CACHE_DIR/p2/k2/snapshot.qcow2" ]
}

@test "snapshot_walk_chain incremental: miss boots from latest-of-plugin" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p3" "incremental" "new-key"
    # Existing snapshot for an older key
    mkdir -p "$RL_CACHE_DIR/p3/old-key"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/p3/old-key/snapshot.qcow2" 1M >/dev/null

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null

    local rebased_to=""
    snapshot_walk_vm_rebase() { rebased_to="$2"; }
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }

    snapshot_walk_chain "fakevm" "p3"
    [ "$rebased_to" = "$RL_CACHE_DIR/p3/old-key/snapshot.qcow2" ]
    [ -f "$RL_CACHE_DIR/p3/new-key/snapshot.qcow2" ]
}
