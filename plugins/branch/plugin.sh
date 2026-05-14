#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

BRANCH_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BRANCH_PLUGIN_DIR/lib.sh"

# Resolve the active VM from the current git branch.
# Empty output means: no opinion, let other resolvers handle it.
resolve_vm() {
    git rev-parse --is-inside-work-tree > /dev/null 2>&1 || return 0
    _branch_vm_name 2>/dev/null || true
}

# Snapshot layer identity = sanitized-branch@base-sha.
snapshot_key() {
    _branch_vm_name 2>/dev/null
}

# Snapshot layer build = set hostname + push current branch into the guest repo.
# qcow2 mechanics (rebase, save) are the framework's responsibility.
snapshot_build() {
    local vm="$1"
    local branch hostname
    branch=$(_branch_current) || return 0
    [[ -n "$branch" ]] || return 0
    hostname=$(_branch_sanitize "$branch")
    aq exec "$vm" sh -c "hostname '$hostname' && echo '$hostname' > /etc/hostname" || true

    # Push code via host-as-remote pattern.
    if git remote get-url rl > /dev/null 2>&1; then
        git remote remove rl
    fi
    local port
    port=$(get_ssh_port "$vm")
    git remote add rl "ssh://rlock@localhost:$port/home/rlock/repo"
    git config core.sshCommand "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p $port"
    git push rl "$branch" >/dev/null 2>&1 || warn "Push failed — try manually: git push rl $branch"
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
