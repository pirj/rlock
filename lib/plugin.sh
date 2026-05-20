#!/usr/bin/env bash
set -euo pipefail

# Plugin directory paths — overridable for testing.
#
# PLUGIN_CORE_DIR:   framework-shipped plugins (single dir,
#                    rlock/plugins/). Internal — devs editing rlock
#                    itself care; downstream consumers don't.
# RLOCK_PLUGIN_PATH: colon-separated PATH-like list of plugin directories
#                    discoverable to `rl new` / `discover_plugins` /
#                    `plugin_dir`. Default when unset:
#                    ~/.config/rl/plugins. Earlier entries win on name
#                    conflicts (same precedence semantics as shell PATH).
#                    Downstream consumers compose by prepending their
#                    own dirs — e.g. bakeri.sh does
#                    RLOCK_PLUGIN_PATH="$PWD/.bakerish/plugins:$HOME/.config/rl/plugins"
#                    so synthesised per-project plugins are discoverable
#                    without rlock learning the downstream config files.
PLUGIN_CORE_DIR="${PLUGIN_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins" && pwd)}"

# Internal helper: print resolved RLOCK_PLUGIN_PATH entries, one per
# line, in priority order (first wins on name conflicts). Computed at
# call time so tests / consumers can mutate the env between calls.
_rlock_plugin_path() {
    local raw="${RLOCK_PLUGIN_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/rl/plugins}"
    local saved_IFS=$IFS d
    IFS=':'
    for d in $raw; do
        [[ -n "$d" ]] && echo "$d"
    done
    IFS=$saved_IFS
}

# Maximum plugin protocol version supported by this framework.
PLUGIN_PROTOCOL_VERSION="1"

# Print the protocol version declared by a plugin, or "1" if unset.
plugin_protocol_version() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    local v
    v=$(toml_get "$pdir/plugin.toml" "protocol_version")
    echo "${v:-1}"
}

# Verify every named plugin declares a protocol version <= framework's max.
# Prints an error and returns 1 if any plugin requires a newer protocol.
check_protocol_versions() {
    local plugin v
    for plugin in "$@"; do
        v=$(plugin_protocol_version "$plugin")
        if [[ "$v" -gt "$PLUGIN_PROTOCOL_VERSION" ]]; then
            echo "Plugin '$plugin' requires protocol version $v, this framework supports up to $PLUGIN_PROTOCOL_VERSION" >&2
            return 1
        fi
    done
}

# Returns 0 if plugin declares a [snapshot] section, 1 otherwise.
plugin_has_snapshot() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    grep -q '^\[snapshot\]' "$pdir/plugin.toml"
}

# Print the snapshot strategy declared by a plugin.
# Defaults to "cached" when [snapshot] is present but strategy is unset.
# Returns 1 with an error on unknown strategy.
plugin_snapshot_strategy() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    local s
    s=$(toml_get_in_section "$pdir/plugin.toml" "snapshot" "strategy")
    s="${s:-cached}"
    case "$s" in
        cached|incremental) echo "$s" ;;
        *) echo "Plugin '$plugin' declares unknown snapshot strategy '$s'" >&2; return 1 ;;
    esac
}

# Print the snapshot kind declared by a plugin.
# Defaults to "cold" when [snapshot] is present but kind is unset.
# Returns 1 with an error on unknown kind.
# See specs/2026-05-18-snapshot-kind-design.md for the cold/live tradeoff.
plugin_snapshot_kind() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    local k
    k=$(toml_get_in_section "$pdir/plugin.toml" "snapshot" "kind")
    k="${k:-cold}"
    case "$k" in
        cold|live) echo "$k" ;;
        *) echo "Plugin '$plugin' declares unknown snapshot kind '$k'" >&2; return 1 ;;
    esac
}

# Print the memory requirement (in integer GB) declared by a plugin's
# [snapshot] section, or empty if none. Memory is meaningful chiefly for
# kind = "live" plugins (the snapshot binds RAM size) but a plugin can
# declare it under kind = "cold" too to express a baseline need.
# The framework collects values across active plugins and takes the max
# to pass to `aq new --memory=NG`.
plugin_snapshot_memory() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    local m
    m=$(toml_get_in_section "$pdir/plugin.toml" "snapshot" "memory")
    # Strip an optional trailing G/g so "4G" / "4g" / "4" all yield "4".
    m="${m%[Gg]}"
    if [[ -n "$m" ]]; then
        if ! [[ "$m" =~ ^[1-9][0-9]*$ ]]; then
            echo "Plugin '$plugin' declares invalid snapshot.memory '$m' (expected positive integer)" >&2
            return 1
        fi
        echo "$m"
    fi
}

# Compute the maximum memory (integer GB) declared across the given
# plugin list. Prints the max, or nothing if no plugin declares memory.
# Usage: max_snapshot_memory plugin1 plugin2 ...
max_snapshot_memory() {
    local max=""
    local p m
    for p in "$@"; do
        m=$(plugin_snapshot_memory "$p" 2>/dev/null) || continue
        [[ -n "$m" ]] || continue
        if [[ -z "$max" || "$m" -gt "$max" ]]; then
            max="$m"
        fi
    done
    [[ -n "$max" ]] && echo "$max"
    return 0
}

