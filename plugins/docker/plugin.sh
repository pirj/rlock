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

    # Collect commands from Dockerfile and compose separately
    local dockerfile_commands="" compose_commands_str=""

    # Step 1: Translate Dockerfile
    local dockerfile="$project_dir/Dockerfile"
    if [[ -f "$dockerfile" ]]; then
        info "Translating Dockerfile..."
        local warnings
        dockerfile_commands=$(translate_dockerfile "$dockerfile" 2>/dev/null) || true
        warnings=$(translate_dockerfile "$dockerfile" 2>&1 1>/dev/null) || true
        if [[ -n "$warnings" ]]; then
            while IFS= read -r w; do
                [[ -n "$w" ]] && warn "$w"
            done <<< "$warnings"
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
        local warnings
        compose_commands_str=$(translate_compose "$composefile" 2>/dev/null) || true
        warnings=$(translate_compose "$composefile" 2>&1 1>/dev/null) || true
        if [[ -n "$warnings" ]]; then
            while IFS= read -r w; do
                [[ -n "$w" ]] && warn "$w"
            done <<< "$warnings"
        fi
    fi

    if [[ -z "$dockerfile_commands" && -z "$compose_commands_str" ]]; then
        info "No Docker provisioning needed"
        return 0
    fi

    # Categorize Dockerfile commands:
    # - apk add → run as root (system packages, needed before runtimes)
    # - mise use → run as rlock (user-scoped runtime manager)
    # - export → append to rlock's .profile
    # - everything else → run as rlock (bundle install, mkdir, etc.)
    local apk_commands="" mise_commands="" env_exports="" user_commands=""

    if [[ -n "$dockerfile_commands" ]]; then
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
                user_commands="${user_commands:+$user_commands
}$cmd"
            fi
        done <<< "$dockerfile_commands"
    fi

    # Categorize compose commands: all run as root (service setup)
    local service_commands=""
    if [[ -n "$compose_commands_str" ]]; then
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] || continue
            if [[ "$cmd" == "apk add"* ]]; then
                apk_commands="${apk_commands:+$apk_commands
}$cmd"
            else
                service_commands="${service_commands:+$service_commands
}$cmd"
            fi
        done <<< "$compose_commands_str"
    fi

    # Execute in order:

    # 1. System packages as root (from both Dockerfile and compose)
    if [[ -n "$apk_commands" ]]; then
        info "Installing system packages..."
        echo "$apk_commands" | aq exec "$vm" sh -s
    fi

    # 2. Runtimes via mise (as rlock)
    #    mise compiles runtimes from source — they need headers that
    #    Docker base images include but Alpine doesn't have by default.
    if [[ -n "$mise_commands" ]]; then
        info "Installing mise and build dependencies..."
        aq exec "$vm" apk add mise build-base openssl-dev readline-dev yaml-dev zlib-dev libffi-dev
        # Trust mise config and run as rlock (mise is user-scoped)
        aq exec "$vm" su -l rlock -c 'mise trust ~/mise.toml 2>/dev/null; true'
        info "Installing runtimes via mise..."
        echo "$mise_commands" | aq exec "$vm" su -l rlock -c 'bash -l -s'
    fi

    # 3. Env exports → rlock's .profile
    if [[ -n "$env_exports" ]]; then
        echo "$env_exports" | aq exec "$vm" sh -c 'cat >> /home/rlock/.profile'
    fi

    # 4. Dockerfile RUN commands as rlock (bundle install, etc.)
    if [[ -n "$user_commands" ]]; then
        info "Running Dockerfile commands..."
        echo "$user_commands" | aq exec "$vm" su -l rlock -c 'sh -s'
    fi

    # 5. Compose service setup as root (initdb, rc-service, etc.)
    if [[ -n "$service_commands" ]]; then
        info "Setting up services..."
        echo "$service_commands" | aq exec "$vm" sh -s
    fi
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
