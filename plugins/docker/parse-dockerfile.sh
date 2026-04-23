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
