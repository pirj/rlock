#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    export RL_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$RL_CACHE_DIR"
    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/snapshot.sh"
}

@test "snapshot_cache_path returns plugin/key/disk.qcow2" {
    run snapshot_cache_path "ruby-bundler" "abc123"
    assert_success
    assert_output "$RL_CACHE_DIR/ruby-bundler/abc123/disk.qcow2"
}

@test "snapshot_lookup hits when file exists" {
    local p="$RL_CACHE_DIR/foo/k1"
    mkdir -p "$p"
    touch "$p/disk.qcow2"
    run snapshot_lookup "foo" "k1"
    assert_success
    assert_output "$p/disk.qcow2"
}

@test "snapshot_lookup misses when file absent" {
    run snapshot_lookup "foo" "k1"
    assert_failure
}

@test "snapshot_latest finds most-recent snapshot regardless of key" {
    mkdir -p "$RL_CACHE_DIR/foo/k1" "$RL_CACHE_DIR/foo/k2"
    touch "$RL_CACHE_DIR/foo/k1/disk.qcow2"
    sleep 1
    touch "$RL_CACHE_DIR/foo/k2/disk.qcow2"
    run snapshot_latest "foo"
    assert_success
    assert_output "$RL_CACHE_DIR/foo/k2/disk.qcow2"
}

@test "snapshot_latest fails when plugin has no snapshots" {
    run snapshot_latest "never-built"
    assert_failure
}

@test "snapshot_entry_kind defaults to cold when meta.json missing" {
    mkdir -p "$RL_CACHE_DIR/foo/k1"
    touch "$RL_CACHE_DIR/foo/k1/disk.qcow2"
    run snapshot_entry_kind "$RL_CACHE_DIR/foo/k1/disk.qcow2"
    assert_success
    assert_output "cold"
}

@test "snapshot_entry_kind reads kind=live from meta.json" {
    mkdir -p "$RL_CACHE_DIR/foo/k1"
    touch "$RL_CACHE_DIR/foo/k1/disk.qcow2"
    cat > "$RL_CACHE_DIR/foo/k1/meta.json" <<'M'
{
  "plugin": "foo",
  "key": "k1",
  "kind": "live"
}
M
    run snapshot_entry_kind "$RL_CACHE_DIR/foo/k1/disk.qcow2"
    assert_success
    assert_output "live"
}

@test "snapshot_save kind=cold writes disk.qcow2 + meta.json with kind=cold" {
    local src="$BATS_TEST_TMPDIR/src.qcow2"
    qemu-img create -f qcow2 "$src" 1M >/dev/null
    snapshot_walk_vm_disk() { echo "$src"; }

    run snapshot_save "fakevm" "demo" "key-xyz" "cold" "parent-plugin" "parent-key"
    assert_success
    [ -f "$RL_CACHE_DIR/demo/key-xyz/disk.qcow2" ]
    [ -f "$RL_CACHE_DIR/demo/key-xyz/meta.json" ]
    [ ! -f "$RL_CACHE_DIR/demo/key-xyz/memory.bin" ]
    run jq -r '.kind' "$RL_CACHE_DIR/demo/key-xyz/meta.json"
    assert_output "cold"
    run jq -r '.parent_plugin' "$RL_CACHE_DIR/demo/key-xyz/meta.json"
    assert_output "parent-plugin"
}

