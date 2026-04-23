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
