# proxy.sh -- Caddy reverse proxy lifecycle management
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh and ui.sh to be sourced first (for die(), info(), warn()).

# shellcheck shell=bash

# --- Constants ---

CADDY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rl"
CADDY_FILE="$CADDY_CONFIG_DIR/Caddyfile"
ANTHROPIC_PORT=9110
# shellcheck disable=SC2034  # OPENAI_PORT used by scripts that source this file
OPENAI_PORT=9111

# --- Caddyfile Generation ---

generate_caddyfile() {
    mkdir -p "$CADDY_CONFIG_DIR"
    # Single-quoted heredoc so {env.*} placeholders are written literally,
    # not expanded by bash. Caddy reads them at runtime.
    cat > "$CADDY_FILE" <<'CADDYFILE'
{
    admin localhost:2020
}

http://127.0.0.1:9110 {
    reverse_proxy https://api.anthropic.com {
        header_up x-api-key "{env.ANTHROPIC_API_KEY}"
        header_up Host api.anthropic.com
    }
}

http://127.0.0.1:9111 {
    reverse_proxy https://api.openai.com {
        header_up Authorization "Bearer {env.OPENAI_API_KEY}"
        header_up Host api.openai.com
    }
}
CADDYFILE
}

# --- Caddy Detection ---

is_caddy_running() {
    # Port probe is more reliable than pgrep or caddy status (not a real subcommand).
    # Checks if the Anthropic proxy port is responding.
    curl -sf -o /dev/null --connect-timeout 1 "http://127.0.0.1:$ANTHROPIC_PORT" 2>/dev/null
}

# --- Caddy Lifecycle ---

ensure_caddy_running() {
    # Idempotent guard: skip if already running
    if is_caddy_running; then
        return 0
    fi

    # ANTHROPIC_API_KEY is required (D-08). OPENAI_API_KEY is optional --
    # if unset, Caddy may insert an empty string for the OpenAI header.
    # Users who don't have an OpenAI key simply won't use Codex.
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        die "ANTHROPIC_API_KEY not set. Export it in your shell before running rl."
    fi

    if [ ! -f "$CADDY_FILE" ]; then
        generate_caddyfile
    fi

    caddy start --config "$CADDY_FILE" --adapter caddyfile 2>/dev/null \
        || die "Failed to start Caddy proxy. Check 'caddy validate --config $CADDY_FILE'."

    # Brief wait for Caddy to bind ports, then verify
    sleep 1
    is_caddy_running \
        || die "Caddy started but proxy not responding on port $ANTHROPIC_PORT."
}