# Discover all available plugins.
# Prints plugin names (one per line), sorted alphabetically.
# Names starting with an underscore are framework-internal (e.g. `_base`)
# and are hidden from user-facing surfaces — they're auto-included by
# the dispatcher rather than chosen by triggers or CLI args.
discover_plugins() {
    local -a dirs=("$PLUGIN_CORE_DIR")
    local d
    while IFS= read -r d; do dirs+=("$d"); done < <(_rlock_plugin_path)
    local dir plugin_dir_path name
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for plugin_dir_path in "$dir"/*/; do
            [[ -f "${plugin_dir_path}plugin.toml" ]] || continue
            name=$(basename "$plugin_dir_path")
            [[ "$name" == _* ]] && continue
            echo "$name"
        done
    done | sort -u
}

# Get the directory path for a named plugin.
# RLOCK_PLUGIN_PATH entries take precedence over the core dir; within
# RLOCK_PLUGIN_PATH, earlier entries win over later ones.
# Returns 1 if plugin not found.
plugin_dir() {
    local name="$1" dir
    while IFS= read -r dir; do
        if [[ -f "$dir/$name/plugin.toml" ]]; then
            echo "$dir/$name"
            return 0
        fi
    done < <(_rlock_plugin_path)
    if [[ -f "$PLUGIN_CORE_DIR/$name/plugin.toml" ]]; then
        echo "$PLUGIN_CORE_DIR/$name"
        return 0
    fi
    return 1
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

# Returns 0 if a plugin is marked deprecated in its manifest, 1 otherwise.
plugin_is_deprecated() {
    local plugin="$1"
    local pdir
    pdir=$(plugin_dir "$plugin") || return 1
    local v
    v=$(toml_get "$pdir/plugin.toml" "deprecated")
    [[ "$v" == "true" ]]
}

# Detect plugins whose triggers match files in the project directory.
# Usage: detect_triggers project_dir plugin_name1 plugin_name2 ...
# Skips plugins listed in ACTIVATED_PLUGINS env var (space-separated).
# Skips plugins marked `deprecated = true` — they may still be activated
# explicitly by name, but won't be auto-suggested via trigger detection.
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

        # Skip deprecated plugins.
        plugin_is_deprecated "$plugin" && continue

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

# Run a hook on a plugin.
# Usage: run_hook plugin_name hook_name [args...]
# Runs plugin.sh as a subprocess with the hook name as first arg.
# Returns 0 if plugin has no plugin.sh or hook is not defined.
# Returns the hook's exit code otherwise.
run_hook() {
    local plugin="$1" hook="$2"
    shift 2
    local pdir
    pdir=$(plugin_dir "$plugin") || return 0
    local plugin_sh="$pdir/plugin.sh"
    [[ -f "$plugin_sh" ]] || return 0
    RL_LIB_DIR="${RL_LIB_DIR:-$LIB_DIR}" bash "$plugin_sh" "$hook" "$@"
}

# Dispatch a plugin command.
# Usage: dispatch_command command_name [args...]
# Reads ACTIVE_PLUGINS (space-separated) to know which plugins to search.
# Finds the plugin that declares this command and runs its command script.
dispatch_command() {
    local cmd_name="$1"
    shift

    # Two-pass lookup:
    #   Pass 1: ACTIVE_PLUGINS — plugins activated for this project via
    #           `rl new`. A plugin's command may depend on its provision
    #           hook having run, so we prefer the active set first.
    #   Pass 2: All DISCOVERABLE plugins (fallback for "command-only"
    #           plugins like bake-run / bake-cache that have no
    #           [snapshot] section and no provision-time work — they
    #           are safe to invoke regardless of whether they appeared
    #           in the project's active chain).
    # Process substitution is avoided so terminal-dependent commands
    # keep stdin.
    local cmd_script=""
    local plugin pdir commands cmd
    for plugin in ${ACTIVE_PLUGINS:-}; do
        pdir=$(plugin_dir "$plugin") || continue
        commands=$(toml_get_array "$pdir/plugin.toml" "commands")
        for cmd in $commands; do
            if [[ "$cmd" == "$cmd_name" ]]; then
                cmd_script="$pdir/commands/${cmd_name}.sh"
                break 2
            fi
        done
    done

    if [[ -z "$cmd_script" ]]; then
        # Fallback: scan every discoverable plugin. Safe for command-only
        # plugins (no [snapshot], no provision hook needs to have run).
        local all_plugins
        all_plugins=$(discover_plugins)
        for plugin in $all_plugins; do
            # Skip plugins already considered in pass 1.
            case " ${ACTIVE_PLUGINS:-} " in
                *" $plugin "*) continue ;;
            esac
            pdir=$(plugin_dir "$plugin") || continue
            commands=$(toml_get_array "$pdir/plugin.toml" "commands")
            for cmd in $commands; do
                if [[ "$cmd" == "$cmd_name" ]]; then
                    cmd_script="$pdir/commands/${cmd_name}.sh"
                    break 2
                fi
            done
        done
    fi

    if [[ -n "$cmd_script" && -f "$cmd_script" ]]; then
        export RL_LIB_DIR="${RL_LIB_DIR:-$LIB_DIR}"
        exec "$cmd_script" "$@"
    fi

    echo "Unknown command: $cmd_name" >&2
    return 1
}
