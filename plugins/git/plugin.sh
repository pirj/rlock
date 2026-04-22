#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

provision() {
    local vm="$1"
    aq exec "$vm" sh <<'PROVISION'
set -eu
apk add git
su -l ai -c '
    mkdir -p ~/repo
    cd ~/repo
    git init
    git config receive.denyCurrentBranch updateInstead
'
PROVISION
}

start() {
    local vm="$1"
    local port
    port=$(get_ssh_port "$vm")
    local remote_url="ssh://ai@localhost:$port/home/ai/repo"
    local ssh_cmd="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $port"

    echo ""
    info "Git remote command:"
    echo "  git remote add rl $remote_url"
    echo "  git config core.sshCommand \"$ssh_cmd\""
    echo ""

    local answer
    read -rp "Add git remote now? (Y/n) " answer
    if [[ "${answer:-Y}" =~ ^[Yy]$ ]]; then
        git remote add rl "$remote_url" 2>/dev/null || warn "Remote 'rl' already exists"
        git config core.sshCommand "$ssh_cmd"

        # Push current branch if on one
        local branch
        branch=$(git symbolic-ref --short HEAD 2>/dev/null) || true
        if [[ -n "$branch" ]]; then
            spinner_start "Pushing $branch to guest"
            git push rl "$branch" 2>/dev/null
            spinner_stop "Code pushed"
        else
            warn "Detached HEAD — skipping push. Push manually with: git push rl HEAD:main"
        fi
    fi
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
