# vm.sh -- VM lifecycle commands (wraps pirj/aq)
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh and ui.sh to be sourced first.

# shellcheck shell=bash

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
    vm_name=$(resolve_vm_name) || die "No airlock for this repo. Run 'rl new' first."

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
    # Detect which agents are available on the host
    detect_host_agents

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
    # If a VM with this name exists but .rl/vm-name does not, it could be
    # from a failed prior rl new in THIS repo (orphaned VM). Offer cleanup.
    if [ -d "$AQ_STATE_DIR/$vm_name" ] && [ ! -f "$RL_DIR/vm-name" ]; then
        die "A VM named '$vm_name' already exists (possibly from a failed 'rl new'). Run 'rl rm' to clean up, then retry."
    elif [ -d "$AQ_STATE_DIR/$vm_name" ]; then
        die "A VM named '$vm_name' already exists (from another repo). Rename this directory to avoid collision."
    fi

    # Ensure Caddy proxy is running (SEC-01)
    spinner_start "Starting API proxy"
    if ! ensure_caddy_running; then
        spinner_stop "Failed"
        die "Failed to start Caddy proxy. Check 'caddy validate --config $CADDY_FILE'."
    fi
    spinner_stop "API proxy ready"

    # Create VM
    spinner_start "Creating VM"
    if ! aq new "$vm_name" 2>/dev/null; then
        spinner_stop "Failed"
        die "Failed to create VM '$vm_name'."
    fi
    spinner_stop "VM created"

    # Save state early so rl rm can always clean up, even if later steps fail
    save_vm_name "$vm_name"

    # Start VM
    spinner_start "Booting VM"
    if ! aq start "$vm_name" 2>/dev/null; then
        spinner_stop "Failed"
        die "Failed to boot VM '$vm_name'. Run 'rl rm' to clean up."
    fi
    spinner_stop "VM booted"

    # Wait for SSH
    spinner_start "Waiting for SSH"
    if ! wait_for_ssh "$vm_name" 60; then
        spinner_stop "Failed"
        die "SSH not available after 60s. VM may have failed to boot. Run 'rl rm' to clean up."
    fi
    spinner_stop "SSH ready"

    # Provision guest (VM-01, SEC-02, SEC-03)
    spinner_start "Provisioning guest"
    local provision_output
    provision_output=$(aq exec "$vm_name" <<'PROVISION'
set -e

# Enable community repository first (sudo, mise live there)
sed -i 's|^#\(.*community\)|\1|' /etc/apk/repositories
apk update

# Base packages
apk add --no-cache tmux git bash curl sudo mise

# Create unprivileged user for agent work (bypassPermissions blocked as root)
adduser -D -s /bin/bash ai
echo "ai ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Set up ai user's home with mise, proxy URLs, and dummy API keys
su - ai -c '
set -e
cat > ~/mise.toml <<MISE
[env]
ANTHROPIC_BASE_URL = "http://10.0.2.2:9110"
OPENAI_BASE_URL = "http://10.0.2.2:9111"
ANTHROPIC_API_KEY = "dummy"
OPENAI_API_KEY = "dummy"
MISE

mise trust ~/mise.toml
echo "eval \"\$(mise activate bash)\"" >> ~/.bashrc
echo "[ -f ~/.bashrc ] && . ~/.bashrc" >> ~/.bash_profile
mkdir -p ~/repo
'

# Allow SSH as ai user (aq sets up root SSH, copy authorized_keys)
mkdir -p /home/ai/.ssh
cp /root/.ssh/authorized_keys /home/ai/.ssh/
chown -R ai:ai /home/ai/.ssh
chmod 700 /home/ai/.ssh
chmod 600 /home/ai/.ssh/authorized_keys

echo "PROVISION_OK"
PROVISION
    )
    if ! echo "$provision_output" | grep -q "PROVISION_OK"; then
        spinner_stop "Failed"
        die "Guest provisioning failed. Run 'rl rm' and 'rl new' to retry."
    fi
    spinner_stop "Guest provisioned"

    # Install agents detected on the host (AGENT-01)
    if [ ${#DETECTED_AGENTS[@]} -gt 0 ]; then
        for agent in "${DETECTED_AGENTS[@]}"; do
            spinner_start "Installing $agent"
            local install_output
            install_output=$(install_agent_in_guest "$vm_name" "$agent")
            if echo "$install_output" | grep -q "AGENT_OK"; then
                spinner_stop "$agent installed"
            else
                spinner_stop "Failed"
                warn "Failed to install $agent. VM is usable without it."
            fi
        done
    fi

    # Final output
    success "Airlock '$vm_name' ready"
    info "Run 'rl code' to connect"
}

cmd_rm() {
    local vm_name
    vm_name=$(resolve_vm_name) || die "No airlock for this repo. Run 'rl new' first."

    if [ -d "$AQ_STATE_DIR/$vm_name" ]; then
        aq rm "$vm_name" || warn "aq rm failed for '$vm_name' -- continuing cleanup"
    else
        warn "VM '$vm_name' not found in aq -- may have been removed externally"
    fi

    rm -rf "$RL_DIR"
    success "Airlock '$vm_name' destroyed"
}
