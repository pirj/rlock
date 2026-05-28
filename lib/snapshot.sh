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

    # Overwrite-safe: remove any prior artifacts at this slot so the new
    # save fully replaces them. Important for `rl warm rebuild`, which
    # promotes the running VM into an existing cache entry (potentially
    # changing kind cold→live or vice versa — the stale memory.bin from
    # a previous live capture would mislead rebase if left in place).
    rm -f "$dir/disk.qcow2" "$dir/memory.bin" "$dir/memory.bin.zst" "$dir/memory.bin.zstpatch" "$dir/memory.format" "$dir/meta.json"

    case "$kind" in
        cold)
            local src_disk
            src_disk=$(snapshot_walk_vm_disk "$vm")
            qemu-img convert -O qcow2 "$src_disk" "$dir/disk.qcow2"
            ;;
        live)
            # aq snapshot create captures memory + disk while VM is running,
            # writing to ~/.local/share/aq/snapshots/<arch>/<tag>/{disk.qcow2,
            # memory.bin[.zst]}. We use a unique internal tag, then move
            # the files into the framework cache and clean up the tag.
            # aq compresses memory.bin to memory.bin.zst when zstd is on
            # the host; whichever form aq produced we move as-is — both
            # are recognised by snapshot_walk_vm_rebase on restore.
            local tag="__rl_cache_${plugin}_${key:0:32}_$$"

            # B5 opt-in: when the user runs with AQ_MEMORY_SNAPSHOT=zstd-patch
            # and the parent layer is also a live entry with memory state,
            # pass the parent's memory.bin.zst path to aq via
            # AQ_PARENT_MEMORY_ZST so aq emits a zstd --patch-from delta
            # instead of a full compression. ~95% disk saving when most
            # memory pages are unchanged across layers (typical for plugin
            # chains that extend an already-running stack). Restore is
            # single-thread chain reconstruction (see _snapshot_reconstruct_memory_chain
            # below) — slower than direct decompression, but acceptable
            # when disk is the binding constraint (CI cache pushes, OCI
            # transport).
            #
            # First live layer of the chain (parent is cold, no memory.bin.zst)
            # has nothing to patch against. Downgrade transparently to plain
            # `zstd` for that one layer so the chain still builds; subsequent
            # live layers patch against this base. aq's strict mode errors
            # if zstd-patch is set but no parent reference is provided, so we
            # explicitly override the env var here instead of leaving the
            # user's setting visible.
            local _save_env=(env)
            if [[ "${AQ_MEMORY_SNAPSHOT:-}" == "zstd-patch" ]]; then
                # Walk back through the ancestor chain to find the most
                # recent layer with a FULL memory.bin.zst (not .zstpatch).
                # That becomes the patch base for the layer we're about
                # to save. Every patch in the chain references the same
                # full ancestor, so a chain of N patch layers means
                # N decompress+apply cycles at restore — but only ONE
                # full memory.bin.zst stored. The alternative — patch
                # against the immediate ancestor regardless of its
                # format — would require either keeping the parent's
                # raw memory hot across saves (extra disk + plumbing)
                # or recursive reconstruction at every save (expensive).
                # Anchoring patches to the most recent full ancestor
                # is simpler and gives most of the disk benefit for
                # the shallow chains B5 targets (2–4 live layers).
                local _wp="$parent_plugin" _wk="$parent_key" _parent_mem=""
                while [[ -n "$_wp" && -n "$_wk" ]]; do
                    local _cand="$RL_CACHE_DIR/$_wp/$_wk/memory.bin.zst"
                    if [[ -f "$_cand" ]]; then _parent_mem="$_cand"; break; fi
                    local _meta="$RL_CACHE_DIR/$_wp/$_wk/meta.json"
                    [[ -f "$_meta" ]] || break
                    local _np _nk
                    _np=$(grep -o '"parent_plugin"[[:space:]]*:[[:space:]]*"[^"]*"' "$_meta" | sed 's/.*"\([^"]*\)"$/\1/')
                    _nk=$(grep -o '"parent_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$_meta" | sed 's/.*"\([^"]*\)"$/\1/')
                    _wp="$_np"; _wk="$_nk"
                done
                if [[ -n "$_parent_mem" ]]; then
                    _save_env+=("AQ_PARENT_MEMORY_ZST=$_parent_mem" "AQ_MEMORY_SNAPSHOT=zstd-patch")
                else
                    # No full-memory ancestor (we're the first live layer
                    # of the chain). Force plain zstd so this layer
                    # becomes the anchor that future patch siblings
                    # reference.
                    _save_env+=("AQ_MEMORY_SNAPSHOT=zstd")
                fi
            fi

            "${_save_env[@]}" aq snapshot create "$vm" "$tag" >/dev/null
            local aq_dir
            aq_dir=$(snapshot_aq_tag_dir "$tag")
            mv "$aq_dir/disk.qcow2" "$dir/disk.qcow2"
            if [[ -f "$aq_dir/memory.bin.zstpatch" ]]; then
                mv "$aq_dir/memory.bin.zstpatch" "$dir/memory.bin.zstpatch"
                mv "$aq_dir/memory.format" "$dir/memory.format" 2>/dev/null || true
            elif [[ -f "$aq_dir/memory.bin.zst" ]]; then
                mv "$aq_dir/memory.bin.zst" "$dir/memory.bin.zst"
            elif [[ -f "$aq_dir/memory.bin" ]]; then
                mv "$aq_dir/memory.bin" "$dir/memory.bin"
            fi
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

