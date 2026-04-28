#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    source "$LIB_DIR/ui.sh"
    source "$LIB_DIR/util.sh"
}

@test "do_ssh fails when vm_name missing" {
    run do_ssh
    assert_failure
}

@test "do_ssh refuses missing VM" {
    AQ_STATE_DIR="$BATS_TEST_TMPDIR/nonexistent" run do_ssh "ghost-vm"
    assert_failure
    assert_output --partial "not found"
}
