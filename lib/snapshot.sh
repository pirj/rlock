#!/usr/bin/env bash
set -euo pipefail

# Cache root for snapshot layers. Defaults to ~/.local/share/aq/cache.
# Overridable for tests via RL_CACHE_DIR.
RL_CACHE_DIR="${RL_CACHE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aq/cache}"

# Resolve the cache path for a given (plugin, key) pair.
# Usage: snapshot_cache_path plugin key
# Returns the path to the cache entry's disk file (disk.qcow2).
# Live entries additionally have memory.bin alongside it.
snapshot_cache_path() {
    local plugin="$1" key="$2"
    echo "$RL_CACHE_DIR/$plugin/$key/disk.qcow2"
}

# If a snapshot exists for (plugin, key), print its disk path and return 0.
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
    newest=$(find "$dir" -name disk.qcow2 -type f -print 2>/dev/null \
        | xargs -r ls -t 2>/dev/null \
        | head -1)
    [[ -n "$newest" ]] && { echo "$newest"; return 0; } || return 1
}

# Read the kind of a cache entry from its meta.json. Returns "cold" if the
# entry has no kind field (back-compat with pre-snapshot-kind entries).
# Usage: snapshot_entry_kind <disk-path>
snapshot_entry_kind() {
    local disk="$1"
    local meta
    meta="$(dirname "$disk")/meta.json"
    [[ -f "$meta" ]] || { echo cold; return 0; }
    local k
    k=$(grep -E '"kind":' "$meta" 2>/dev/null \
        | sed -E 's/.*"kind": "([^"]*)".*/\1/' \
        | head -1)
    echo "${k:-cold}"
}

# Save a VM's current state as a cached layer snapshot.
# Usage: snapshot_save vm plugin key kind parent_plugin parent_key
#
# kind=cold: VM must be stopped. Disk is copied via qemu-img convert.
# kind=live: VM must be running. We shell out to `aq snapshot create` to
#            capture memory + disk via QMP migrate, then move the resulting
#            files into the framework cache directory and delete the aq tag.
#
# parent_plugin / parent_key may be empty strings.
snapshot_save() {
    local vm="$1" plugin="$2" key="$3" kind="$4" parent_plugin="${5:-}" parent_key="${6:-}"
    local dir="$RL_CACHE_DIR/$plugin/$key"
    mkdir -p "$dir"

    case "$kind" in
        cold)
            local src_disk
            src_disk=$(snapshot_walk_vm_disk "$vm")
            qemu-img convert -O qcow2 "$src_disk" "$dir/disk.qcow2"
            ;;
        live)
            # aq snapshot create captures memory + disk while VM is running,
            # writing to ~/.local/share/aq/snapshots/<arch>/<tag>/{disk.qcow2,memory.bin}.
            # We use a unique internal tag, then move the files into the
            # framework cache and clean up the tag.
            local tag="__rl_cache_${plugin}_${key:0:32}_$$"
            aq snapshot create "$vm" "$tag" >/dev/null
            local aq_dir
            aq_dir=$(snapshot_aq_tag_dir "$tag")
            mv "$aq_dir/disk.qcow2" "$dir/disk.qcow2"
            mv "$aq_dir/memory.bin" "$dir/memory.bin"
            aq snapshot rm --force "$tag" >/dev/null 2>&1 || true
            ;;
        *)
            echo "snapshot_save: unknown kind '$kind' (expected cold|live)" >&2
            return 1
            ;;
    esac

    cat > "$dir/meta.json" <<META
{
  "plugin": "$plugin",
  "key": "$key",
  "kind": "$kind",
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

# Resolve the host-side directory where aq stores a snapshot tag's files.
# Overridable via AQ_STATE_DIR + ARCH; tests may stub.
snapshot_aq_tag_dir() {
    local tag="$1"
    local arch="${ARCH:-$(uname -m)}"
    case "$arch" in arm64) arch=aarch64 ;; esac
    echo "$AQ_STATE_DIR/snapshots/$arch/$tag"
}

snapshot_walk_vm_rebase() {
    # Replace VM disk with a new qcow2 backed by the given file.
    #
    # incoming-memory.bin policy:
    #   * If the new layer is kind=live: overwrite incoming-memory.bin
    #     with this layer's memory.bin. A later live layer's memory state
    #     supersedes any earlier one.
    #   * If the new layer is kind=cold: PRESERVE any existing
    #     incoming-memory.bin. A typical chain is live (e.g. docker-
    #     compose warm) followed by cold (mise/ruby-bundler/npm no-op
    #     layers). Their disk overlays add nothing, so the earlier live
    #     layer's memory state is still semantically valid for the
    #     restore. Clearing here would force a fresh cold boot at every
    #     restore even when an upstream live snapshot was available.
    #
    # Stale incoming-memory.bin from a previous `rl new` session is
    # handled by `snapshot_walk_chain` clearing once at the start.
    local vm="$1" backing="$2"
    local disk vm_dir kind cache_dir
    disk=$(snapshot_walk_vm_disk "$vm")
    vm_dir=$(dirname "$disk")
    rm -f "$disk"
    snapshot_rebase "$disk" "$backing"

    kind=$(snapshot_entry_kind "$backing")
    if [[ "$kind" == "live" ]]; then
        cache_dir=$(dirname "$backing")
        rm -f "$vm_dir/incoming-memory.bin"
        if [[ -f "$cache_dir/memory.bin" ]]; then
            cp "$cache_dir/memory.bin" "$vm_dir/incoming-memory.bin"
        fi
    fi
    # kind=cold: leave any existing incoming-memory.bin in place.
}

