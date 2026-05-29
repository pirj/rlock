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

# resolve_vm_name -- delegates to plugin resolve_vm hooks first, then
# falls back to .rl/vm-name and finally to directory-derived name.
# Plugins are queried in REVERSE dep order (most specific last).
resolve_vm_name() {
    # First: ask plugins via resolve_vm hook
    if command -v get_active_plugins > /dev/null 2>&1 && \
       command -v run_hook > /dev/null 2>&1; then
        local plugin
        local -a plugins
        mapfile -t plugins < <(get_active_plugins)
        # Iterate in reverse so the most recently added plugin wins
        local i
        for (( i=${#plugins[@]}-1; i>=0; i-- )); do
            plugin="${plugins[$i]}"
            [[ -n "$plugin" ]] || continue
            local result
            result=$(run_hook "$plugin" "resolve_vm" 2>/dev/null) || continue
            if [[ -n "$result" ]]; then
                printf '%s' "$result"
                return 0
            fi
        done
    fi

    # Fallback: saved vm-name
    local saved
    if saved=$(get_saved_vm_name); then
        printf '%s' "$saved"
        return 0
    fi

    # Last resort: directory-derived name if VM exists
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

# Auto-deliver the host's current git HEAD into the VM at /home/rlock/repo.
# Used by cmd_new (post-walk catch-all push) and snapshot_walk_chain
# (during-walk push at the first cache miss boundary so that source-needing
# plugins find files when they build).
#
# Idempotent: setting up the rl-<vm> remote is wrapped in a flock on
# .git/config.lock for concurrent multi-VM `rl new` invocations from the
# same repo. Push itself is safe to run in parallel against different
# remotes — different SSH ports, different destinations.
#
# Silently no-ops when:
#   - cwd isn't inside a git repo, OR
#   - the VM SSH port can't be read (VM not provisioned far enough), OR
#   - the git plugin's snapshot_build hasn't run (no bare-ish repo in VM
#     to receive). In practice this only matters when called before any
#     iteration of the chain walks the git plugin's layer.
git_sync_source_to_vm() {
    local vm="$1"
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0

    local port
    port=$(get_ssh_port "$vm" 2>/dev/null) || {
        warn "git_sync_source_to_vm: SSH port unknown for $vm — skipping"
        return 0
    }

    local remote_name="rl-$vm"
    local remote_url="ssh://rlock@localhost:$port/home/rlock/repo"

    # Idempotent remote setup, flock-protected.
    # NB: .git/config.lock is git's own lockfile — taking it ourselves
    # would race with git's internal operations. Use a separate path.
    (
        flock 9
        git -C "$git_root" remote remove "$remote_name" 2>/dev/null || :
        git -C "$git_root" remote add "$remote_name" "$remote_url"
    ) 9>"$git_root/.git/snapcompose-remote.lock"

    info "Pushing HEAD into VM '$vm'..."
    # --receive-pack: SSH non-interactive sessions for the rlock user in
    # Alpine guests don't have /usr/bin on PATH, so a bare `git push`
    # over SSH fails with "bash: git-receive-pack: command not found".
    # Spelling the absolute path bypasses the PATH lookup. Surface
    # stderr so failures are visible — they cascade into the next
    # plugin's snapshot_build cd'ing into a directory the push was
    # supposed to deliver.
    if ! GIT_SSH_COMMAND="ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $port" \
            git -C "$git_root" push -f \
                --receive-pack=/usr/bin/git-receive-pack \
                "$remote_name" HEAD:refs/heads/main 2>&1; then
        warn "git push to VM failed — proceeding with whatever code is in the VM"
    fi
}