@test "snapshot_save kind=live shells to aq snapshot create + moves files" {
    local aq_tag_dir="$BATS_TEST_TMPDIR/aq_snapshots"
    snapshot_aq_tag_dir() { echo "$aq_tag_dir/$1"; }

    # Stub `aq`: snapshot create writes both files into the tag dir;
    # snapshot rm is a no-op.
    aq() {
        case "$1" in
            snapshot)
                case "$2" in
                    create)
                        local tag="$4"
                        mkdir -p "$aq_tag_dir/$tag"
                        echo "DISK"   > "$aq_tag_dir/$tag/disk.qcow2"
                        echo "MEMORY" > "$aq_tag_dir/$tag/memory.bin"
                        ;;
                    rm) : ;;
                esac
                ;;
        esac
    }
    export -f aq snapshot_aq_tag_dir

    run snapshot_save "fakevm" "warm" "k-live" "live" "engine" "k-engine"
    assert_success
    [ -f "$RL_CACHE_DIR/warm/k-live/disk.qcow2" ]
    [ -f "$RL_CACHE_DIR/warm/k-live/memory.bin" ]
    [ -f "$RL_CACHE_DIR/warm/k-live/meta.json" ]
    grep -q '"kind": "live"' "$RL_CACHE_DIR/warm/k-live/meta.json"
    # Disk content was moved from aq tag dir into framework cache
    run cat "$RL_CACHE_DIR/warm/k-live/disk.qcow2"
    assert_output "DISK"
    run cat "$RL_CACHE_DIR/warm/k-live/memory.bin"
    assert_output "MEMORY"
}

@test "snapshot_save rejects unknown kind" {
    run snapshot_save "fakevm" "foo" "k" "weird" "" ""
    assert_failure
}

@test "snapshot_rebase creates qcow2 with given backing" {
    local backing="$BATS_TEST_TMPDIR/backing.qcow2"
    qemu-img create -f qcow2 "$backing" 1M >/dev/null
    local out="$BATS_TEST_TMPDIR/top.qcow2"
    run snapshot_rebase "$out" "$backing"
    assert_success
    [ -f "$out" ]
    qemu-img info "$out" | grep -q "backing file: $backing"
}

@test "snapshot_walk_vm_rebase places incoming-memory.bin for live entry" {
    local backing="$BATS_TEST_TMPDIR/cache/foo/k1/disk.qcow2"
    mkdir -p "$(dirname "$backing")"
    qemu-img create -f qcow2 "$backing" 1M >/dev/null
    echo "MEMORY-STATE" > "$(dirname "$backing")/memory.bin"
    cat > "$(dirname "$backing")/meta.json" <<'M'
{ "kind": "live" }
M

    local vm_dir="$BATS_TEST_TMPDIR/vm/foo"
    mkdir -p "$vm_dir"
    export AQ_STATE_DIR="$BATS_TEST_TMPDIR/vm"

    snapshot_walk_vm_rebase "foo" "$backing"
    [ -f "$vm_dir/storage.qcow2" ]
    [ -f "$vm_dir/incoming-memory.bin" ]
    run cat "$vm_dir/incoming-memory.bin"
    assert_output "MEMORY-STATE"
}

@test "snapshot_walk_vm_rebase preserves incoming-memory.bin from earlier live ancestor when this layer is cold" {
    # Chain: live ancestor placed incoming-memory.bin; later cold rebase
    # must NOT clear it (a cold layer on top of a live one is a typical
    # bakeri.sh shape: docker-compose live, mise/ruby-bundler/npm cold).
    local backing="$BATS_TEST_TMPDIR/cache/foo/k_cold/disk.qcow2"
    mkdir -p "$(dirname "$backing")"
    qemu-img create -f qcow2 "$backing" 1M >/dev/null
    # No meta.json → entry treated as cold
    local vm_dir="$BATS_TEST_TMPDIR/vm/foo"
    mkdir -p "$vm_dir"
    echo "LIVE-MEMORY-FROM-EARLIER-LAYER" > "$vm_dir/incoming-memory.bin"
    export AQ_STATE_DIR="$BATS_TEST_TMPDIR/vm"

    snapshot_walk_vm_rebase "foo" "$backing"
    [ -f "$vm_dir/incoming-memory.bin" ]
    run cat "$vm_dir/incoming-memory.bin"
    assert_output "LIVE-MEMORY-FROM-EARLIER-LAYER"
}