# Walk the layer chain for an ordered plugin list.
# Usage: snapshot_walk_chain vm plugin1 [plugin2 ...]
#
# Strategy controls cache lookup and miss-time fork-point:
#   * cached:      lookup by current key; miss → boot on parent, build, save.
#   * incremental: lookup by current key; miss → boot on latest-of-plugin
#                  (any key) else parent, build, save under current key.
#   * ephemeral:   never cached. Boot on parent, build, do not save.
#
# Kind controls snapshot capture format (cached / incremental only):
#   * cold: VM stopped, qemu-img convert disk into cache. Restore on next
#           run = qemu-img rebase. No memory captured.
#   * live: VM running, aq snapshot create captures memory + disk via QMP.
#           Restore places memory.bin as incoming-memory.bin so the next
#           `aq start` resumes mid-flight via `-incoming file:...`.
#
# Plugins without [snapshot] are skipped here (provision is run elsewhere).
snapshot_walk_chain() {
    local vm="$1"; shift
    local parent_plugin="" parent_key="" parent_path=""

    # Each iteration may rebase the VM disk; the VM must be stopped first.
    snapshot_walk_vm_stop "$vm"

    # Clear any stale incoming-memory.bin from a prior `rl new` session.
    # Subsequent rebases will only re-create it when restoring a live
    # cache hit (snapshot_walk_vm_rebase handles the per-layer policy).
    local _vm_dir
    _vm_dir=$(dirname "$(snapshot_walk_vm_disk "$vm")")
    rm -f "$_vm_dir/incoming-memory.bin"

    local plugin strategy kind key cache_path latest
    for plugin in "$@"; do
        plugin_has_snapshot "$plugin" || continue
        strategy=$(plugin_snapshot_strategy "$plugin")
        kind=$(plugin_snapshot_kind "$plugin")
        key=$(run_hook "$plugin" "snapshot_key")

        # Cache hit (cached + incremental only)
        if [[ "$strategy" != "ephemeral" ]] && cache_path=$(snapshot_lookup "$plugin" "$key"); then
            snapshot_walk_vm_rebase "$vm" "$cache_path"
            parent_plugin="$plugin"; parent_key="$key"; parent_path="$cache_path"
            continue
        fi

        # Miss: pick the right backing for the build
        if [[ "$strategy" == "incremental" ]]; then
            if latest=$(snapshot_latest "$plugin" 2>/dev/null); then
                snapshot_walk_vm_rebase "$vm" "$latest"
            elif [[ -n "$parent_path" ]]; then
                snapshot_walk_vm_rebase "$vm" "$parent_path"
            fi
        fi
        # For cached: VM is already on parent's qcow2 (rebased on previous
        # iteration's cache hit, or initial backing).
        # For ephemeral: same — run on whatever the VM disk currently is.

        # We're about to boot the VM to run `snapshot_build` on top of the
        # parent's disk state. An earlier live ancestor's memory.bin would
        # cause `-incoming file:` to resume mid-flight; we don't want that
        # during a build (the build expects a clean cold boot at the new
        # disk content). Clear it for this iteration.
        rm -f "$_vm_dir/incoming-memory.bin"

        snapshot_walk_vm_boot "$vm"
        run_hook "$plugin" "snapshot_build" "$vm"

        if [[ "$strategy" == "ephemeral" ]]; then
            # No save, no stop — the layer's effects stay on the VM disk
            # for whatever follows.
            continue
        fi

        if [[ "$kind" == "live" ]]; then
            # Capture while running, then stop so the next iteration's
            # rebase has a clean disk file.
            snapshot_save "$vm" "$plugin" "$key" "live" "$parent_plugin" "$parent_key"
            snapshot_walk_vm_stop "$vm"
        else
            # Cold capture: must stop first so qemu-img convert sees a
            # consistent disk.
            snapshot_walk_vm_stop "$vm"
            snapshot_save "$vm" "$plugin" "$key" "cold" "$parent_plugin" "$parent_key"
        fi

        parent_plugin="$plugin"; parent_key="$key"
        parent_path=$(snapshot_cache_path "$plugin" "$key")
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

        local size mem mem_size
        size=$(stat -f%z "$snap" 2>/dev/null || stat -c%s "$snap" 2>/dev/null || echo 0)
        # If this is a live entry, also drop memory.bin (much bigger than disk).
        mem="$(dirname "$snap")/memory.bin"
        if [[ -f "$mem" ]]; then
            mem_size=$(stat -f%z "$mem" 2>/dev/null || stat -c%s "$mem" 2>/dev/null || echo 0)
            size=$((size + mem_size))
            rm -f "$mem"
        fi
        rm -f "$snap" "$(dirname "$snap")/meta.json"
        rmdir "$(dirname "$snap")" 2>/dev/null || true
        removed=$((removed + 1))
        freed_bytes=$((freed_bytes + size))
    done < <(find "$RL_CACHE_DIR" -name disk.qcow2 -type f 2>/dev/null)

    if [[ $removed -gt 0 ]]; then
        local mb=$((freed_bytes / 1024 / 1024))
        echo "Pruned $removed stale snapshots (${mb} MB)" > "${RL_CACHE_DIR}/.last-prune.log"
    fi
}
