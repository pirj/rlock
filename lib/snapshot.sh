#!/usr/bin/env bash
set -euo pipefail

# Cache root for snapshot layers. Defaults to ~/.local/share/aq/cache.
# Overridable for tests via RL_CACHE_DIR.
RL_CACHE_DIR="${RL_CACHE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aq/cache}"

# Resolve the cache path for a given (plugin, key) pair.
# Usage: snapshot_cache_path plugin key
snapshot_cache_path() {
    local plugin="$1" key="$2"
    echo "$RL_CACHE_DIR/$plugin/$key/snapshot.qcow2"
}

# If a snapshot exists for (plugin, key), print its path and return 0.
# Otherwise return non-zero with no output.
snapshot_lookup() {
    local plugin="$1" key="$2"
    local p
    p=$(snapshot_cache_path "$plugin" "$key")
    [[ -f "$p" ]] && { echo "$p"; return 0; } || return 1
}

# Print the path of the most recently built snapshot for a plugin
# (any key). Returns non-zero if the plugin has no snapshots.
snapshot_latest() {
    local plugin="$1"
    local dir="$RL_CACHE_DIR/$plugin"
    [[ -d "$dir" ]] || return 1
    local newest
    newest=$(find "$dir" -name snapshot.qcow2 -type f -print 2>/dev/null \
        | xargs -r ls -t 2>/dev/null \
        | head -1)
    [[ -n "$newest" ]] && { echo "$newest"; return 0; } || return 1
}

# Save a VM's current qcow2 disk as a cached layer snapshot.
# Usage: snapshot_save src_qcow2 plugin key parent_plugin parent_key
# parent_plugin / parent_key may be empty strings.
snapshot_save() {
    local src="$1" plugin="$2" key="$3" parent_plugin="${4:-}" parent_key="${5:-}"
    local dir="$RL_CACHE_DIR/$plugin/$key"
    mkdir -p "$dir"
    qemu-img convert -O qcow2 "$src" "$dir/snapshot.qcow2"
    cat > "$dir/meta.json" <<META
{
  "plugin": "$plugin",
  "key": "$key",
  "parent_plugin": "$parent_plugin",
  "parent_key": "$parent_key",
  "built_at": "$(date -u +%FT%TZ)"
}
META
}

# Create a new qcow2 with the given file as its backing.
# Usage: snapshot_rebase output_qcow2 backing_qcow2
snapshot_rebase() {
    local out="$1" backing="$2"
    qemu-img create -f qcow2 -b "$backing" -F qcow2 "$out" >/dev/null
}

# --- VM seam ---
# Thin wrappers around aq / qemu-img so tests can stub them.

snapshot_walk_vm_disk() {
    # Print the path of the current VM disk.
    local vm="$1"
    echo "$AQ_STATE_DIR/$vm/storage.qcow2"
}

snapshot_walk_vm_boot() {
    local vm="$1"
    aq start "$vm" >/dev/null
    wait_for_ssh "$vm" 60 >/dev/null
}

snapshot_walk_vm_stop() {
    local vm="$1"
    aq stop "$vm" >/dev/null 2>&1 || true
}

snapshot_walk_vm_rebase() {
    # Replace VM disk with a new qcow2 backed by the given file.
    local vm="$1" backing="$2"
    local disk
    disk=$(snapshot_walk_vm_disk "$vm")
    rm -f "$disk"
    snapshot_rebase "$disk" "$backing"
}

# Walk the layer chain for an ordered plugin list.
# Usage: snapshot_walk_chain vm plugin1 [plugin2 ...]
# For each plugin with [snapshot]:
#   * cached: lookup by current key; on miss, boot on parent, run snapshot_build, save.
#   * incremental: lookup by current key; on miss, boot on latest-of-plugin (if any),
#                  else parent, run snapshot_build, save under current key.
#   * ephemeral: never cached. Boot on parent, run snapshot_build, do not save.
# Plugins without [snapshot] are skipped here (provision is run elsewhere).
snapshot_walk_chain() {
    local vm="$1"; shift
    local parent_plugin="" parent_key="" parent_path=""

    # Each iteration may rebase the VM disk; the VM must be stopped first.
    snapshot_walk_vm_stop "$vm"

    local plugin strategy key cache_path latest disk
    for plugin in "$@"; do
        plugin_has_snapshot "$plugin" || continue
        strategy=$(plugin_snapshot_strategy "$plugin")
        key=$(run_hook "$plugin" "snapshot_key")

        # Cache hit (cached + incremental only)
        if [[ "$strategy" != "ephemeral" ]] && cache_path=$(snapshot_lookup "$plugin" "$key"); then
            snapshot_walk_vm_rebase "$vm" "$cache_path"
            parent_plugin="$plugin"; parent_key="$key"; parent_path="$cache_path"
            continue
        fi

        # Miss: pick the right backing
        if [[ "$strategy" == "incremental" ]]; then
            if latest=$(snapshot_latest "$plugin" 2>/dev/null); then
                snapshot_walk_vm_rebase "$vm" "$latest"
            elif [[ -n "$parent_path" ]]; then
                snapshot_walk_vm_rebase "$vm" "$parent_path"
            fi
        fi
        # For cached: VM is already on parent's qcow2 (or initial base).
        # For ephemeral: same — run on whatever the VM disk currently is.

        snapshot_walk_vm_boot "$vm"
        run_hook "$plugin" "snapshot_build" "$vm"
        snapshot_walk_vm_stop "$vm"

        if [[ "$strategy" != "ephemeral" ]]; then
            disk=$(snapshot_walk_vm_disk "$vm")
            snapshot_save "$disk" "$plugin" "$key" "$parent_plugin" "$parent_key"
            parent_plugin="$plugin"; parent_key="$key"
            parent_path=$(snapshot_cache_path "$plugin" "$key")
        fi
    done
}

# Remove cached snapshots that are stale.
# Usage: snapshot_prune [--max-age-days=N] [--live path] [--live path ...]
# A snapshot is removed when ALL conditions hold:
#   * its file mtime is older than N days (default 30)
#   * its path is not in the live set
snapshot_prune() {
    local max_age=30
    local -a live=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-age-days=*) max_age="${1#--max-age-days=}"; shift ;;
            --live) shift; live+=("$1"); shift ;;
            *) shift ;;
        esac
    done

    local removed=0 freed_bytes=0
    local snap
    while IFS= read -r snap; do
        # Skip if in live set
        local keep=0 l
        for l in "${live[@]:-}"; do
            [[ "$snap" == "$l" ]] && keep=1 && break
        done
        [[ $keep -eq 1 ]] && continue

        # Skip if recent
        if [[ -n "$(find "$snap" -mtime "-$max_age" -print 2>/dev/null)" ]]; then
            continue
        fi

        local size
        size=$(stat -f%z "$snap" 2>/dev/null || stat -c%s "$snap" 2>/dev/null || echo 0)
        rm -f "$snap" "$(dirname "$snap")/meta.json"
        rmdir "$(dirname "$snap")" 2>/dev/null || true
        removed=$((removed + 1))
        freed_bytes=$((freed_bytes + size))
    done < <(find "$RL_CACHE_DIR" -name snapshot.qcow2 -type f 2>/dev/null)

    if [[ $removed -gt 0 ]]; then
        local mb=$((freed_bytes / 1024 / 1024))
        echo "Pruned $removed stale snapshots (${mb} MB)" > "${RL_CACHE_DIR}/.last-prune.log"
    fi
}
