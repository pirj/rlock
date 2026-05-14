#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_DIR="$PROJECT_ROOT/plugins/branch"
    source "$PLUGIN_DIR/lib.sh"

    cd "$BATS_TEST_TMPDIR"
    git init -q -b main testrepo
    cd testrepo
    git config user.email t@t
    git config user.name t
    echo init > a; git add a
    git -c commit.gpgsign=false commit -qm init
}

@test "branch plugin declares [snapshot] cached strategy in toml" {
    run grep -q '^\[snapshot\]' "$PROJECT_ROOT/plugins/branch/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"cached"' "$PROJECT_ROOT/plugins/branch/plugin.toml"
    assert_success
}

@test "branch snapshot_key returns sanitized@base-sha" {
    git checkout -qb feature/foo
    local sha
    sha=$(git rev-parse --short=7 main)
    run env RL_LIB_DIR="$PROJECT_ROOT/lib" bash "$PROJECT_ROOT/plugins/branch/plugin.sh" snapshot_key
    assert_success
    assert_output "feature_foo@${sha}"
}
