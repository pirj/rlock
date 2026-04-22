#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

vm_name=$(resolve_vm_name) || die "No airlock found in this directory"

if ! is_vm_running "$vm_name"; then
    info "Starting stopped VM..."
    aq start "$vm_name"
    if ! wait_for_ssh "$vm_name" 60; then
        die "SSH connection timed out"
    fi
fi

port=$(get_ssh_port "$vm_name")
ssh -t -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "$port" ai@localhost "cd ~/repo && tmux new-session -A -s rl"