@test "snapshot_walk_vm_rebase overwrites incoming-memory.bin when this layer is live" {
    # A later live layer's memory state supersedes any earlier one.
    local backing="$BATS_TEST_TMPDIR/cache/foo/k_live2/disk.qcow2"
    mkdir -p "$(dirname "$backing")"
    qemu-img create -f qcow2 "$backing" 1M >/dev/null
    echo "NEW-LIVE-MEMORY" > "$(dirname "$backing")/memory.bin"
    cat > "$(dirname "$backing")/meta.json" <<'M'
{ "kind": "live" }
M

    local vm_dir="$BATS_TEST_TMPDIR/vm/foo"
    mkdir -p "$vm_dir"
    echo "OLDER-LIVE-MEMORY" > "$vm_dir/incoming-memory.bin"
    export AQ_STATE_DIR="$BATS_TEST_TMPDIR/vm"

    snapshot_walk_vm_rebase "foo" "$backing"
    run cat "$vm_dir/incoming-memory.bin"
    assert_output "NEW-LIVE-MEMORY"
}

@test "snapshot_walk_chain clears stale incoming-memory.bin at start" {
    # A leftover incoming-memory.bin from a previous `rl new` session
    # must be cleared before walking — otherwise it would be applied
    # spuriously when no plugin in this chain is kind=live.
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p-stale" "cached" "k-s"
    local fakedisk="$BATS_TEST_TMPDIR/vm-stale/storage.qcow2"
    mkdir -p "$BATS_TEST_TMPDIR/vm-stale"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    echo "STALE-FROM-PRIOR-SESSION" > "$BATS_TEST_TMPDIR/vm-stale/incoming-memory.bin"

    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_rebase() { :; }

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "vm-stale" "p-stale"
    assert_success
    [ ! -f "$BATS_TEST_TMPDIR/vm-stale/incoming-memory.bin" ]
}

# --- snapshot_walk_chain ---

_setup_fake_plugin() {
    # Args: name strategy key [kind]
    local name="$1" strategy="$2" key="$3" kind="${4:-cold}"
    export PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core"
    export PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user"
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
description = "Fake $name"

[snapshot]
strategy = "$strategy"
kind = "$kind"
EOF
    cat > "$PLUGIN_CORE_DIR/$name/plugin.sh" <<SH
#!/usr/bin/env bash
snapshot_key()  { echo "$key"; }
snapshot_build() { echo "BUILT:$name" >> "$BATS_TEST_TMPDIR/built.log"; }
if declare -f "\$1" > /dev/null 2>&1; then "\$1" "\${@:2}"; fi
SH
    chmod +x "$PLUGIN_CORE_DIR/$name/plugin.sh"
}

@test "snapshot_walk_chain cached: cache hit skips build" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p1" "cached" "k1"
    mkdir -p "$RL_CACHE_DIR/p1/k1"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/p1/k1/disk.qcow2" 1M >/dev/null

    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$BATS_TEST_TMPDIR/fake.qcow2"; }
    snapshot_walk_vm_rebase() { :; }

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "p1"
    assert_success
    [ ! -s "$BATS_TEST_TMPDIR/built.log" ]
}

@test "snapshot_walk_chain cached: miss triggers build + save" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p2" "cached" "k2"

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "p2"
    assert_success
    grep -q "BUILT:p2" "$BATS_TEST_TMPDIR/built.log"
    [ -f "$RL_CACHE_DIR/p2/k2/disk.qcow2" ]
    grep -q '"kind": "cold"' "$RL_CACHE_DIR/p2/k2/meta.json"
}

