#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

BRANCH_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BRANCH_PLUGIN_DIR/lib.sh"

subcommand="${1:-create}"

# --- rl branch rm ---

if [[ "$subcommand" == "rm" ]]; then
    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        die "rl branch requires a git repository"
    fi

    branch=$(_branch_current) || die "Detached HEAD — no branch to remove"
    [[ -n "$branch" ]] || die "Detached HEAD — no branch to remove"

    vm_name=$(_branch_vm_name) || die "Could not determine VM name for branch '$branch'"

    if [[ ! -d "$AQ_STATE_DIR/$vm_name" ]]; then
        die "No VM '$vm_name' to remove"
    fi

    # Run plugin rm hooks in reverse dep order
    mapfile -t plugins < <(get_active_plugins)
    for (( i=${#plugins[@]}-1; i>=0; i-- )); do
        plugin="${plugins[$i]}"
        [[ -n "$plugin" ]] || continue
        run_hook "$plugin" "rm" "$vm_name" || warn "Plugin '$plugin' rm hook failed"
    done

    spinner_start "Destroying VM"
    aq rm "$vm_name" >/dev/null 2>&1 || warn "aq rm failed for '$vm_name'"
    spinner_stop "VM destroyed"

    success "Branch VM '$vm_name' removed"
    exit 0
fi

# --- rl branch (create) ---

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    die "rl branch requires a git repository"
fi

branch=$(_branch_current) || die "Detached HEAD — checkout a named branch first"
[[ -n "$branch" ]] || die "Detached HEAD — checkout a named branch first"

vm_name=$(_branch_vm_name) || die "Could not determine VM name"

if [[ -d "$AQ_STATE_DIR/$vm_name" ]]; then
    die "VM '$vm_name' already exists"
fi

# Look for ancestor snapshot to use as backing
base_sha="${vm_name##*@}"
ancestor_snapshot=$(_branch_find_ancestor_snapshot "$base_sha")

if [[ -n "$ancestor_snapshot" ]]; then
    info "Inheriting from ancestor snapshot: $(basename "$(dirname "$ancestor_snapshot")")"
    spinner_start "Creating VM with backing snapshot"
    mkdir -p "$AQ_STATE_DIR/$vm_name"
    qemu-img create -f qcow2 -b "$ancestor_snapshot" -F qcow2 \
        "$AQ_STATE_DIR/$vm_name/storage.qcow2" >/dev/null
    spinner_stop "VM created (overlay)"
    # NOTE: aq still needs to do its boot setup — but the disk already exists.
    # The cleanest path is: ask base to create a fresh VM and then swap the
    # disk. For v1 we just defer to aq new and overwrite the storage afterwards.
    aq new "$vm_name" >/dev/null
    qemu-img create -f qcow2 -b "$ancestor_snapshot" -F qcow2 \
        "$AQ_STATE_DIR/$vm_name/storage.qcow2" >/dev/null
else
    info "No ancestor snapshot found — creating from base"
    spinner_start "Creating VM"
    aq new "$vm_name" >/dev/null
    spinner_stop "VM created"
fi

# Resize disk and start
qemu-img resize "$AQ_STATE_DIR/$vm_name/storage.qcow2" 4G >/dev/null 2>&1 || true
spinner_start "Booting VM"
aq start "$vm_name" >/dev/null
spinner_stop "VM booted"

spinner_start "Waiting for SSH"
wait_for_ssh "$vm_name" 60 || die "SSH connection timed out"
spinner_stop "SSH ready"

# Run plugin provision and start hooks in dep order
mapfile -t plugins < <(get_active_plugins)
for plugin in "${plugins[@]}"; do
    [[ -n "$plugin" ]] || continue
    spinner_start "Provisioning: $plugin"
    if ! run_hook "$plugin" "provision" "$vm_name"; then
        spinner_stop "FAILED: $plugin"
        die "Plugin '$plugin' provisioning failed."
    fi
    spinner_stop "Provisioned: $plugin"
done

for plugin in "${plugins[@]}"; do
    [[ -n "$plugin" ]] || continue
    run_hook "$plugin" "start" "$vm_name" || true
done

# Push current branch via git plugin's remote
if git remote get-url rl > /dev/null 2>&1; then
    git remote remove rl
fi
port=$(get_ssh_port "$vm_name")
git remote add rl "ssh://rlock@localhost:$port/home/rlock/repo"
git config core.sshCommand "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p $port"
spinner_start "Pushing $branch to guest"
git push rl "$branch" >/dev/null 2>&1 || warn "Push failed — try manually: git push rl $branch"
spinner_stop "Code pushed"

# Stop VM cleanly so the qcow2 is consistent, then snapshot it
spinner_start "Snapshotting clean state"
aq stop "$vm_name" >/dev/null 2>&1 || true
sleep 1
qemu-img convert -O qcow2 "$AQ_STATE_DIR/$vm_name/storage.qcow2" \
    "$AQ_STATE_DIR/$vm_name/snapshot.qcow2" 2>/dev/null \
    || warn "snapshot creation failed — children won't inherit"
aq start "$vm_name" >/dev/null
wait_for_ssh "$vm_name" 60 || warn "VM did not come back up after snapshot"
spinner_stop "Snapshot saved"

success "Branch VM '$vm_name' ready"