# Read meta.json for a cache entry and print the parent's full cache path
# (or empty if no parent / parent missing). Used by patch-chain restore.
_snapshot_parent_dir() {
    local cache_dir="$1"
    local meta="$cache_dir/meta.json"
    [[ -f "$meta" ]] || { echo ""; return; }
    local pp pk
    pp=$(grep -o '"parent_plugin"[[:space:]]*:[[:space:]]*"[^"]*"' "$meta" | sed 's/.*"\([^"]*\)"$/\1/')
    pk=$(grep -o '"parent_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$meta" | sed 's/.*"\([^"]*\)"$/\1/')
    if [[ -n "$pp" && -n "$pk" ]]; then
        echo "$RL_CACHE_DIR/$pp/$pk"
    fi
}

# Reconstruct a leaf live layer's raw memory.bin via patch chain.
# Walks back from leaf via meta.json's parent_plugin/parent_key fields
# until it finds an ancestor stored as full memory.bin.zst (the "base"
# of the chain).
#
# Each patch was encoded by the save side against the most-recent full
# ancestor's raw memory (see snapshot_save's "_wp/_wk while loop"
# above). So restore applies the LEAF's patch directly against the
# chain base — intermediate .zstpatch layers in the chain are
# *bypassed*; they exist only so the next sibling layer can walk back
# to the base. Their disk content (the next layer's qcow2 backing) is
# still consumed by the disk-rebase path; only the memory.bin layer
# uses this single-step direct-to-base application.
#
# Returns 1 if any link in the chain is missing or the decode fails.
_snapshot_reconstruct_memory_chain() {
    local leaf_cache_dir="$1" out_raw="$2"
    # Walk back to the chain base (most-recent ancestor with full
    # memory.bin.zst). We don't accumulate intermediate links into a
    # chain array — we apply the LEAF's patch directly against the
    # base, matching how the encoder produced it.
    local base="$leaf_cache_dir"
    while [[ -f "$base/memory.bin.zstpatch" && ! -f "$base/memory.bin.zst" ]]; do
        local parent
        parent=$(_snapshot_parent_dir "$base")
        if [[ -z "$parent" || ! -d "$parent" ]]; then
            echo "  ERROR: patch chain broken at $base — no parent cache entry" >&2
            return 1
        fi
        base="$parent"
    done

    if [[ ! -f "$base/memory.bin.zst" ]]; then
        echo "  ERROR: chain base $base lacks memory.bin.zst" >&2
        return 1
    fi

    echo "  reconstructing memory chain: base=$(basename "$(dirname "$base")")/$(basename "$base") -> leaf=$(basename "$(dirname "$leaf_cache_dir")")/$(basename "$leaf_cache_dir")" >&2

    # Decompress the chain base into a working raw file. Single-thread
    # `zstd -dc` rather than `pzstd -dc` even when pzstd is available:
    # the resulting bytes are the patch-from reference, and the patches
    # were created against a reference produced by single-thread zstd
    # (see aq's snapshot-create patch path). Using pzstd here would
    # decompress in parallel, which has been observed to produce a
    # reference whose downstream patch-apply trips zstd error 36
    # "Restored data doesn't match checksum" on ubuntu-latest CI
    # (benchmark-r17-r18 r18 cold path, 2026-05-27). Spend the ~1 s
    # extra wall-clock to keep the encode/decode reference byte-identical.
    zstd -dc "$base/memory.bin.zst" > "$out_raw"
    # DIAG: sha256 of chain-base raw, matches aq's encode-side PATCH_DIAG
    # in the log when patch round-trip succeeds. Divergence here would
    # prove `zstd -dc` isn't deterministic for our inputs.
    if command -v sha256sum >/dev/null 2>&1; then
        echo "  PATCH_DIAG decode-ref sha256=$(sha256sum "$out_raw" | cut -d' ' -f1)  bytes=$(stat -c %s "$out_raw" 2>/dev/null || stat -f %z "$out_raw")" >&2
    fi

    # Apply the LEAF's patch directly against the chain base. Skipping
    # intermediate .zstpatch layers is correct: each was encoded against
    # the same full ancestor (the encoder also walks back to the most-
    # recent full ancestor), so each one's content is a delta from
    # base.raw to that layer's snapshotted memory. We only need the
    # LEAF's patch to reconstruct the leaf's memory.
    #
    # --long=31 matches the encoder's 2 GiB window setting (see aq's
    # `Live snapshot: computing memory delta` block) — without it
    # zstd refuses to decode any frame whose window exceeds the
    # default 128 MiB cap. The function is called from inside an
    # `if` in snapshot_walk_vm_rebase, which disables `set -e` for
    # the body — so we have to check the zstd exit explicitly and
    # return 1 on failure, otherwise an empty raw file gets staged
    # and the next aq start tries to migrate from a 0-byte memory.bin.
    if [[ "$leaf_cache_dir" != "$base" ]]; then
        local leaf_patch="$leaf_cache_dir/memory.bin.zstpatch"
        if [[ ! -f "$leaf_patch" ]]; then
            echo "  ERROR: leaf $leaf_cache_dir has no memory.bin.zstpatch" >&2
            return 1
        fi
        local tmp_next
        tmp_next=$(mktemp -t aq-patch-tmp-XXXXXX)
        if ! zstd -dc --long=31 --patch-from="$out_raw" "$leaf_patch" > "$tmp_next"; then
            echo "  ERROR: leaf patch apply failed at $leaf_cache_dir" >&2
            rm -f "$tmp_next"
            return 1
        fi
        mv "$tmp_next" "$out_raw"
    fi
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
    echo "  rebase: backing=$backing kind=$kind" >&2
    if [[ "$kind" == "live" ]]; then
        cache_dir=$(dirname "$backing")
        # Always clear BOTH forms so a previous layer's incoming doesn't
        # bleed through. aq's start path picks whichever form is staged.
        rm -f "$vm_dir/incoming-memory.bin" "$vm_dir/incoming-memory.bin.zst"
        # B5: when the leaf layer is a patch (memory.bin.zstpatch),
        # reconstruct the raw memory by walking the parent chain and
        # applying patches forward. aq's start path sees a plain
        # incoming-memory.bin and uses `-incoming file:` (no further
        # decompression). This adds reconstruction cost to every restore
        # of a patch leaf but saves disk on the cached chain itself.
        if [[ -f "$cache_dir/memory.bin.zstpatch" && ! -f "$cache_dir/memory.bin.zst" ]]; then
            echo "  reconstructing patch chain into incoming-memory.bin..." >&2
            if _snapshot_reconstruct_memory_chain "$cache_dir" "$vm_dir/incoming-memory.bin"; then
                echo "  staged (patch-chain): $cache_dir -> $vm_dir/incoming-memory.bin ($(stat -c%s "$vm_dir/incoming-memory.bin" 2>/dev/null) B)" >&2
            else
                echo "  ERROR: patch-chain reconstruction failed; restore will fall back to cold boot" >&2
                rm -f "$vm_dir/incoming-memory.bin"
            fi
            return
        fi

        local src dst
        if [[ -f "$cache_dir/memory.bin.zst" ]]; then
            src="$cache_dir/memory.bin.zst"
            dst="$vm_dir/incoming-memory.bin.zst"
        elif [[ -f "$cache_dir/memory.bin" ]]; then
            src="$cache_dir/memory.bin"
            dst="$vm_dir/incoming-memory.bin"
        else
            echo "  WARN: kind=live but no memory.bin[.zst] in $cache_dir" >&2
            return
        fi

        # Hardlink first — zero-copy stage when cache and vm_dir share
        # a filesystem (which is normal: both under $HOME/.local/share/aq).
        # qemu reads the file once and `rm`s the staged path after
        # migration completes; with a hardlink that just drops one
        # of two refcounts to the cache file's inode, the cache
        # remains intact. Falls back to cp on cross-fs / hardlink-
        # disallowed setups.
        if ln "$src" "$dst" 2>/dev/null; then
            echo "  staged (hardlink): $src -> $dst ($(stat -c%s "$dst" 2>/dev/null) B)" >&2
        else
            cp "$src" "$dst"
            echo "  staged (cp): $src -> $dst ($(stat -c%s "$dst" 2>/dev/null) B)" >&2
        fi
    fi
    # kind=cold: leave any existing incoming-memory.bin / .zst in place.
}

