# vm.sh -- VM lifecycle commands (wraps pirj/aq)
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh and ui.sh to be sourced first.

# --- VM State ---

is_vm_running() {
    local vm_name="$1"
    local pid_file="$AQ_STATE_DIR/$vm_name/process.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- Commands ---

cmd_status() {
    local vm_name
    vm_name=$(get_saved_vm_name) || die "No airlock for this repo. Run 'rl new' first."

    if ! [ -d "$AQ_STATE_DIR/$vm_name" ]; then
        printf '%s: %snot found%s (VM may have been removed externally)\n' \
            "$vm_name" "$RED" "$RESET"
        return 1
    fi

    if is_vm_running "$vm_name"; then
        local pid ssh_info=""
        pid=$(cat "$AQ_STATE_DIR/$vm_name/process.pid")
        local port
        if port=$(get_ssh_port "$vm_name"); then
            ssh_info=", ssh:$port"
        fi
        printf '%s: %srunning%s (pid %s%s)\n' "$vm_name" "$GREEN" "$RESET" "$pid" "$ssh_info"
    else
        printf '%s: %sstopped%s\n' "$vm_name" "$YELLOW" "$RESET"
    fi
}

cmd_rm() {
    local vm_name
    vm_name=$(get_saved_vm_name) || die "No airlock for this repo. Run 'rl new' first."

    if [ -d "$AQ_STATE_DIR/$vm_name" ]; then
        aq rm "$vm_name" || warn "aq rm failed for '$vm_name' -- continuing cleanup"
    else
        warn "VM '$vm_name' not found in aq -- may have been removed externally"
    fi

    rm -rf "$RL_DIR"
    success "Airlock '$vm_name' destroyed"
}
