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

@test "snapshot_save overwrites prior cold entry at the same slot" {
    local src="$BATS_TEST_TMPDIR/src.qcow2"
    qemu-img create -f qcow2 "$src" 1M >/dev/null
    snapshot_walk_vm_disk() { echo "$src"; }
    export -f snapshot_walk_vm_disk

    snapshot_save "fakevm" "demo" "k" "cold" "" ""
    local before_inode
    before_inode=$(stat -f %i "$RL_CACHE_DIR/demo/k/disk.qcow2" 2>/dev/null \
                   || stat -c %i "$RL_CACHE_DIR/demo/k/disk.qcow2")
    snapshot_save "fakevm" "demo" "k" "cold" "" ""
    local after_inode
    after_inode=$(stat -f %i "$RL_CACHE_DIR/demo/k/disk.qcow2" 2>/dev/null \
                  || stat -c %i "$RL_CACHE_DIR/demo/k/disk.qcow2")
    # The previous file was rm'd before convert wrote a new one — fresh inode.
    [ "$before_inode" != "$after_inode" ]
}

@test "snapshot_save cold overwrite drops stale memory.bin from a prior live entry" {
    local src="$BATS_TEST_TMPDIR/src.qcow2"
    qemu-img create -f qcow2 "$src" 1M >/dev/null
    snapshot_walk_vm_disk() { echo "$src"; }
    export -f snapshot_walk_vm_disk

    # Simulate a prior live capture at the same slot.
    mkdir -p "$RL_CACHE_DIR/demo/k"
    touch "$RL_CACHE_DIR/demo/k/disk.qcow2" "$RL_CACHE_DIR/demo/k/memory.bin"

    snapshot_save "fakevm" "demo" "k" "cold" "" ""
    [ -f "$RL_CACHE_DIR/demo/k/disk.qcow2" ]
    [ ! -f "$RL_CACHE_DIR/demo/k/memory.bin" ]
    run jq -r '.kind' "$RL_CACHE_DIR/demo/k/meta.json"
    assert_output "cold"
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

@test "snapshot_walk_chain skips layer whose snapshot_should_skip prints skip" {
    source "$LIB_DIR/plugin.sh"
    # Plugin declares snapshot_should_skip that always prints "skip".
    local name="p-skipper"
    export PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core"
    export PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user"
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
description = "Skipping plugin"
[snapshot]
strategy = "cached"
EOF
    cat > "$PLUGIN_CORE_DIR/$name/plugin.sh" <<SH
#!/usr/bin/env bash
snapshot_should_skip() { echo "skip"; }
snapshot_key()  { echo "should-not-be-called" >> "$BATS_TEST_TMPDIR/built.log"; }
snapshot_build() { echo "should-not-be-called" >> "$BATS_TEST_TMPDIR/built.log"; }
if declare -f "\$1" > /dev/null 2>&1; then "\$1" "\${@:2}"; fi
SH
    chmod +x "$PLUGIN_CORE_DIR/$name/plugin.sh"

    snapshot_walk_vm_boot()   { echo "boot called" >> "$BATS_TEST_TMPDIR/built.log"; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$BATS_TEST_TMPDIR/fake.qcow2"; }
    snapshot_walk_vm_rebase() { echo "rebase called" >> "$BATS_TEST_TMPDIR/built.log"; }

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "$name"
    assert_success
    [ ! -s "$BATS_TEST_TMPDIR/built.log" ]
}

@test "snapshot_walk_chain participates when snapshot_should_skip prints anything else" {
    source "$LIB_DIR/plugin.sh"
    # Plugin returns "go" (or empty) — should NOT skip.
    local name="p-go"
    export PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core"
    export PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user"
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
description = "Non-skipping plugin"
[snapshot]
strategy = "cached"
EOF
    cat > "$PLUGIN_CORE_DIR/$name/plugin.sh" <<SH
#!/usr/bin/env bash
snapshot_should_skip() { echo "go"; }
snapshot_key()  { echo "kgo"; }
snapshot_build() { echo "BUILT" >> "$BATS_TEST_TMPDIR/built.log"; }
if declare -f "\$1" > /dev/null 2>&1; then "\$1" "\${@:2}"; fi
SH
    chmod +x "$PLUGIN_CORE_DIR/$name/plugin.sh"

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "$name"
    assert_success
    grep -q "BUILT" "$BATS_TEST_TMPDIR/built.log"
}

@test "snapshot_walk_chain participates when snapshot_should_skip is undefined" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p-nohook" "cached" "kn"

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }

    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "p-nohook"
    assert_success
    grep -q "BUILT:p-nohook" "$BATS_TEST_TMPDIR/built.log"
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

@test "snapshot_walk_chain coalesces consecutive cache hits into one rebase" {
    # Three plugins all cache-hit. Pre-v2 the loop rebased N times;
    # post-v2 it defers each hit's rebase and only materialises the last
    # one. snapshot_walk_vm_rebase is stubbed as a counter.
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "h1" "cached" "k1"
    _setup_fake_plugin "h2" "cached" "k2"
    _setup_fake_plugin "h3" "cached" "k3"
    for p in h1 h2 h3; do
        mkdir -p "$RL_CACHE_DIR/$p/k${p#h}"
        qemu-img create -f qcow2 "$RL_CACHE_DIR/$p/k${p#h}/disk.qcow2" 1M >/dev/null
    done

    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$BATS_TEST_TMPDIR/fake.qcow2"; }
    snapshot_walk_vm_rebase() {
        echo "rebase:$2" >> "$BATS_TEST_TMPDIR/rebase.log"
    }

    : > "$BATS_TEST_TMPDIR/rebase.log"
    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" h1 h2 h3
    assert_success
    # All three should record hits in stats.
    for p in h1 h2 h3; do
        run grep -E '"hits": 1' "$RL_CACHE_DIR/$p/stats.json"
        assert_success
    done
    # But only ONE rebase actually happens — to h3's cache.
    [ "$(wc -l < "$BATS_TEST_TMPDIR/rebase.log")" -eq 1 ]
    grep -q "rebase:$RL_CACHE_DIR/h3/k3/disk.qcow2" "$BATS_TEST_TMPDIR/rebase.log"
}

@test "snapshot_walk_chain flushes pending hit before a miss-build" {
    # Pattern: cache hit, then cache miss. The hit's rebase must
    # materialise BEFORE the miss-build runs (so storage.qcow2 is on
    # the chain parent), not be skipped.
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "h-pre"  "cached" "kpre"
    _setup_fake_plugin "m-post" "cached" "kpost"
    mkdir -p "$RL_CACHE_DIR/h-pre/kpre"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/h-pre/kpre/disk.qcow2" 1M >/dev/null
    # m-post has no cache → miss.

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() {
        echo "rebase:$2" >> "$BATS_TEST_TMPDIR/rebase.log"
    }

    : > "$BATS_TEST_TMPDIR/rebase.log"
    : > "$BATS_TEST_TMPDIR/built.log"
    run snapshot_walk_chain "fakevm" "h-pre" "m-post"
    assert_success
    # h-pre's hit rebase fired (flushed before m-post's build).
    grep -q "rebase:$RL_CACHE_DIR/h-pre/kpre/disk.qcow2" "$BATS_TEST_TMPDIR/rebase.log"
    # m-post built.
    grep -q "BUILT:m-post" "$BATS_TEST_TMPDIR/built.log"
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

@test "snapshot_stats_record_hit creates stats.json with hits=1 when absent" {
    snapshot_stats_record_hit "myplug"
    [ -f "$RL_CACHE_DIR/myplug/stats.json" ]
    run grep -E '"hits": 1' "$RL_CACHE_DIR/myplug/stats.json"
    assert_success
    run grep -E '"misses": 0' "$RL_CACHE_DIR/myplug/stats.json"
    assert_success
    run grep -E '"last_outcome": "hit"' "$RL_CACHE_DIR/myplug/stats.json"
    assert_success
}

@test "snapshot_stats_record_hit increments hits on existing stats" {
    snapshot_stats_record_hit "myplug"
    snapshot_stats_record_hit "myplug"
    snapshot_stats_record_hit "myplug"
    run grep -E '"hits": 3' "$RL_CACHE_DIR/myplug/stats.json"
    assert_success
}

@test "snapshot_stats_record_miss bumps misses and adds to total duration" {
    snapshot_stats_record_miss "myplug" 12
    snapshot_stats_record_miss "myplug" 30
    run grep -E '"misses": 2' "$RL_CACHE_DIR/myplug/stats.json"
    assert_success
    run grep -E '"rebuild_seconds_total": 42' "$RL_CACHE_DIR/myplug/stats.json"
    assert_success
    run grep -E '"rebuild_seconds_last": 30' "$RL_CACHE_DIR/myplug/stats.json"
    assert_success
    run grep -E '"last_outcome": "miss"' "$RL_CACHE_DIR/myplug/stats.json"
    assert_success
}

@test "snapshot_stats_show prints a table with per-plugin metrics" {
    snapshot_stats_record_hit  "plug-a"
    snapshot_stats_record_hit  "plug-a"
    snapshot_stats_record_miss "plug-a" 8
    snapshot_stats_record_miss "plug-b" 60

    run snapshot_stats_show
    assert_success
    assert_output --partial "PLUGIN"
    assert_output --partial "HIT RATE"
    assert_output --partial "plug-a"
    assert_output --partial "plug-b"
    # plug-a: 2 hits + 1 miss = 66% (integer division 200/3=66)
    assert_output --partial "66%"
    # plug-b: 0 hits + 1 miss = 0%
    assert_output --partial "0%"
    # plug-a avg = 8s (one miss, total 8)
    assert_output --partial "8s"
    # plug-b avg = 60s
    assert_output --partial "60s"
}

@test "snapshot_stats_show prints empty-state message when no stats" {
    run snapshot_stats_show
    assert_success
    assert_output --partial "No stats recorded"
}

@test "snapshot_walk_chain on cache hit records a hit in stats" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p-stats-hit" "cached" "k1"
    mkdir -p "$RL_CACHE_DIR/p-stats-hit/k1"
    qemu-img create -f qcow2 "$RL_CACHE_DIR/p-stats-hit/k1/disk.qcow2" 1M >/dev/null

    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$BATS_TEST_TMPDIR/fake.qcow2"; }
    snapshot_walk_vm_rebase() { :; }

    run snapshot_walk_chain "fakevm" "p-stats-hit"
    assert_success
    run grep -E '"hits": 1' "$RL_CACHE_DIR/p-stats-hit/stats.json"
    assert_success
    run grep -E '"misses": 0' "$RL_CACHE_DIR/p-stats-hit/stats.json"
    assert_success
}

@test "snapshot_walk_chain on cache miss records a miss in stats" {
    source "$LIB_DIR/plugin.sh"
    _setup_fake_plugin "p-stats-miss" "cached" "k1"

    local fakedisk="$BATS_TEST_TMPDIR/disk.qcow2"
    qemu-img create -f qcow2 "$fakedisk" 1M >/dev/null
    snapshot_walk_vm_boot()   { :; }
    snapshot_walk_vm_stop()   { :; }
    snapshot_walk_vm_disk()   { echo "$fakedisk"; }
    snapshot_walk_vm_rebase() { :; }

    run snapshot_walk_chain "fakevm" "p-stats-miss"
    assert_success
    run grep -E '"hits": 0' "$RL_CACHE_DIR/p-stats-miss/stats.json"
    assert_success
    run grep -E '"misses": 1' "$RL_CACHE_DIR/p-stats-miss/stats.json"
    assert_success
    run grep -E '"last_outcome": "miss"' "$RL_CACHE_DIR/p-stats-miss/stats.json"
    assert_success
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
