#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    # Provide RL_LIB_DIR for plugins that source shared libs
    export RL_LIB_DIR="$LIB_DIR"

    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/plugin.sh"
}

@test "run_hook calls provision hook" {
    mkdir -p "$PLUGIN_CORE_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    cat > "$PLUGIN_CORE_DIR/git/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
set -euo pipefail
provision() { echo "provisioned:$1"; }
if declare -f "$1" > /dev/null 2>&1; then "$1" "${@:2}"; fi
PLUGIN
    chmod +x "$PLUGIN_CORE_DIR/git/plugin.sh"

    run run_hook "git" "provision" "test-vm"
    assert_success
    assert_output "provisioned:test-vm"
}

@test "run_hook silently skips undefined hooks" {
    mkdir -p "$PLUGIN_CORE_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    cat > "$PLUGIN_CORE_DIR/git/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
set -euo pipefail
provision() { echo "provisioned"; }
if declare -f "$1" > /dev/null 2>&1; then "$1" "${@:2}"; fi
PLUGIN
    chmod +x "$PLUGIN_CORE_DIR/git/plugin.sh"

    run run_hook "git" "start" "test-vm"
    assert_success
    assert_output ""
}

@test "run_hook returns failure on hook error" {
    mkdir -p "$PLUGIN_CORE_DIR/broken"
    cat > "$PLUGIN_CORE_DIR/broken/plugin.toml" <<'EOF'
description = "Broken"
EOF
    cat > "$PLUGIN_CORE_DIR/broken/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
set -euo pipefail
provision() { echo "failing" >&2; exit 1; }
if declare -f "$1" > /dev/null 2>&1; then "$1" "${@:2}"; fi
PLUGIN
    chmod +x "$PLUGIN_CORE_DIR/broken/plugin.sh"

    run run_hook "broken" "provision" "test-vm"
    assert_failure
}

@test "run_hook skips plugin with no plugin.sh" {
    mkdir -p "$PLUGIN_CORE_DIR/minimal"
    cat > "$PLUGIN_CORE_DIR/minimal/plugin.toml" <<'EOF'
description = "Minimal"
EOF
    # No plugin.sh
    run run_hook "minimal" "provision" "test-vm"
    assert_success
    assert_output ""
}

@test "dispatch_command finds and runs command script" {
    mkdir -p "$PLUGIN_CORE_DIR/agent-claude-code/commands"
    cat > "$PLUGIN_CORE_DIR/agent-claude-code/plugin.toml" <<'EOF'
description = "Claude Code"
commands = ["claude"]
EOF
    cat > "$PLUGIN_CORE_DIR/agent-claude-code/commands/claude.sh" <<'CMD'
#!/usr/bin/env bash
echo "claude:$*"
CMD
    chmod +x "$PLUGIN_CORE_DIR/agent-claude-code/commands/claude.sh"

    # Simulate active plugins
    ACTIVE_PLUGINS="agent-claude-code"
    run dispatch_command "claude" "arg1" "arg2"
    assert_success
    assert_output "claude:arg1 arg2"
}

@test "dispatch_command fails for unknown command" {
    ACTIVE_PLUGINS=""
    run dispatch_command "nonexistent"
    assert_failure
    assert_output --partial "Unknown command"
}
