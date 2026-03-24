#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Source shared modules (always needed)
. "$LIB_DIR/ui.sh"
. "$LIB_DIR/util.sh"

# --- Help ---

cmd_help() {
    cat <<'EOF'
usage: rl <command>

commands:
  new      Create a new isolated VM for the current repo
  code     Connect to the VM's coding session
  status   Show the current repo's airlock status
  rm       Destroy the VM and clean up resources

Run 'rl <command> --help' for command-specific help.
EOF
}

# Check all dependencies
check_all_deps

# Parse subcommand
cmd="${1:-help}"
shift 2>/dev/null || true

# Dispatch
case "$cmd" in
    new)
        . "$LIB_DIR/vm.sh"
        # . "$LIB_DIR/ssh.sh"  # Created in Plan 02
        die "Command 'new' not yet implemented."
        ;;
    code)
        die "Command 'code' not yet implemented."
        ;;
    status)
        . "$LIB_DIR/vm.sh"
        cmd_status "$@"
        ;;
    rm)
        . "$LIB_DIR/vm.sh"
        cmd_rm "$@"
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        die "Unknown command '$cmd'. Run 'rl help' for usage."
        ;;
esac