# Walk the layer chain for an ordered plugin list.
# Usage: snapshot_walk_chain vm plugin1 [plugin2 ...]
#
# Strategy controls cache lookup and miss-time fork-point:
#   * cached:      lookup by current key; miss → boot on parent, build, save.
#   * incremental: lookup by current key; miss → boot on latest-of-plugin
#                  (any key) else parent, build, save under current key.
#
# Kind controls snapshot capture format:
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

    # Pre-slurp every discoverable plugin's plugin.toml into the
    # in-process TOML cache + plugin-dir cache. The loop below dispatches
    # 4-6 toml lookups per plugin via subshells; without prefetch each
    # one forks sed/awk on the same files. ~50-80 ms save on warm
    # rails-pg-sample. See C9 in rlock/TODO.md.
    plugin_meta_prefetch

    # Once any layer in the chain (cache-hit or freshly-built) is live,
    # ALL subsequent layers are force-promoted to live. Building a cold
    # layer on top of a live ancestor requires a cold-reboot of the VM
    # for snapshot_build, which loses any ambient services started by
    # the live ancestor (running postgres, warm dockerd, redis page
    # cache, ...) — and worse, side effects of that cold boot (rc-update
    # auto-starting services to a different on-disk state) create a
    # memory↔disk inconsistency at the final live restore. Promotion
    # keeps the VM live-restored throughout the chain so each layer's
    # build sees the cumulative running state and captures it. Storage
    # cost is bounded by TTL-based GC and the opt-in zstd --patch-from
    # mode (see aq's ROADMAP).
    local chain_has_live=0

    # Each iteration may rebase the VM disk; the VM must be stopped first.
    snapshot_walk_vm_stop "$vm"

    # Clear any stale incoming-memory.bin[.zst] from a prior `rl new`
    # session. Subsequent rebases will only re-create one when restoring
    # a live cache hit (snapshot_walk_vm_rebase handles the per-layer
    # policy and picks the .zst form when present).
    local _vm_dir
    _vm_dir=$(dirname "$(snapshot_walk_vm_disk "$vm")")
    rm -f "$_vm_dir/incoming-memory.bin" "$_vm_dir/incoming-memory.bin.zst"

    # Coalesce consecutive cache-hit rebases. Each cached snapshot is a
    # standalone qcow2 (saved via `qemu-img convert` without `-B`), so a
    # rebase to layer N has all of L1…N's content baked in regardless of
    # whether we rebased to the intermediate layers first. For warm paths
    # with N=4 cache hits, this collapses 4 rebases + 4 memory-dump
    # potential cps into 1 — measurable on the rails-pg-sample fixture
    # (saved ~0.5 s per intermediate hit, plus avoids unnecessary
    # memory.bin.zst staging on non-tail live layers).
    #
    # The pending rebase is flushed before any miss (both cached and
    # incremental need storage.qcow2 to be on the actual parent's qcow2
    # before the build runs) and at the chain end.
    local pending_path=""

    local plugin strategy kind key cache_path latest
    for plugin in "$@"; do
        plugin_has_snapshot "$plugin" || continue

        # Per-iteration short-circuit. Plugins can declare a
        # `snapshot_should_skip` hook that prints the literal string
        # "skip" to signal "nothing to do for this project — don't
        # participate in the chain". Saves the rebase + aq start +
        # wait_for_ssh + aq stop cycle (~5-7 s) per no-op layer.
        #
        # Stdout-based signalling (not exit code) because the framework's
        # plugin dispatch falls through to exit 0 when the hook isn't
        # defined — an exit-code protocol would mistake "hook absent"
        # for "skip".
        if [[ "$(run_hook "$plugin" "snapshot_should_skip" 2>/dev/null)" == "skip" ]]; then
            continue
        fi

        strategy=$(plugin_snapshot_strategy "$plugin")
        kind=$(plugin_snapshot_kind "$plugin")
        key=$(run_hook "$plugin" "snapshot_key")

        # Promote to live once the chain has gone live.
        if [[ $chain_has_live -eq 1 ]]; then
            kind="live"
        fi

        # Cache lookup. We treat a cold-kind cache hit as STALE when the
        # chain has already gone live — the cold entry's recipe ran on
        # a cold-booted VM in some previous walk, and its disk state
        # reflects services restarted by rc-update during that boot.
        # Restoring our cumulative live memory on top of that disk is
        # exactly the inconsistency live-promotion exists to avoid.
        # Fall through to the miss path to rebuild as live.
        if cache_path=$(snapshot_lookup "$plugin" "$key"); then
            local cached_kind
            cached_kind=$(snapshot_entry_kind "$cache_path")
            if [[ $chain_has_live -eq 1 && "$cached_kind" == "cold" ]]; then
                : # fall through to miss
            else
                # Defer the rebase — a subsequent consecutive hit will replace
                # this pending path; only the final hit (or pre-miss flush)
                # actually materialises in qemu-img + memory-dump cp work.
                snapshot_stats_record_hit "$plugin"
                pending_path="$cache_path"
                parent_plugin="$plugin"; parent_key="$key"; parent_path="$cache_path"
                # Sticky live: a cached live entry means everything downstream
                # builds on its running state.
                if [[ "$cached_kind" == "live" ]]; then
                    chain_has_live=1
                fi
                continue
            fi
        fi

        # Miss path begins. Materialise any deferred cache-hit rebase
        # first so storage.qcow2's backing is the actual chain parent
        # before the build runs.
        if [[ -n "$pending_path" ]]; then
            snapshot_walk_vm_rebase "$vm" "$pending_path"
            pending_path=""
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

        # We're about to boot the VM to run `snapshot_build` on top of
        # the parent's disk state.
        #
        # Before live-promotion: we cleared incoming-memory.bin so the
        # build would cold-boot cleanly at the new disk content. That
        # turned out to be exactly the source of memory↔disk drift —
        # cold-booting a VM whose disk has services in "stopped" state
        # (because a previous cold rebuild walked through with services
        # restarted by rc-update) doesn't actually match the cached
        # live memory.
        #
        # Now: if any layer in the chain is live, we KEEP the staged
        # incoming-memory.bin so this build is live-restored from the
        # most recent live ancestor. The build sees the cumulative
        # running state and captures it (forced kind=live above).
        if [[ $chain_has_live -eq 0 ]]; then
            rm -f "$_vm_dir/incoming-memory.bin" "$_vm_dir/incoming-memory.bin.zst"
        fi

        # Time the miss-path build for snapshot_stats. SECONDS is a bash
        # builtin counting whole seconds since shell start — second-level
        # resolution is enough for the ~tens-of-seconds rebuild we see in
        # practice and avoids a python3 / coreutils-gdate dependency.
        local _build_t0=$SECONDS
        snapshot_walk_vm_boot "$vm"
        run_hook "$plugin" "snapshot_build" "$vm"

        if [[ "$kind" == "live" ]]; then
            # Capture while running, then stop so the next iteration's
            # rebase has a clean disk file.
            snapshot_save "$vm" "$plugin" "$key" "live" "$parent_plugin" "$parent_key"
            snapshot_walk_vm_stop "$vm"
            chain_has_live=1
            # snapshot_save deposits memory.bin[.zst] into the cache
            # dir but doesn't stage it into $_vm_dir. The next layer's
            # build VM would then cold-boot from its own dirty
            # storage.qcow2 (build mutations baked in, no memory) and
            # lose the running state we just captured. Re-rebase to
            # the just-saved entry: snapshot_walk_vm_rebase picks up
            # the live-kind meta and copies memory.bin[.zst] into the
            # vm_dir as incoming-memory.bin[.zst] for the next boot.
            snapshot_walk_vm_rebase "$vm" "$(snapshot_cache_path "$plugin" "$key")"
        else
            # Cold capture: must stop first so qemu-img convert sees a
            # consistent disk.
            snapshot_walk_vm_stop "$vm"
            snapshot_save "$vm" "$plugin" "$key" "cold" "$parent_plugin" "$parent_key"
        fi
        snapshot_stats_record_miss "$plugin" "$((SECONDS - _build_t0))"

        parent_plugin="$plugin"; parent_key="$key"
        parent_path=$(snapshot_cache_path "$plugin" "$key")
    done

    # Tail flush: warm paths where the last operation was a cache hit
    # haven't materialised their final rebase yet. This is the operation
    # that lands the kind=live tail's memory.bin[.zst] in the VM dir as
    # incoming-memory.bin[.zst] for the post-walk `aq start` to pick up.
    if [[ -n "$pending_path" ]]; then
        snapshot_walk_vm_rebase "$vm" "$pending_path"
    fi
}

