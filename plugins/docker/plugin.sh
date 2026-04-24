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

    # Separate commands by type:
    # 1. apk add — install system packages first (needed for compiling runtimes)
    # 2. mise use — install runtimes (may compile from source, needs build deps)
    # 3. export — env vars for rlock's profile
    # 4. everything else — run in order
    local apk_commands=""
    local mise_commands=""
    local env_exports=""
    local other_commands=""

    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        if [[ "$cmd" == "apk add"* ]]; then
            apk_commands="${apk_commands:+$apk_commands
}$cmd"
        elif [[ "$cmd" == "mise use"* ]]; then
            mise_commands="${mise_commands:+$mise_commands
}$cmd"
        elif [[ "$cmd" == export* ]]; then
            env_exports="${env_exports:+$env_exports
}$cmd"
        else
            other_commands="${other_commands:+$other_commands
}$cmd"
        fi
    done <<< "$script"

    # 1. System packages (as root)
    if [[ -n "$apk_commands" ]]; then
        info "Installing system packages..."
        echo "$apk_commands" | aq exec "$vm" sh -s
    fi

    # 2. Runtimes via mise (as rlock — mise is user-scoped)
    if [[ -n "$mise_commands" ]]; then
        info "Installing runtimes via mise..."
        echo "$mise_commands" | aq exec "$vm" su -l rlock -c 'sh -s'
    fi

    # 3. Env exports → rlock's profile
    if [[ -n "$env_exports" ]]; then
        echo "$env_exports" | aq exec "$vm" sh -c 'cat >> /home/rlock/.profile'
    fi

    # 4. Other commands (as root — may include service setup, bundle install, etc.)
    if [[ -n "$other_commands" ]]; then
        info "Running setup commands..."
        echo "$other_commands" | aq exec "$vm" sh -s
    fi
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