@test "snapshot_walk_chain cached kind=live: miss triggers build + live save" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p2live" "cached" "k2live" "live"

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }

    # Stub aq + tag dir for the live save path
    local aq_tag_dir="$BATS_TEST_TMPDIR/aq_snapshots"
    snapshot_aq_tag_dir() { echo "$aq_tag_dir/$1"; }
    aq() {
        case "$1" in
            snapshot)
                case "$2" in
                    create)
                        local tag="$4"
                        mkdir -p "$aq_tag_dir/$tag"
                        echo "D" > "$aq_tag_dir/$tag/disk.qcow2"
                        echo "M" > "$aq_tag_dir/$tag/memory.bin"
                        ;;
                    rm) : ;;
                esac
                ;;
        esac
    }
    export -f aq snapshot_aq_tag_dir

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "p2live"
    assert_success
    grep -q "BUILT:p2live" "$BATS_TEST_TMPDIR/built.log"
    [ -f "$RL_CACHE_DIR/p2live/k2live/disk.qcow2" ]
    [ -f "$RL_CACHE_DIR/p2live/k2live/memory.bin" ]
    grep -q '"kind": "live"' "$RL_CACHE_DIR/p2live/k2live/meta.json"
}

@test "snapshot_walk_chain incremental: miss boots from latest-of-plugin" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p3" "incremental" "new-key"
    # Existing snapshot for an older key
    mkdir -p "$RL_CACHE_DIR/p3/old-key"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/p3/old-key/disk.qcow2" 1M >/dev/null

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null

    local rebased_to=""
    snapshot_walk_vm_rebase() { rebased_to="$2"; }
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }

    snapshot_walk_chain "fakevm" "p3"
    [ "$rebased_to" = "$RL_CACHE_DIR/p3/old-key/disk.qcow2" ]
    [ -f "$RL_CACHE_DIR/p3/new-key/disk.qcow2" ]
}

@test "snapshot_walk_chain ephemeral: runs build but does not save" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p4" "ephemeral" "k4"

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }

    : > "$BATS_TEST_TMPDIR/built.log"
    snapshot_walk_chain "fakevm" "p4"
    grep -q "BUILT:p4" "$BATS_TEST_TMPDIR/built.log"
    [ ! -d "$RL_CACHE_DIR/p4" ]
}

@test "snapshot_prune removes entries older than threshold + not in live set" {
    mkdir -p "$RL_CACHE_DIR/foo/k_old" "$RL_CACHE_DIR/foo/k_recent" "$RL_CACHE_DIR/foo/k_live"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/foo/k_old/disk.qcow2" 1M >/dev/null
    qemu-img create -f qcow2 "$RL_CACHE_DIR/foo/k_recent/disk.qcow2" 1M >/dev/null
    qemu-img create -f qcow2 "$RL_CACHE_DIR/foo/k_live/disk.qcow2" 1M >/dev/null

    # Backdate the "old" entry by 60 days
    touch -t 202401010000 "$RL_CACHE_DIR/foo/k_old/disk.qcow2"

    # Live set excludes k_live from pruning
    snapshot_prune --max-age-days=30 --live "$RL_CACHE_DIR/foo/k_live/disk.qcow2"
    [ ! -f "$RL_CACHE_DIR/foo/k_old/disk.qcow2" ]
    [ -f "$RL_CACHE_DIR/foo/k_recent/disk.qcow2" ]
    [ -f "$RL_CACHE_DIR/foo/k_live/disk.qcow2" ]
}

@test "snapshot_prune drops memory.bin alongside disk.qcow2 for live entries" {
    mkdir -p "$RL_CACHE_DIR/foo/k_live_old"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/foo/k_live_old/disk.qcow2" 1M >/dev/null
    dd if=/dev/zero of="$RL_CACHE_DIR/foo/k_live_old/memory.bin" bs=1M count=2 2>/dev/null
    cat > "$RL_CACHE_DIR/foo/k_live_old/meta.json" <<'M'
{ "kind": "live" }
M
    touch -t 202401010000 "$RL_CACHE_DIR/foo/k_live_old/disk.qcow2"

    snapshot_prune --max-age-days=30
    [ ! -f "$RL_CACHE_DIR/foo/k_live_old/disk.qcow2" ]
    [ ! -f "$RL_CACHE_DIR/foo/k_live_old/memory.bin" ]
    [ ! -d "$RL_CACHE_DIR/foo/k_live_old" ]
}