# --- Per-plugin snapshot analytics --------------------------------------
#
# stats.json schema (one file per plugin under $RL_CACHE_DIR/<plugin>/):
#   {
#     "plugin":                "<name>",
#     "first_seen":            "<ISO8601>",
#     "last_seen":             "<ISO8601>",
#     "hits":                  <int>,
#     "misses":                <int>,
#     "rebuild_seconds_total": <int>,
#     "rebuild_seconds_last":  <int>,
#     "last_outcome":          "hit" | "miss"
#   }
# Updated by snapshot_walk_chain on every iteration. Read by
# snapshot_stats_show (surfaced via `rl cache stats`).
#
# Plain bash read/write (no jq dep) to keep the runtime requirements
# minimal. Concurrent rl new on the same project isn't supported; one
# session at a time per cache dir.

_snapshot_stats_path() {
    local plugin="$1"
    echo "$RL_CACHE_DIR/$plugin/stats.json"
}

_snapshot_stats_read_int() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo 0; return 0; }
    local v
    v=$(grep -E "\"$key\":" "$file" 2>/dev/null \
        | sed -E 's/.*"'"$key"'": ([0-9]+).*/\1/' | head -1)
    echo "${v:-0}"
}

_snapshot_stats_read_str() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo ""; return 0; }
    local v
    v=$(grep -E "\"$key\":" "$file" 2>/dev/null \
        | sed -E 's/.*"'"$key"'": "([^"]*)".*/\1/' | head -1)
    echo "$v"
}

