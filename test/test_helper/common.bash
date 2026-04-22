#!/usr/bin/env bash

_common_setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'

    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LIB_DIR="$PROJECT_ROOT/lib"
}
