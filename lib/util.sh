# util.sh -- Shared utilities: dependency checks, error handling, .rl/ state management
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires ui.sh to be sourced first (for $RED, $RESET color variables).

# shellcheck shell=bash

# --- Constants ---

RL_DIR=".rl"
AQ_STATE_DIR="$HOME/.local/share/aq"

# --- Error Handling ---

die() {
    printf '%sError:%s %s\n' "$RED" "$RESET" "$1" >&2
    exit 1
}

# --- Dependency Checking ---

check_dependency() {
    local cmd="$1"
    local hint="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "$cmd not found. Install: $hint"
    fi
}

# --- .rl/ State Management ---

get_vm_name() {
    basename "$(pwd)"
}

get_saved_vm_name() {
    if [ -f "$RL_DIR/vm-name" ]; then
        cat "$RL_DIR/vm-name"
    else
        return 1
    fi
}

# resolve_vm_name -- tries get_saved_vm_name first, then falls back to
# get_vm_name if a matching VM exists in aq state. Handles orphaned VMs
# from failed rl new attempts gracefully.
resolve_vm_name() {
    local saved
    if saved=$(get_saved_vm_name); then
        printf '%s' "$saved"
        return 0
    fi

    # Fallback: check if a VM matching the directory name exists
    local derived
    derived=$(get_vm_name)
    if [ -d "$AQ_STATE_DIR/$derived" ]; then
        printf '%s' "$derived"
        return 0
    fi

    return 1
}

save_vm_name() {
    ensure_rl_dir
    printf '%s' "$1" > "$RL_DIR/vm-name"
}

ensure_rl_dir() {
    mkdir -p "$RL_DIR"
    if [ -f .gitignore ]; then
        grep -qxF '.rl/' .gitignore || echo '.rl/' >> .gitignore
    else
        echo '.rl/' > .gitignore
    fi
}

# --- SSH Port ---

get_ssh_port() {
    local vm_name="$1"
    local port_file="$AQ_STATE_DIR/$vm_name/ssh-port.conf"
    if [ -f "$port_file" ]; then
        cat "$port_file"
    else
        return 1
    fi
}

# --- VM State ---

is_vm_running() {
    local vm_name="$1"
    local pid_file="$AQ_STATE_DIR/$vm_name/process.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    return 1
}

wait_for_ssh() {
    local vm_name="$1"
    local timeout="${2:-60}"
    local elapsed=0

    while [ ! -f "$AQ_STATE_DIR/$vm_name/ssh-port.conf" ] && [ "$elapsed" -lt "$timeout" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "$elapsed" -ge "$timeout" ]; then
        return 1
    fi

    local port
    port=$(get_ssh_port "$vm_name") || return 1

    while [ "$elapsed" -lt "$timeout" ]; do
        if ssh -o ConnectTimeout=2 \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -p "$port" root@localhost true 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# --- Plugin State ---

save_active_plugins() {
    ensure_rl_dir
    printf '%s\n' "$@" > "$RL_DIR/plugins"
}

get_active_plugins() {
    local plugins_file="$RL_DIR/plugins"
    [[ -f "$plugins_file" ]] || return 0
    cat "$plugins_file"
}

# --- Centralized SSH ---

# Run a command in the guest VM via SSH.
# Usage: do_ssh vm_name [command...]
# Without command — interactive shell. With command — exec it via -t.
# Auto-starts stopped VM and waits for SSH.
# Errors out cleanly if the VM does not exist.
do_ssh() {
    local vm_name="${1:-}"
    if [[ -z "$vm_name" ]]; then
        die "do_ssh: vm_name is required"
    fi
    shift

    if [[ ! -d "$AQ_STATE_DIR/$vm_name" ]]; then
        die "VM '$vm_name' not found. Hint: run 'rl branch' to create a VM for the current git branch."
    fi

    if ! is_vm_running "$vm_name"; then
        info "Starting stopped VM..."
        aq start "$vm_name"
        wait_for_ssh "$vm_name" 60 || die "SSH connection timed out"
    fi

    local port
    port=$(get_ssh_port "$vm_name")

    if [[ $# -eq 0 ]]; then
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p "$port" rlock@localhost
    else
        ssh -t -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p "$port" rlock@localhost "$@"
    fi
}
