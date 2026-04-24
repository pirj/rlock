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

@test "parse_from extracts ruby runtime" {
    run parse_from "FROM ruby:3.2"
    assert_success
    assert_output "mise use ruby@3.2"
}

@test "parse_from strips -alpine suffix" {
    run parse_from "FROM node:18-alpine"
    assert_success
    assert_output "mise use node@18"
}

@test "parse_from strips -slim suffix" {
    run parse_from "FROM python:3.11-slim"
    assert_success
    assert_output "mise use python@3.11"
}

@test "parse_from strips -bullseye suffix" {
    run parse_from "FROM ruby:3.2.1-bullseye"
    assert_success
    assert_output "mise use ruby@3.2.1"
}

@test "parse_from uses latest when no tag" {
    run parse_from "FROM ruby"
    assert_success
    assert_output "mise use ruby@latest"
}

@test "parse_from skips ubuntu base image" {
    run parse_from "FROM ubuntu:22.04"
    assert_success
    assert_output ""
}

@test "parse_from skips debian base image" {
    run parse_from "FROM debian:bookworm"
    assert_success
    assert_output ""
}

@test "parse_from skips alpine base image" {
    run parse_from "FROM alpine:3.21"
    assert_success
    assert_output ""
}

@test "parse_from handles golang image" {
    run parse_from "FROM golang:1.22"
    assert_success
    assert_output "mise use go@1.22"
}

@test "parse_from skips multi-stage FROM AS" {
    run parse_from "FROM ruby:3.2 AS builder"
    assert_success
    assert_output ""
}

@test "parse_run translates apt-get install" {
    run parse_run "RUN apt-get install -y build-essential libpq-dev curl"
    assert_success
    assert_output "apk add build-base libpq-dev curl"
}

@test "parse_run translates apt install" {
    run parse_run "RUN apt install -y git"
    assert_success
    assert_output "apk add git"
}

@test "parse_run translates yum install" {
    run parse_run "RUN yum install -y libssl-dev"
    assert_success
    assert_output "apk add openssl-dev"
}

@test "parse_run translates dnf install" {
    run parse_run "RUN dnf install -y zlib1g-dev"
    assert_success
    assert_output "apk add zlib-dev"
}

@test "parse_run strips --no-install-recommends" {
    run parse_run "RUN apt-get install -y --no-install-recommends curl wget"
    assert_success
    assert_output "apk add curl wget"
}

@test "parse_run passes through non-install commands" {
    run parse_run "RUN echo hello world"
    assert_success
    assert_output "echo hello world"
}

@test "parse_run passes through pip install" {
    run parse_run "RUN pip install flask gunicorn"
    assert_success
    assert_output "pip install flask gunicorn"
}

@test "parse_run strips apt-get update prefix" {
    run parse_run "RUN apt-get update && apt-get install -y curl"
    assert_success
    assert_output "apk add curl"
}

@test "parse_env outputs export" {
    run parse_env "ENV RAILS_ENV=production"
    assert_success
    assert_output 'export RAILS_ENV="production"'
}

@test "parse_env handles space-separated format" {
    run parse_env "ENV RAILS_ENV production"
    assert_success
    assert_output 'export RAILS_ENV="production"'
}

@test "parse_workdir warns and skips" {
    run parse_workdir "WORKDIR /app"
    assert_success
    assert_output --partial "WORKDIR /app skipped"
}

@test "translate_dockerfile handles full Dockerfile" {
    local dockerfile="$BATS_TEST_TMPDIR/Dockerfile"
    cat > "$dockerfile" <<'EOF'
FROM ruby:3.2
RUN apt-get update && apt-get install -y build-essential libpq-dev
ENV RAILS_ENV=production
WORKDIR /app
COPY . .
EXPOSE 3000
RUN bundle install
EOF
    run bash -c "source '$PLUGIN_DIR/parse-dockerfile.sh' && translate_dockerfile '$dockerfile' 2>/dev/null"
    assert_success
    assert_line --index 0 "mise use ruby@3.2"
    assert_line --index 1 "apk add build-base libpq-dev"
    assert_line --index 2 'export RAILS_ENV="production"'
    assert_line --index 3 "bundle install"
}

@test "translate_dockerfile handles continuation lines" {
    local dockerfile="$BATS_TEST_TMPDIR/Dockerfile"
    cat > "$dockerfile" <<'EOF'
FROM node:18
RUN apt-get install -y \
    curl \
    wget
EOF
    run translate_dockerfile "$dockerfile"
    assert_success
    assert_line --index 0 "mise use node@18"
    assert_line --index 1 "apk add curl wget"
}

@test "translate_dockerfile skips comments" {
    local dockerfile="$BATS_TEST_TMPDIR/Dockerfile"
    cat > "$dockerfile" <<'EOF'
# This is a comment
FROM ruby:3.2
# Another comment
RUN echo hello
EOF
    run translate_dockerfile "$dockerfile"
    assert_success
    assert_line --index 0 "mise use ruby@3.2"
    assert_line --index 1 "echo hello"
}
