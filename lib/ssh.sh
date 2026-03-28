# ssh.sh -- SSH connection and tmux session management
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh and ui.sh to be sourced first.

# shellcheck shell=bash

# --- SSH Connectivity ---

wait_for_ssh() {
    local vm_name="$1"
    local timeout="${2:-60}"
    local elapsed=0

    # Phase 1: Wait for ssh-port.conf to appear
    while [ ! -f "$AQ_STATE_DIR/$vm_name/ssh-port.conf" ] && [ "$elapsed" -lt "$timeout" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "$elapsed" -ge "$timeout" ]; then
        return 1
    fi

    local port
    port=$(get_ssh_port "$vm_name") || return 1

    # Phase 2: Poll SSH connectivity
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

# --- Commands ---

cmd_code() {
    local vm_name
    vm_name=$(resolve_vm_name) || die "No airlock for this repo. Run 'rl new' first."

    if ! [ -d "$AQ_STATE_DIR/$vm_name" ]; then
        die "VM '$vm_name' not found. Run 'rl new' to create."
    fi

    # Auto-start stopped VM (per Open Question 3 recommendation)
    if ! is_vm_running "$vm_name"; then
        info "Starting VM '$vm_name'..."
        aq start "$vm_name" 2>/dev/null || die "Failed to start VM '$vm_name'."
        wait_for_ssh "$vm_name" 60 || die "VM started but SSH not available. Run 'rl status' to check."
    fi

    local ssh_port
    ssh_port=$(get_ssh_port "$vm_name") || die "SSH port not available for '$vm_name'. Try 'rl rm' and 'rl new'."

    # Connect with tmux attach-or-create (D-05, D-06, D-12)
    ssh -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$ssh_port" \
        ai@localhost \
        -t "cd ~/repo 2>/dev/null; tmux new-session -A -s rl" \
      || die "SSH connection failed. Run 'rl status' to check VM state."
}
