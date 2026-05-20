#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    RLOCK_PLUGIN_PATH="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$RLOCK_PLUGIN_PATH"

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

@test "plugin_snapshot_kind defaults to cold when empty" {
    _make_plugin "pk1" 'description = "P"' '[snapshot]' 'strategy = "cached"'
    run plugin_snapshot_kind "pk1"
    assert_success
    assert_output "cold"
}

@test "plugin_snapshot_kind reads explicit live value" {
    _make_plugin "pk2" 'description = "P"' '[snapshot]' 'strategy = "cached"' 'kind = "live"'
    run plugin_snapshot_kind "pk2"
    assert_success
    assert_output "live"
}

@test "plugin_snapshot_kind rejects unknown value" {
    _make_plugin "pk3" 'description = "P"' '[snapshot]' 'strategy = "cached"' 'kind = "warm"'
    run plugin_snapshot_kind "pk3"
    assert_failure
    assert_output --partial "unknown snapshot kind"
}

@test "plugin_snapshot_memory returns empty when not declared" {
    _make_plugin "pm1" 'description = "P"' '[snapshot]' 'strategy = "cached"'
    run plugin_snapshot_memory "pm1"
    assert_success
    [ -z "$output" ]
}

@test "plugin_snapshot_memory strips G suffix" {
    _make_plugin "pm2" 'description = "P"' '[snapshot]' 'strategy = "cached"' 'memory = "4G"'
    run plugin_snapshot_memory "pm2"
    assert_success
    assert_output "4"
}

@test "plugin_snapshot_memory accepts bare integer" {
    _make_plugin "pm3" 'description = "P"' '[snapshot]' 'strategy = "cached"' 'memory = "8"'
    run plugin_snapshot_memory "pm3"
    assert_success
    assert_output "8"
}

@test "plugin_snapshot_memory rejects non-integer" {
    _make_plugin "pm4" 'description = "P"' '[snapshot]' 'strategy = "cached"' 'memory = "0"'
    run plugin_snapshot_memory "pm4"
    assert_failure
    assert_output --partial "invalid snapshot.memory"
}

@test "max_snapshot_memory picks largest across plugins" {
    _make_plugin "mm1" 'description = "A"' '[snapshot]' 'strategy = "cached"' 'memory = "2G"'
    _make_plugin "mm2" 'description = "B"' '[snapshot]' 'strategy = "cached"' 'memory = "8G"'
    _make_plugin "mm3" 'description = "C"' '[snapshot]' 'strategy = "cached"' 'memory = "4G"'
    run max_snapshot_memory mm1 mm2 mm3
    assert_success
    assert_output "8"
}

@test "max_snapshot_memory returns empty when no plugin declares" {
    _make_plugin "mm-none1" 'description = "A"' '[snapshot]' 'strategy = "cached"'
    _make_plugin "mm-none2" 'description = "B"' '[snapshot]' 'strategy = "cached"'
    run max_snapshot_memory mm-none1 mm-none2
    assert_success
    [ -z "$output" ]
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

@test "plugin_is_deprecated true when manifest declares deprecated = \"true\"" {
    _make_plugin "p9" 'description = "P"' 'deprecated = "true"'
    run plugin_is_deprecated "p9"
    assert_success
}

@test "plugin_is_deprecated false when manifest lacks the field" {
    _make_plugin "p10" 'description = "P"'
    run plugin_is_deprecated "p10"
    assert_failure
}

@test "detect_triggers skips deprecated plugins" {
    mkdir -p "$BATS_TEST_TMPDIR/project"
    touch "$BATS_TEST_TMPDIR/project/Dockerfile"
    _make_plugin "old-docker" 'description = "Old"' 'deprecated = "true"' 'triggers = ["Dockerfile"]'
    _make_plugin "new-docker" 'description = "New"' 'triggers = ["Dockerfile"]'
    run detect_triggers "$BATS_TEST_TMPDIR/project" "old-docker" "new-docker"
    assert_success
    refute_output --partial "old-docker"
    assert_output --partial "new-docker"
}
