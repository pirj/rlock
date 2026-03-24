# util.sh -- Shared utilities: dependency checks, error handling, .rl/ state management
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires ui.sh to be sourced first (for $RED, $RESET color variables).

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

check_all_deps() {
    check_dependency "aq" "brew install pirj/tap/aq"
    check_dependency "qemu-system-aarch64" "brew install qemu"
    check_dependency "git" "brew install git"
    check_dependency "ssh" "Install OpenSSH"
    check_dependency "tmux" "brew install tmux"
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
