#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    export RL_LIB_DIR="$LIB_DIR"
    export RL_DIR="$BATS_TEST_TMPDIR/rl"
    mkdir -p "$RL_DIR"

    source "$LIB_DIR/ui.sh"
    source "$LIB_DIR/util.sh"
    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/plugin.sh"
}

_make_resolver_plugin() {
    local name="$1" output="$2"
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
description = "Test resolver"
EOF
    cat > "$PLUGIN_CORE_DIR/$name/plugin.sh" <<PLUGIN
#!/usr/bin/env bash
set -euo pipefail
resolve_vm() { echo "$output"; }
if declare -f "\$1" > /dev/null 2>&1; then "\$1" "\${@:2}"; fi
PLUGIN
}

@test "resolve_vm_name uses plugin hook output" {
    _make_resolver_plugin "resolver" "custom-vm"
    echo "resolver" > "$RL_DIR/plugins"

    run resolve_vm_name
    assert_success
    assert_output "custom-vm"
}

@test "resolve_vm_name falls back when hook empty" {
    _make_resolver_plugin "resolver" ""
    echo "resolver" > "$RL_DIR/plugins"
    cd "$BATS_TEST_TMPDIR"
    mkdir -p "myrepo"
    cd "myrepo"
    mkdir -p "$BATS_TEST_TMPDIR/aqstate/myrepo"
    AQ_STATE_DIR="$BATS_TEST_TMPDIR/aqstate" run resolve_vm_name
    assert_success
    assert_output "myrepo"
}

@test "resolve_vm_name fails when no plugin and no fallback" {
    cd "$BATS_TEST_TMPDIR"
    mkdir -p "ghostrepo"
    cd "ghostrepo"
    AQ_STATE_DIR="$BATS_TEST_TMPDIR/empty" run resolve_vm_name
    assert_failure
}
