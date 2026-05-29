#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

# Snapshot key = pinned identifier for this installation recipe.
# Bump the suffix when the recipe changes.
snapshot_key() {
    printf 'git-recipe-v1' | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    aq exec "$vm" sh <<'BUILD'
set -eu
apk add git
su -l rlock -c '
    mkdir -p ~/repo
    cd ~/repo
    # -b main pins the initial branch so the framework auto-push
    # (which pushes HEAD:main) matches the current HEAD and the
    # receive.denyCurrentBranch updateInstead hook actually updates
    # the working tree. Without -b main, git init defaults to master
    # (or whichever init.defaultBranch is set globally), and the push
    # to main creates a stale branch with no working-tree update.
    git init -b main
    git config receive.denyCurrentBranch updateInstead
'
BUILD
}

start() {
    local vm="$1"
    # Source delivery is now handled by the framework's auto-push hook
    # in cmd_new (see rlock/bin/rl + git_sync_source_to_vm in lib/util.sh).
    # That path sets up an `rl-<vm>` remote and pushes HEAD non-
    # interactively, both at the first cache-miss boundary in the chain
    # walker and as a catch-all post-walk push for full-warm runs.
    #
    # Print the remote info as a one-line confirmation so users running
    # `rl new` by hand see what was wired up.
    local port
    port=$(get_ssh_port "$vm" 2>/dev/null) || return 0
    info "Git remote 'rl-$vm' → ssh://rlock@localhost:$port/home/rlock/repo"
}

rm() {
    local vm="$1"
    git remote remove rl 2>/dev/null || true
    git config --unset core.sshCommand 2>/dev/null || true
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
