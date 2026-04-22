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
    local name="$1" deps="${2:-}"
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
description = "$name plugin"
deps = [$deps]
EOF
}

@test "resolve_deps returns single plugin with no deps" {
    _make_plugin "git"
    run resolve_deps "git"
    assert_success
    assert_output "git"
}

@test "resolve_deps includes dependency before dependent" {
    _make_plugin "auth-proxy"
    _make_plugin "agent-claude-code" '"auth-proxy"'
    run resolve_deps "agent-claude-code"
    assert_success
    assert_line --index 0 "auth-proxy"
    assert_line --index 1 "agent-claude-code"
}

@test "resolve_deps handles transitive dependencies" {
    _make_plugin "base-tools"
    _make_plugin "auth-proxy" '"base-tools"'
    _make_plugin "agent-claude-code" '"auth-proxy"'
    run resolve_deps "agent-claude-code"
    assert_success
    assert_line --index 0 "base-tools"
    assert_line --index 1 "auth-proxy"
    assert_line --index 2 "agent-claude-code"
}

@test "resolve_deps deduplicates shared dependencies" {
    _make_plugin "auth-proxy"
    _make_plugin "agent-claude-code" '"auth-proxy"'
    _make_plugin "agent-codex" '"auth-proxy"'
    run resolve_deps "agent-claude-code" "agent-codex"
    assert_success
    # auth-proxy should appear exactly once
    local count
    count=$(echo "$output" | grep -c "^auth-proxy$")
    [[ "$count" -eq 1 ]]
}

@test "resolve_deps prints auto-inclusion notice to stderr" {
    _make_plugin "auth-proxy"
    _make_plugin "agent-claude-code" '"auth-proxy"'
    run --separate-stderr resolve_deps "agent-claude-code"
    assert_success
    # stderr should contain the notice
    [[ "$stderr" == *"Including auth-proxy (required by agent-claude-code)"* ]]
}

@test "resolve_deps detects circular dependency" {
    _make_plugin "a" '"b"'
    _make_plugin "b" '"a"'
    run resolve_deps "a"
    assert_failure
    assert_output --partial "Circular dependency"
}

@test "resolve_deps errors on missing dependency" {
    _make_plugin "agent-claude-code" '"nonexistent"'
    run resolve_deps "agent-claude-code"
    assert_failure
    assert_output --partial "requires 'nonexistent'"
    assert_output --partial "not installed"
}

@test "resolve_deps preserves order of independent plugins" {
    _make_plugin "git"
    _make_plugin "auth-proxy"
    run resolve_deps "git" "auth-proxy"
    assert_success
    assert_line --index 0 "git"
    assert_line --index 1 "auth-proxy"
}
