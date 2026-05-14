#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

subcommand="${1:-create}"
shift || true

if [[ "$subcommand" == "rm" ]]; then
    # Delegate to `rl rm` — the active VM is resolved by branch's resolve_vm hook.
    exec "$RL_BIN_DIR/rl" rm "$@"
fi

# create: just run `rl new` — snapshot_walk_chain handles the layer chain,
# including branch's [snapshot] participation.
exec "$RL_BIN_DIR/rl" new "$@"
