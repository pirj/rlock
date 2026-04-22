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

# Internal helper: check if a value exists in a space-separated list.
# Usage: _in_list "value" "item1 item2 item3"
_in_list() {
    local needle="$1" haystack="$2"
    local item
    for item in $haystack; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Internal recursive visitor for resolve_deps.
# Uses global variables: _rd_input, _rd_resolved, _rd_visited, _rd_in_stack,
# _rd_notices (for buffered stderr notices), _rd_error (non-empty on failure).
_rd_visit() {
    local plugin="$1"
    local parent="${2:-}"

    if _in_list "$plugin" "$_rd_in_stack"; then
        _rd_error="Circular dependency detected involving '$plugin'"
        return 1
    fi
    _in_list "$plugin" "$_rd_visited" && return 0

    local pdir
    if ! pdir=$(plugin_dir "$plugin"); then
        if [[ -n "$parent" ]]; then
            _rd_error="Plugin '$parent' requires '$plugin', but '$plugin' is not installed"
        else
            _rd_error="Plugin '$plugin' is not installed"
        fi
        return 1
    fi

    _rd_in_stack="$_rd_in_stack $plugin"

    local dep
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        if ! _in_list "$dep" "$_rd_visited"; then
            # Buffer auto-inclusion notice if dep was not explicitly requested
            if ! _in_list "$dep" "$_rd_input"; then
                _rd_notices="$_rd_notices
Including $dep (required by $plugin)"
            fi
        fi
        _rd_visit "$dep" "$plugin" || return 1
    done < <(toml_get_array "$pdir/plugin.toml" "deps")

    # Remove plugin from in_stack (replace with empty to preserve word boundaries)
    _rd_in_stack="${_rd_in_stack/ $plugin/}"
    _rd_visited="$_rd_visited $plugin"
    _rd_resolved="$_rd_resolved $plugin"
}

# Resolve plugin dependencies via depth-first topological sort.
# Usage: resolve_deps plugin1 plugin2 ...
# Prints resolved list (deps first) one per line to stdout.
# Prints auto-inclusion notices to stderr.
# Exits non-zero on circular or missing dependencies.
resolve_deps() {
    # Space-separated strings used as sets (bash 3.2 compatible — no assoc arrays)
    _rd_input=" $* "
    _rd_resolved=""
    _rd_visited=""
    _rd_in_stack=""
    _rd_notices=""
    _rd_error=""

    local plugin rc=0
    for plugin in "$@"; do
        if ! _rd_visit "$plugin" ""; then
            rc=1
            break
        fi
    done

    local name
    for name in $_rd_resolved; do
        echo "$name"
    done

    # Emit buffered notices to stderr after stdout (keeps stdout-only lines ordered)
    if [[ -n "$_rd_notices" ]]; then
        echo "$_rd_notices" >&2
    fi

    # Emit error message to stderr
    if [[ -n "$_rd_error" ]]; then
        echo "$_rd_error" >&2
    fi

    return $rc
}
