#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    source "$LIB_DIR/toml.sh"

    # Override plugin dirs to use temp directories
    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    source "$LIB_DIR/plugin.sh"
}

@test "discover_plugins finds core plugins" {
    mkdir -p "$PLUGIN_CORE_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git gateway"
EOF
    run discover_plugins
    assert_success
    assert_output "git"
}

@test "discover_plugins finds user plugins" {
    mkdir -p "$PLUGIN_USER_DIR/custom"
    cat > "$PLUGIN_USER_DIR/custom/plugin.toml" <<'EOF'
description = "Custom plugin"
EOF
    run discover_plugins
    assert_success
    assert_output "custom"
}

@test "discover_plugins merges core and user, sorted unique" {
    mkdir -p "$PLUGIN_CORE_DIR/git" "$PLUGIN_CORE_DIR/auth-proxy"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    cat > "$PLUGIN_CORE_DIR/auth-proxy/plugin.toml" <<'EOF'
description = "Auth proxy"
EOF
    mkdir -p "$PLUGIN_USER_DIR/custom"
    cat > "$PLUGIN_USER_DIR/custom/plugin.toml" <<'EOF'
description = "Custom"
EOF
    run discover_plugins
    assert_success
    assert_line --index 0 "auth-proxy"
    assert_line --index 1 "custom"
    assert_line --index 2 "git"
}

@test "discover_plugins skips directories without plugin.toml" {
    mkdir -p "$PLUGIN_CORE_DIR/broken"
    # No plugin.toml
    run discover_plugins
    assert_success
    assert_output ""
}

@test "plugin_dir returns core plugin path" {
    mkdir -p "$PLUGIN_CORE_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    run plugin_dir "git"
    assert_success
    assert_output "$PLUGIN_CORE_DIR/git"
}

@test "plugin_dir prefers user plugin over core" {
    mkdir -p "$PLUGIN_CORE_DIR/git" "$PLUGIN_USER_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Core git"
EOF
    cat > "$PLUGIN_USER_DIR/git/plugin.toml" <<'EOF'
description = "User git"
EOF
    run plugin_dir "git"
    assert_success
    assert_output "$PLUGIN_USER_DIR/git"
}

@test "plugin_dir fails for unknown plugin" {
    run plugin_dir "nonexistent"
    assert_failure
}

@test "discover_plugins hides names starting with underscore" {
    mkdir -p "$PLUGIN_CORE_DIR/git" "$PLUGIN_CORE_DIR/_base"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    cat > "$PLUGIN_CORE_DIR/_base/plugin.toml" <<'EOF'
description = "Framework base"
EOF
    run discover_plugins
    assert_success
    assert_output "git"
    refute_output --partial "_base"
}

@test "plugin_dir still resolves underscore-prefixed framework plugins" {
    mkdir -p "$PLUGIN_CORE_DIR/_base"
    cat > "$PLUGIN_CORE_DIR/_base/plugin.toml" <<'EOF'
description = "Framework base"
EOF
    run plugin_dir "_base"
    assert_success
    assert_output "$PLUGIN_CORE_DIR/_base"
}

@test "discover_plugins iterates a colon-separated PLUGIN_USER_DIRS list" {
    # Set up two distinct user dirs to compose.
    local dir1="$BATS_TEST_TMPDIR/u1"
    local dir2="$BATS_TEST_TMPDIR/u2"
    mkdir -p "$dir1/plugin-a" "$dir2/plugin-b"
    cat > "$dir1/plugin-a/plugin.toml" <<'EOF'
description = "From dir1"
EOF
    cat > "$dir2/plugin-b/plugin.toml" <<'EOF'
description = "From dir2"
EOF

    PLUGIN_USER_DIRS="$dir1:$dir2" run discover_plugins
    assert_success
    assert_line --index 0 "plugin-a"
    assert_line --index 1 "plugin-b"
}

@test "plugin_dir resolves from any dir in PLUGIN_USER_DIRS, earlier wins" {
    local dir1="$BATS_TEST_TMPDIR/u1"
    local dir2="$BATS_TEST_TMPDIR/u2"
    # Same plugin name in both dirs — dir1 listed first should win.
    mkdir -p "$dir1/dup" "$dir2/dup"
    cat > "$dir1/dup/plugin.toml" <<'EOF'
description = "From dir1 (priority)"
EOF
    cat > "$dir2/dup/plugin.toml" <<'EOF'
description = "From dir2 (overridden)"
EOF

    PLUGIN_USER_DIRS="$dir1:$dir2" run plugin_dir "dup"
    assert_success
    assert_output "$dir1/dup"
}

@test "PLUGIN_USER_DIRS empty entries are skipped" {
    # ":dir::" style — leading / trailing / consecutive colons mustn't
    # confuse discover_plugins into scanning $PWD or such.
    local dir1="$BATS_TEST_TMPDIR/u1"
    mkdir -p "$dir1/lonely"
    cat > "$dir1/lonely/plugin.toml" <<'EOF'
description = "Lonely"
EOF

    PLUGIN_USER_DIRS=":$dir1::" run discover_plugins
    assert_success
    assert_output "lonely"
}

@test "PLUGIN_USER_DIR singular form still works when PLUGIN_USER_DIRS unset" {
    # Backward compatibility — every existing test (and every existing
    # consumer) sets only PLUGIN_USER_DIR. Make sure we don't break it.
    mkdir -p "$PLUGIN_USER_DIR/legacy"
    cat > "$PLUGIN_USER_DIR/legacy/plugin.toml" <<'EOF'
description = "Legacy via singular var"
EOF

    unset PLUGIN_USER_DIRS
    run discover_plugins
    assert_success
    assert_output "legacy"
}
