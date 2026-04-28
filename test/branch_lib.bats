#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_DIR="$PROJECT_ROOT/plugins/branch"
    source "$PLUGIN_DIR/lib.sh"

    # Set up a tiny git repo for tests that need git
    cd "$BATS_TEST_TMPDIR"
    git init -q -b main testrepo
    cd testrepo
    git config user.email test@example.com
    git config user.name test
    echo "init" > a
    git add a
    git -c commit.gpgsign=false commit -qm init
}

@test "_branch_sanitize replaces slashes" {
    run _branch_sanitize "feature/user-auth"
    assert_success
    assert_output "feature_user-auth"
}

@test "_branch_sanitize replaces colons and backslashes" {
    run _branch_sanitize "feat:bar\\baz"
    assert_success
    assert_output "feat_bar_baz"
}

@test "_branch_sanitize keeps safe names" {
    run _branch_sanitize "main"
    assert_success
    assert_output "main"
}

@test "_branch_current returns the current branch" {
    run _branch_current
    assert_success
    assert_output "main"
}

@test "_branch_base_sha returns HEAD on main itself" {
    local head
    head=$(git rev-parse --short=7 HEAD)
    run _branch_base_sha "main"
    assert_success
    assert_output "$head"
}

@test "_branch_base_sha returns merge-base for feature branch" {
    local main_sha
    main_sha=$(git rev-parse --short=7 HEAD)
    git checkout -qb feature
    echo "feature work" > b
    git add b
    git -c commit.gpgsign=false commit -qm "feature commit"
    run _branch_base_sha "feature"
    assert_success
    assert_output "$main_sha"
}

@test "_branch_vm_name combines sanitized branch and base sha" {
    git checkout -qb feature/x
    local main_sha
    main_sha=$(git -c commit.gpgsign=false rev-parse --short=7 main)
    run _branch_vm_name
    assert_success
    assert_output "feature_x@$main_sha"
}

@test "_branch_find_ancestor_snapshot returns nothing if no snapshots" {
    AQ_STATE_DIR="$BATS_TEST_TMPDIR/aqstate" run _branch_find_ancestor_snapshot "abc1234"
    assert_success
    assert_output ""
}

@test "_branch_find_ancestor_snapshot finds matching snapshot" {
    local aq="$BATS_TEST_TMPDIR/aqstate"
    mkdir -p "$aq/main@abc1234"
    touch "$aq/main@abc1234/snapshot.qcow2"
    AQ_STATE_DIR="$aq" run _branch_find_ancestor_snapshot "abc1234"
    assert_success
    assert_output "$aq/main@abc1234/snapshot.qcow2"
}

@test "_branch_find_ancestor_snapshot ignores VMs without snapshot" {
    local aq="$BATS_TEST_TMPDIR/aqstate"
    mkdir -p "$aq/main@abc1234"
    # No snapshot.qcow2
    AQ_STATE_DIR="$aq" run _branch_find_ancestor_snapshot "abc1234"
    assert_success
    assert_output ""
}
