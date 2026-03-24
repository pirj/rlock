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

cmd_new() {
    local vm_name
    vm_name=$(get_vm_name)

    # Check if VM already exists for this repo (D-03)
    if [ -f "$RL_DIR/vm-name" ]; then
        local saved
        saved=$(get_saved_vm_name)
        if [ "$saved" = "$vm_name" ]; then
            die "VM already exists. Use 'rl code' to connect or 'rl rm' to destroy."
        fi
    fi

    # Check cross-repo collision (Pitfall 2)
    if [ -d "$AQ_STATE_DIR/$vm_name" ]; then
        die "A VM named '$vm_name' already exists (from another repo). Rename this directory to avoid collision."
    fi

    # Create VM
    spinner_start "Creating VM"
    if ! aq new "$vm_name" 2>/dev/null; then
        spinner_stop "Failed"
        die "Failed to create VM '$vm_name'."
    fi
    spinner_stop "VM created"

    # Start VM
    spinner_start "Booting VM"
    if ! aq start "$vm_name" 2>/dev/null; then
        spinner_stop "Failed"
        die "Failed to boot VM '$vm_name'."
    fi
    spinner_stop "VM booted"

    # Wait for SSH
    spinner_start "Waiting for SSH"
    if ! wait_for_ssh "$vm_name" 60; then
        spinner_stop "Failed"
        die "SSH not available after 60s. VM may have failed to boot."
    fi
    spinner_stop "SSH ready"

    # Provision guest (VM-01)
    spinner_start "Installing packages"
    local provision_output
    provision_output=$(aq exec "$vm_name" <<'PROVISION'
set -e
apk add --no-cache tmux git
mkdir -p /root/repo
echo "PROVISION_OK"
PROVISION
    )
    if ! echo "$provision_output" | grep -q "PROVISION_OK"; then
        spinner_stop "Failed"
        die "Guest provisioning failed. Try 'rl rm' and 'rl new' again."
    fi
    spinner_stop "Packages installed"

    # Save state
    save_vm_name "$vm_name"

    # Final output
    success "Airlock '$vm_name' ready"
    info "Run 'rl code' to connect"
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
