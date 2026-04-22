#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    source "$LIB_DIR/toml.sh"

    TEST_TOML="$BATS_TEST_TMPDIR/test.toml"
}

@test "toml_get reads string value" {
    cat > "$TEST_TOML" <<'EOF'
description = "Git gateway"
EOF
    run toml_get "$TEST_TOML" "description"
    assert_success
    assert_output "Git gateway"
}

@test "toml_get returns empty for missing key" {
    cat > "$TEST_TOML" <<'EOF'
description = "Git gateway"
EOF
    run toml_get "$TEST_TOML" "nonexistent"
    assert_success
    assert_output ""
}

@test "toml_get_array reads array values" {
    cat > "$TEST_TOML" <<'EOF'
deps = ["auth-proxy", "git"]
EOF
    run toml_get_array "$TEST_TOML" "deps"
    assert_success
    assert_line --index 0 "auth-proxy"
    assert_line --index 1 "git"
}

@test "toml_get_array returns empty for empty array" {
    cat > "$TEST_TOML" <<'EOF'
deps = []
EOF
    run toml_get_array "$TEST_TOML" "deps"
    assert_success
    assert_output ""
}

@test "toml_get_array returns empty for missing key" {
    cat > "$TEST_TOML" <<'EOF'
description = "something"
EOF
    run toml_get_array "$TEST_TOML" "deps"
    assert_success
    assert_output ""
}

@test "toml_get_array reads single-element array" {
    cat > "$TEST_TOML" <<'EOF'
triggers = [".git"]
EOF
    run toml_get_array "$TEST_TOML" "triggers"
    assert_success
    assert_output ".git"
}
