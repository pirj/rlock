# ui.sh -- Terminal UX: spinner, colors, formatted output
#
# This file is sourced by the rl entry point. Do not execute directly.
# Colors are initialized automatically when this file is sourced.

# shellcheck shell=bash

# --- Color Auto-Detection (D-09) ---

setup_colors() {
    # shellcheck disable=SC2034  # Variables used by scripts that source this file
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$(tput colors 2>/dev/null)" -ge 8 ] 2>/dev/null; then
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        BLUE=$(tput setaf 4)
        BOLD=$(tput bold)
        RESET=$(tput sgr0)
    else
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        BOLD=''
        RESET=''
    fi
}

# --- Output Helpers ---

info() {
    printf '%s%s%s\n' "$BLUE" "$1" "$RESET"
}

success() {
    printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
    printf '%s%s%s\n' "$YELLOW" "$1" "$RESET" >&2
}

# --- Braille Spinner (D-07, D-08) ---

SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPINNER_PID=""

_spinner_cleanup() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf '\r\033[2K' >&2
    fi
}

spinner_start() {
    local msg="$1"
    if [ -t 2 ]; then
        trap '_spinner_cleanup; trap - INT; kill -INT $$' INT
        (
            local i=0
            while true; do
                printf '\r  %s %s' "${SPINNER_CHARS[$((i % ${#SPINNER_CHARS[@]}))]}" "$msg" >&2
                i=$((i + 1))
                sleep 0.08
            done
        ) &
        SPINNER_PID=$!
    else
        printf '  %s\n' "$msg" >&2
    fi
}

spinner_stop() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf '\r\033[2K  %s✓%s %s\n' "$GREEN" "$RESET" "$1" >&2
    else
        printf '  %s\n' "$1" >&2
    fi
}

# Initialize colors at source time
setup_colors
