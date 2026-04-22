#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

# --- Constants ---

CREDS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rl"
CREDS_FILE="$CREDS_DIR/credentials"
CADDY_FILE="$CREDS_DIR/Caddyfile"
ANTHROPIC_PORT=9110
OPENAI_PORT=9111
KEYCHAIN_SERVICE="Claude Code-credentials"

# --- Credential Store ---

creds_get() {
    local key="$1"
    if [ -f "$CREDS_FILE" ]; then
        grep "^${key}=" "$CREDS_FILE" 2>/dev/null | head -1 | cut -d= -f2-
    fi
}

creds_set() {
    local key="$1"
    local value="$2"
    mkdir -p "$CREDS_DIR"

    if [ -f "$CREDS_FILE" ]; then
        local tmp="$CREDS_FILE.tmp"
        grep -v "^${key}=" "$CREDS_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$CREDS_FILE"
    fi

    echo "${key}=${value}" >> "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
}

# Resolve a credential: creds store -> env var -> empty.
creds_resolve() {
    local key="$1"
    local stored
    stored=$(creds_get "$key")
    if [ -n "$stored" ]; then
        printf '%s' "$stored"
        return 0
    fi
    local env_val="${!key:-}"
    if [ -n "$env_val" ]; then
        printf '%s' "$env_val"
        return 0
    fi
    return 1
}

# --- Claude Code OAuth Import ---

# Read Claude Code's OAuth credentials from the macOS Keychain.
# Returns JSON with accessToken and refreshToken, or empty on failure.
_read_keychain() {
    if ! command -v security >/dev/null 2>&1; then
        return 1
    fi
    security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
}

# Import OAuth tokens from Claude Code's keychain entry.
import_claude_oauth() {
    local keychain_data
    keychain_data=$(_read_keychain) || return 1

    if [ -z "$keychain_data" ]; then
        return 1
    fi

    # Parse JSON -- extract accessToken and refreshToken
    local access_token refresh_token
    access_token=$(printf '%s' "$keychain_data" | \
        sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
    refresh_token=$(printf '%s' "$keychain_data" | \
        sed -n 's/.*"refreshToken":"\([^"]*\)".*/\1/p')

    if [ -z "$access_token" ]; then
        return 1
    fi

    creds_set "ANTHROPIC_API_KEY" "$access_token"
    creds_set "ANTHROPIC_REFRESH_TOKEN" "$refresh_token"
    creds_set "ANTHROPIC_AUTH_TYPE" "oauth"
    return 0
}

# Check if the current credential is an OAuth token and refresh if needed.
# Called before generating the Caddyfile.
refresh_if_needed() {
    local auth_type
    auth_type=$(creds_get "ANTHROPIC_AUTH_TYPE")
    if [ "$auth_type" = "oauth" ]; then
        # Re-import from keychain to get latest tokens
        import_claude_oauth 2>/dev/null || true
    fi
}

# --- Caddyfile Generation ---

generate_caddyfile() {
    mkdir -p "$CREDS_DIR"

    # Resolve credentials from store or env vars
    local anthropic_key openai_key
    anthropic_key=$(creds_resolve "ANTHROPIC_API_KEY" 2>/dev/null) || true
    openai_key=$(creds_resolve "OPENAI_API_KEY" 2>/dev/null) || true

    # Write actual key values into the Caddyfile (not env var references).
    # Caddy reads {env.*} only at startup, so keys exported after Caddy starts
    # would be invisible. Writing actual values + caddy reload solves this.
    # File is chmod 600 below.
    cat > "$CADDY_FILE" <<CADDYFILE
{
    admin localhost:2020
}

http://:${ANTHROPIC_PORT} {
    bind 127.0.0.1
    request_header x-api-key "${anthropic_key}"
    reverse_proxy https://api.anthropic.com {
        header_up Host api.anthropic.com
    }
}

http://:${OPENAI_PORT} {
    bind 127.0.0.1
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

# --- Refresh Daemon ---

# Start a background process that periodically refreshes OAuth tokens
# and reloads Caddy. Writes PID to a file for cleanup.
start_refresh_daemon() {
    local pid_file="$CREDS_DIR/refreshd.pid"
    local log_file="$CREDS_DIR/refreshd.log"

    # Check if daemon is already running
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi

    (
        while true; do
            sleep 300  # Check every 5 minutes

            local auth_type
            auth_type=$(creds_get "ANTHROPIC_AUTH_TYPE")
            if [ "$auth_type" != "oauth" ]; then
                continue
            fi

            local old_token new_token
            old_token=$(creds_get "ANTHROPIC_API_KEY")

            # Re-import from keychain
            if import_claude_oauth 2>/dev/null; then
                new_token=$(creds_get "ANTHROPIC_API_KEY")
                if [ "$old_token" != "$new_token" ]; then
                    echo "$(date -Iseconds) Token refreshed" >> "$log_file"
                    # Regenerate Caddyfile and reload Caddy
                    generate_caddyfile
                    caddy reload --config "$CADDY_FILE" --adapter caddyfile 2>/dev/null || true
                fi
            fi
        done
    ) &
    echo $! > "$pid_file"
    disown
}

# --- Hooks ---

start() {
    local vm="$1"
    refresh_if_needed
    generate_caddyfile
    if is_caddy_running; then
        caddy reload --config "$CADDY_FILE" --adapter caddyfile >/dev/null 2>&1 || warn "Caddy reload failed"
    else
        caddy start --config "$CADDY_FILE" --adapter caddyfile >/dev/null 2>&1
        sleep 1
        if ! is_caddy_running; then
            die "Failed to start Caddy proxy"
        fi
    fi
    local auth_type
    auth_type=$(creds_get "ANTHROPIC_AUTH_TYPE")
    [[ "$auth_type" == "oauth" ]] && start_refresh_daemon
    success "API proxy running (Anthropic :$ANTHROPIC_PORT, OpenAI :$OPENAI_PORT)"
}

rm() {
    # shellcheck disable=SC2034
    local vm="$1"
    info "Caddy proxy left running (may be shared with other airlocks). Stop manually: caddy stop"
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
