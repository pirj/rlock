#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker"
    source "$PLUGIN_DIR/parse-dockerfile.sh"
}

@test "pkg_map_lookup translates known package" {
    run pkg_map_lookup "build-essential"
    assert_success
    assert_output "build-base"
}

@test "pkg_map_lookup passes through unknown package" {
    run pkg_map_lookup "curl"
    assert_success
    assert_output "curl"
}

@test "pkg_map_lookup handles libssl-dev" {
    run pkg_map_lookup "libssl-dev"
    assert_success
    assert_output "openssl-dev"
}
