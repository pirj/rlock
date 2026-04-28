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

# Set the guest hostname to the sanitized branch name.
provision() {
    local vm="$1"
    local branch
    branch=$(_branch_current) || return 0
    [[ -n "$branch" ]] || return 0
    local hostname
    hostname=$(_branch_sanitize "$branch")
    aq exec "$vm" sh -c "hostname '$hostname' && echo '$hostname' > /etc/hostname" || true
}

# Prune orphan snapshots when removing this branch's VM.
rm() {
    local vm="$1"
    # Conservative pruning: rebuild later when we have data on real chains.
    # For now, just ensure the rm itself succeeds.
    return 0
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
