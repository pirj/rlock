#!/usr/bin/env bash

_common_setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'

    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck disable=SC2034  # consumed by bats tests that source this helper
    LIB_DIR="$PROJECT_ROOT/lib"
}
