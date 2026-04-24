#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

DOCKER_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DOCKER_PLUGIN_DIR
source "$DOCKER_PLUGIN_DIR/parse-dockerfile.sh"
source "$DOCKER_PLUGIN_DIR/parse-compose.sh"

provision() {
    local vm="$1"

    # Parse on the host, where Dockerfile/compose files live.
    local project_dir
    project_dir=$(pwd)

    local script=""

    # Step 1: Translate Dockerfile
    local dockerfile="$project_dir/Dockerfile"
    if [[ -f "$dockerfile" ]]; then
        info "Translating Dockerfile..."
        local commands warnings
        commands=$(translate_dockerfile "$dockerfile" 2>/dev/null) || true
        warnings=$(translate_dockerfile "$dockerfile" 2>&1 1>/dev/null) || true

        if [[ -n "$warnings" ]]; then
            while IFS= read -r w; do
                [[ -n "$w" ]] && warn "$w"
            done <<< "$warnings"
        fi

        if [[ -n "$commands" ]]; then
            script="$commands"
        fi
    fi

    # Step 2: Translate docker-compose.yml
    local composefile=""
    for candidate in "$project_dir/docker-compose.yml" "$project_dir/docker-compose.yaml"; do
        if [[ -f "$candidate" ]]; then
            composefile="$candidate"
            break
        fi
    done

    if [[ -n "$composefile" ]]; then
        info "Translating $(basename "$composefile")..."
        local compose_commands compose_warnings
        compose_commands=$(translate_compose "$composefile" 2>/dev/null) || true
        compose_warnings=$(translate_compose "$composefile" 2>&1 1>/dev/null) || true

        if [[ -n "$compose_warnings" ]]; then
            while IFS= read -r w; do
                [[ -n "$w" ]] && warn "$w"
            done <<< "$compose_warnings"
        fi

        if [[ -n "$compose_commands" ]]; then
            if [[ -n "$script" ]]; then
                script="$script
$compose_commands"
            else
                script="$compose_commands"
            fi
        fi
    fi

    # Step 3: Execute in guest
    if [[ -z "$script" ]]; then
        info "No Docker provisioning needed"
        return 0
    fi

    # Separate env exports (go to rlock's profile) from other commands (run as root)
    local env_exports=""
    local pkg_commands=""

    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        if [[ "$cmd" == export* ]]; then
            if [[ -n "$env_exports" ]]; then
                env_exports="$env_exports
$cmd"
            else
                env_exports="$cmd"
            fi
        else
            if [[ -n "$pkg_commands" ]]; then
                pkg_commands="$pkg_commands
$cmd"
            else
                pkg_commands="$cmd"
            fi
        fi
    done <<< "$script"

    # Execute package/service commands as root
    if [[ -n "$pkg_commands" ]]; then
        echo "$pkg_commands" | aq exec "$vm" sh -s
    fi

    # Add env exports to rlock's profile
    if [[ -n "$env_exports" ]]; then
        echo "$env_exports" | aq exec "$vm" sh -c 'cat >> /home/rlock/.profile'
    fi
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
