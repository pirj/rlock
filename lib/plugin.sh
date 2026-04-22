#!/usr/bin/env bash
set -euo pipefail

# Plugin directory paths — overridable for testing
PLUGIN_CORE_DIR="${PLUGIN_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins" && pwd)}"
PLUGIN_USER_DIR="${PLUGIN_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/rl/plugins}"

# Discover all available plugins.
# Prints plugin names (one per line), sorted alphabetically.
discover_plugins() {
    local dir plugin_dir_path
    for dir in "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"; do
        [[ -d "$dir" ]] || continue
        for plugin_dir_path in "$dir"/*/; do
            [[ -f "${plugin_dir_path}plugin.toml" ]] || continue
            basename "$plugin_dir_path"
        done
    done | sort -u
}

# Get the directory path for a named plugin.
# User plugins take precedence over core plugins.
# Returns 1 if plugin not found.
plugin_dir() {
    local name="$1"
    if [[ -f "$PLUGIN_USER_DIR/$name/plugin.toml" ]]; then
        echo "$PLUGIN_USER_DIR/$name"
    elif [[ -f "$PLUGIN_CORE_DIR/$name/plugin.toml" ]]; then
        echo "$PLUGIN_CORE_DIR/$name"
    else
        return 1
    fi
}