_snapshot_stats_write() {
    local plugin="$1" hits="$2" misses="$3" total_s="$4" last_s="$5" \
          outcome="$6" first="$7" last="$8"
    local dir="$RL_CACHE_DIR/$plugin"
    mkdir -p "$dir"
    local tmp="$dir/stats.json.tmp"
    cat > "$tmp" <<JSON
{
  "plugin": "$plugin",
  "first_seen": "$first",
  "last_seen": "$last",
  "hits": $hits,
  "misses": $misses,
  "rebuild_seconds_total": $total_s,
  "rebuild_seconds_last": $last_s,
  "last_outcome": "$outcome"
}
JSON
    mv "$tmp" "$dir/stats.json"
}

# Bump hits + last_seen + last_outcome.
snapshot_stats_record_hit() {
    local plugin="$1"
    local file
    file=$(_snapshot_stats_path "$plugin")
    local now
    now=$(date -u +%FT%TZ)
    local hits misses total last first
    hits=$(_snapshot_stats_read_int "$file" hits)
    misses=$(_snapshot_stats_read_int "$file" misses)
    total=$(_snapshot_stats_read_int "$file" rebuild_seconds_total)
    last=$(_snapshot_stats_read_int "$file" rebuild_seconds_last)
    first=$(_snapshot_stats_read_str "$file" first_seen)
    [[ -z "$first" ]] && first="$now"
    hits=$((hits + 1))
    _snapshot_stats_write "$plugin" "$hits" "$misses" "$total" "$last" \
        "hit" "$first" "$now"
}

