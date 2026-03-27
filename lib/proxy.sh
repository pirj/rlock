# proxy.sh -- Caddy reverse proxy lifecycle management
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh, ui.sh, and creds.sh to be sourced first.

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

    # Resolve credentials from store or env vars
    local anthropic_key openai_key
    anthropic_key=$(creds_resolve "ANTHROPIC_API_KEY" 2>/dev/null) || true
    openai_key=$(creds_resolve "OPENAI_API_KEY" 2>/dev/null) || true

    # Write actual key values into the Caddyfile (not env var references).
    # Caddy reads {env.*} only at startup, so keys exported after Caddy starts
    # would be invisible. Writing actual values + caddy reload solves this.
    # File is chmod 600 by ensure_caddy_running.
    cat > "$CADDY_FILE" <<CADDYFILE
{
    admin localhost:2020
}

http://127.0.0.1:${ANTHROPIC_PORT} {
    request_header x-api-key "${anthropic_key}"
    reverse_proxy https://api.anthropic.com {
        header_up Host api.anthropic.com
    }
}

http://127.0.0.1:${OPENAI_PORT} {
    request_header Authorization "Bearer ${openai_key}"
    reverse_proxy https://api.openai.com {
        header_up Host api.openai.com
    }
}
CADDYFILE
    chmod 600 "$CADDY_FILE"
}

# --- Caddy Detection ---

is_caddy_running() {
    # Port probe: checks if Caddy is listening. Use -s (silent) without -f
    # because the upstream API returns 404 for GET / which curl -f treats as failure.
    # Any HTTP response (even 404) means Caddy is running.
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 1 \
        "http://127.0.0.1:$ANTHROPIC_PORT" 2>/dev/null) || return 1
    [ "$http_code" != "000" ]
}

# --- Caddy Lifecycle ---

ensure_caddy_running() {
    # Refresh OAuth tokens if needed before generating config
    refresh_if_needed

    # Always regenerate the Caddyfile to pick up credential changes
    generate_caddyfile

    if is_caddy_running; then
        # Caddy is running — reload config to pick up any key changes
        caddy reload --config "$CADDY_FILE" --adapter caddyfile >/dev/null 2>&1 || true
        # Start refresh daemon for OAuth token lifecycle
        start_refresh_daemon 2>/dev/null || true
        return 0
    fi

    # Start Caddy (suppress its chatty startup output)
    caddy start --config "$CADDY_FILE" --adapter caddyfile >/dev/null 2>&1 \
        || return 1

    # Brief wait for Caddy to bind ports, then verify
    sleep 1
    is_caddy_running || return 1

    # Start refresh daemon for OAuth token lifecycle
    start_refresh_daemon 2>/dev/null || true
}
