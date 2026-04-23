#!/usr/bin/env bash
set -euo pipefail

DOCKER_PLUGIN_DIR="${DOCKER_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PKG_MAP_FILE="$DOCKER_PLUGIN_DIR/pkg-map.txt"

# Look up a Debian package name in the mapping file.
# Returns the Alpine equivalent, or the original name if not found.
pkg_map_lookup() {
    local pkg="$1"
    local mapped
    mapped=$(sed -n "s/^${pkg}=//p" "$PKG_MAP_FILE" 2>/dev/null) || true
    if [[ -n "$mapped" ]]; then
        echo "$mapped"
    else
        echo "$pkg"
    fi
}

# Known OS base images (no runtime to install).
_OS_IMAGES="ubuntu debian alpine centos fedora amazonlinux busybox scratch"

# Map Docker image names to mise runtime names.
_image_to_mise_runtime() {
    local image="$1"
    case "$image" in
        ruby)    echo "ruby" ;;
        node)    echo "node" ;;
        python)  echo "python" ;;
        golang)  echo "go" ;;
        go)      echo "go" ;;
        rust)    echo "rust" ;;
        elixir)  echo "elixir" ;;
        *)       echo "" ;;
    esac
}

# Strip known OS/variant suffixes from a Docker tag.
_strip_tag_suffix() {
    local tag="$1"
    echo "$tag" | sed -E 's/-(alpine|slim|bullseye|bookworm|buster|jammy|noble|focal)$//'
}

# Parse a FROM line and emit a mise use command, or nothing.
# Usage: parse_from "FROM image:tag [AS name]"
parse_from() {
    local line="$1"

    # Skip multi-stage: FROM ... AS ...
    if [[ "$line" =~ [Aa][Ss][[:space:]] ]]; then
        return 0
    fi

    # Extract image:tag
    local image_tag
    image_tag=$(echo "$line" | awk '{print $2}')

    local image tag
    if [[ "$image_tag" == *:* ]]; then
        image="${image_tag%%:*}"
        tag="${image_tag#*:}"
    else
        image="$image_tag"
        tag=""
    fi

    # Strip org prefix (e.g., library/ruby → ruby)
    image="${image##*/}"

    # Skip OS base images
    local os
    for os in $_OS_IMAGES; do
        if [[ "$image" == "$os" ]]; then
            return 0
        fi
    done

    # Map to mise runtime
    local runtime
    runtime=$(_image_to_mise_runtime "$image")
    if [[ -z "$runtime" ]]; then
        return 0
    fi

    # Clean up version tag
    local version
    if [[ -n "$tag" ]]; then
        version=$(_strip_tag_suffix "$tag")
    else
        version="latest"
    fi

    echo "mise use ${runtime}@${version}"
}

# Parse a RUN line. If it's a package install, translate to apk add.
# Otherwise, pass through the command as-is.
parse_run() {
    local line="$1"

    # Strip "RUN " prefix
    local cmd="${line#RUN }"

    # Strip "apt-get update && " prefix if present
    cmd=$(echo "$cmd" | sed 's/apt-get update *&& *//g; s/apt update *&& *//g')

    # Detect package install patterns
    local pkg_install_pattern='(apt-get|apt|yum|dnf) install'
    if [[ "$cmd" =~ $pkg_install_pattern ]]; then
        # Extract everything after "install"
        local args="${cmd#*install}"

        # Strip flags and map package names
        local packages=""
        local word
        for word in $args; do
            case "$word" in
                -*) continue ;;
                *)
                    local mapped
                    mapped=$(pkg_map_lookup "$word")
                    packages="$packages $mapped"
                    ;;
            esac
        done

        packages="${packages# }"
        if [[ -n "$packages" ]]; then
            echo "apk add $packages"
        fi
    else
        echo "$cmd"
    fi
}
