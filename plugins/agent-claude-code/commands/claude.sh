#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

vm_name=$(resolve_vm_name) || die "No airlock found in this directory"
do_ssh "$vm_name" "cd ~/repo && tmux new-session -A -s rl 'bash -l -c \"claude --dangerously-skip-permissions\"'"
