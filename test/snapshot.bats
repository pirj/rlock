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