# Bump misses + add to total/last duration + last_seen + last_outcome.
snapshot_stats_record_miss() {
    local plugin="$1" duration_s="$2"
    local file
    file=$(_snapshot_stats_path "$plugin")
    local now
    now=$(date -u +%FT%TZ)
    local hits misses total first
    hits=$(_snapshot_stats_read_int "$file" hits)
    misses=$(_snapshot_stats_read_int "$file" misses)
    total=$(_snapshot_stats_read_int "$file" rebuild_seconds_total)
    first=$(_snapshot_stats_read_str "$file" first_seen)
    [[ -z "$first" ]] && first="$now"
    misses=$((misses + 1))
    total=$((total + duration_s))
    _snapshot_stats_write "$plugin" "$hits" "$misses" "$total" "$duration_s" \
        "miss" "$first" "$now"
}

# Pretty-print a per-plugin table to stdout. Used by `rl cache stats`.
snapshot_stats_show() {
    local cache_dir="${RL_CACHE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aq/cache}"
    if [[ ! -d "$cache_dir" ]]; then
        echo "No cache data yet (cache dir: $cache_dir)."
        return 0
    fi

    local found=0 stats plugin hits misses total last_outcome last_seen avg ratio denom
    local fmt='%-22s %6s %6s %10s %10s %8s   %s\n'
    while IFS= read -r stats; do
        if [[ "$found" -eq 0 ]]; then
            printf "$fmt" PLUGIN HITS MISSES "HIT RATE" "AVG BUILD" LAST "LAST SEEN"
            printf "$fmt" "----------------------" "------" "------" \
                "----------" "----------" "--------" "-------------------"
            found=1
        fi
        plugin=$(_snapshot_stats_read_str "$stats" plugin)
        hits=$(_snapshot_stats_read_int "$stats" hits)
        misses=$(_snapshot_stats_read_int "$stats" misses)
        total=$(_snapshot_stats_read_int "$stats" rebuild_seconds_total)
        last_outcome=$(_snapshot_stats_read_str "$stats" last_outcome)
        last_seen=$(_snapshot_stats_read_str "$stats" last_seen)
        denom=$((hits + misses))
        if [[ "$denom" -eq 0 ]]; then
            ratio="-"
        else
            ratio="$((hits * 100 / denom))%"
        fi
        if [[ "$misses" -eq 0 ]]; then
            avg="-"
        else
            avg="$((total / misses))s"
        fi
        printf "$fmt" "$plugin" "$hits" "$misses" "$ratio" "$avg" \
            "$last_outcome" "$last_seen"
    done < <(find "$cache_dir" -maxdepth 2 -name stats.json -type f 2>/dev/null | sort)

    if [[ "$found" -eq 0 ]]; then
        echo "No stats recorded yet."
    fi
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

        local size mem mem_zst mem_size
        size=$(stat -f%z "$snap" 2>/dev/null || stat -c%s "$snap" 2>/dev/null || echo 0)
        # If this is a live entry, also drop memory.bin / memory.bin.zst
        # (much bigger than disk).
        mem="$(dirname "$snap")/memory.bin"
        mem_zst="$(dirname "$snap")/memory.bin.zst"
        for f in "$mem" "$mem_zst"; do
            if [[ -f "$f" ]]; then
                mem_size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
                size=$((size + mem_size))
                rm -f "$f"
            fi
        done
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
