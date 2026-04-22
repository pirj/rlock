#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/plugin.sh"

    # Create a fake project directory for trigger detection
    PROJECT="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT"
}

_make_plugin() {
    local name="$1"
    shift
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
$@
EOF
}

# --- Trigger detection ---

@test "detect_triggers finds plugins with matching triggers" {
    _make_plugin "git" 'description = "Git"
triggers = [".git"]'
    mkdir -p "$PROJECT/.git"
    run detect_triggers "$PROJECT" "git"
    assert_success
    assert_output "git"
}

@test "detect_triggers skips plugins without matching triggers" {
    _make_plugin "git" 'description = "Git"
triggers = [".git"]'
    # No .git in PROJECT
    run detect_triggers "$PROJECT" "git"
    assert_success
    assert_output ""
}

@test "detect_triggers skips already-activated plugins" {
    _make_plugin "git" 'description = "Git"
triggers = [".git"]'
    mkdir -p "$PROJECT/.git"
    ACTIVATED_PLUGINS="git" run detect_triggers "$PROJECT" "git"
    assert_success
    assert_output ""
}

@test "detect_triggers skips plugins with no triggers field" {
    _make_plugin "auth-proxy" 'description = "Auth proxy"'
    run detect_triggers "$PROJECT" "auth-proxy"
    assert_success
    assert_output ""
}

# --- Host dependency checking ---

@test "check_host_deps passes when all deps available" {
    _make_plugin "git" 'description = "Git"
host_deps = ["bash", "cat"]'
    run check_host_deps "git"
    assert_success
}

@test "check_host_deps fails on missing binary" {
    _make_plugin "git" 'description = "Git"
host_deps = ["nonexistent_binary_xyz"]'
    run check_host_deps "git"
    assert_failure
    assert_output --partial "requires 'nonexistent_binary_xyz'"
}

# --- Command conflict detection ---

@test "check_command_conflicts passes with no conflicts" {
    _make_plugin "agent-claude-code" 'description = "Claude"
commands = ["claude"]'
    _make_plugin "git" 'description = "Git"
commands = []'
    run check_command_conflicts "agent-claude-code" "git"
    assert_success
}

@test "check_command_conflicts detects duplicate commands" {
    _make_plugin "plugin-a" 'description = "A"
commands = ["code"]'
    _make_plugin "plugin-b" 'description = "B"
commands = ["code"]'
    run check_command_conflicts "plugin-a" "plugin-b"
    assert_failure
    assert_output --partial "Command 'code' claimed by both"
}
