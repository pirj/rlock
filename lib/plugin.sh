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

# Detect plugins whose triggers match files in the project directory.
# Usage: detect_triggers project_dir plugin_name1 plugin_name2 ...
# Skips plugins listed in ACTIVATED_PLUGINS env var (space-separated).
# Prints matched plugin names (one per line).
detect_triggers() {
    local project_dir="$1"
    shift
    local -a available=("$@")

    local plugin
    for plugin in "${available[@]}"; do
        # Skip if already activated
        local skip=0
        local activated
        for activated in ${ACTIVATED_PLUGINS:-}; do
            [[ "$activated" == "$plugin" ]] && skip=1 && break
        done
        [[ $skip -eq 1 ]] && continue

        local pdir
        pdir=$(plugin_dir "$plugin") || continue
        local trigger
        while IFS= read -r trigger; do
            [[ -n "$trigger" ]] || continue
            if [[ -e "$project_dir/$trigger" ]]; then
                echo "$plugin"
                break
            fi
        done < <(toml_get_array "$pdir/plugin.toml" "triggers")
    done
}

# Check that all host dependencies for given plugins are available.
# Usage: check_host_deps plugin1 plugin2 ...
# Exits non-zero with message if any binary is missing.
check_host_deps() {
    local plugin
    for plugin in "$@"; do
        local pdir
        pdir=$(plugin_dir "$plugin") || continue
        local dep
        while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            if ! command -v "$dep" > /dev/null 2>&1; then
                echo "Plugin '$plugin' requires '$dep' on the host" >&2
                return 1
            fi
        done < <(toml_get_array "$pdir/plugin.toml" "host_deps")
    done
}

# Check that no two activated plugins claim the same command.
# Usage: check_command_conflicts plugin1 plugin2 ...
# Exits non-zero with message if a conflict is found.
# Uses a flat "cmd:owner cmd:owner ..." string to track seen commands
# (bash 3.2 compatible — no associative arrays).
check_command_conflicts() {
    local seen_commands=""
    local plugin
    for plugin in "$@"; do
        local pdir
        pdir=$(plugin_dir "$plugin") || continue
        local cmd
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] || continue
            # Check if cmd already recorded: look for "cmd:" prefix in seen_commands
            local owner entry
            for entry in $seen_commands; do
                case "$entry" in
                    "$cmd":*)
                        owner="${entry#*:}"
                        echo "Command '$cmd' claimed by both $owner and $plugin" >&2
                        return 1
                        ;;
                esac
            done
            seen_commands="$seen_commands $cmd:$plugin"
        done < <(toml_get_array "$pdir/plugin.toml" "commands")
    done
}
