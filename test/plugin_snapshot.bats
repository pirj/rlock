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
