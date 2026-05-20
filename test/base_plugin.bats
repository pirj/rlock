#!/usr/bin/env bats
#
# The `_base` framework plugin. Validates the two properties cmd_new
# relies on: a constant snapshot_key (so any rl new on the host hits
# the cached base after the first) and a valid manifest (so
# walk_chain treats it as a cached cold layer).

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$PROJECT_ROOT/plugins"
    RLOCK_PLUGIN_PATH="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$RLOCK_PLUGIN_PATH"

    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/plugin.sh"
}

@test "_base plugin manifest exists and declares cached cold snapshot" {
    local pdir
    pdir=$(plugin_dir "_base")
    [ -f "$pdir/plugin.toml" ]

    run plugin_has_snapshot "_base"
    assert_success

    run plugin_snapshot_strategy "_base"
    assert_success
    assert_output "cached"

    run plugin_snapshot_kind "_base"
    assert_success
    assert_output "cold"
}

@test "_base snapshot_key is constant across invocations" {
    local pdir
    pdir=$(plugin_dir "_base")
    export RL_LIB_DIR="$LIB_DIR"

    local k1 k2
    k1=$(bash "$pdir/plugin.sh" snapshot_key)
    k2=$(bash "$pdir/plugin.sh" snapshot_key)
    [ -n "$k1" ]
    [ "$k1" = "$k2" ]
}

@test "_base snapshot_key is a sha256-shaped hex string" {
    local pdir
    pdir=$(plugin_dir "_base")
    export RL_LIB_DIR="$LIB_DIR"

    local k
    k=$(bash "$pdir/plugin.sh" snapshot_key)
    [[ "$k" =~ ^[0-9a-f]{64}$ ]]
}

@test "_base has empty deps (sorts first in chain)" {
    local pdir
    pdir=$(plugin_dir "_base")

    local -a deps
    mapfile -t deps < <(toml_get_array "$pdir/plugin.toml" "deps")
    [ "${#deps[@]}" -eq 0 ]
}
