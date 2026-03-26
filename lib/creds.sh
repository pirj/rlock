# creds.sh -- Credential store and OAuth token management
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh and ui.sh to be sourced first.

# shellcheck shell=bash

# --- Constants ---

CREDS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rl"
CREDS_FILE="$CREDS_DIR/credentials"
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

# Resolve a credential: creds store → env var → empty.
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

    # Parse JSON — extract accessToken and refreshToken
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

# Refresh the OAuth access token using the refresh token.
# On success, updates the credential store and returns 0.
refresh_oauth_token() {
    local refresh_token
    refresh_token=$(creds_get "ANTHROPIC_REFRESH_TOKEN")
    if [ -z "$refresh_token" ]; then
        return 1
    fi

    # Re-import from keychain — Claude Code manages its own token refresh,
    # so the keychain always has the latest valid tokens.
    if import_claude_oauth; then
        return 0
    fi
    return 1
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
                    if command -v generate_caddyfile >/dev/null 2>&1; then
                        generate_caddyfile
                        caddy reload --config "$CADDY_FILE" --adapter caddyfile 2>/dev/null || true
                    fi
                fi
            fi
        done
    ) &
    echo $! > "$pid_file"
    disown
}

# --- Auth Command ---

cmd_auth() {
    local provider="${1:-}"

    if [ -z "$provider" ]; then
        cat <<'EOF'
usage: rl auth <provider>

providers:
  anthropic    Import Claude Code OAuth credentials (or set API key)
  openai       Set OpenAI API key (for Codex)
  status       Show which credentials are configured

examples:
  rl auth anthropic
  rl auth openai
  rl auth status
EOF
        return 0
    fi

    case "$provider" in
        anthropic)
            _auth_anthropic
            ;;
        openai)
            _auth_api_key "OPENAI_API_KEY" "OpenAI" "https://platform.openai.com/api-keys"
            ;;
        status)
            _auth_status
            ;;
        *)
            die "Unknown provider '$provider'. Use 'anthropic' or 'openai'."
            ;;
    esac
}

_auth_anthropic() {
    # Try OAuth import from Claude Code's keychain first
    info "Checking for Claude Code OAuth credentials..."

    if import_claude_oauth; then
        local token
        token=$(creds_get "ANTHROPIC_API_KEY")
        local masked="${token:0:12}...${token: -4}"
        success "Imported OAuth token from Claude Code: $masked"

        # Start refresh daemon for token lifecycle
        start_refresh_daemon
        success "Token refresh daemon started"

        # Regenerate Caddyfile and reload if Caddy is running
        _reload_proxy_if_running
        return 0
    fi

    # Fallback: manual API key entry
    warn "Claude Code OAuth credentials not found in keychain."
    info "Make sure you've run 'claude login' first, or enter an API key manually."
    printf '\n'
    printf '  1) Run claude login (then re-run rl auth anthropic)\n'
    printf '  2) Enter API key manually\n'
    printf '\n'
    printf 'Choice [1]: '
    read -r choice

    case "${choice:-1}" in
        1)
            if command -v claude >/dev/null 2>&1; then
                info "Running claude login..."
                claude login
                # Retry import after login
                if import_claude_oauth; then
                    success "OAuth credentials imported after login"
                    start_refresh_daemon
                    _reload_proxy_if_running
                else
                    warn "Could not import credentials after login. Try 'rl auth anthropic' again."
                fi
            else
                die "claude CLI not found. Install: npm install -g @anthropic-ai/claude-code"
            fi
            ;;
        2)
            _auth_api_key "ANTHROPIC_API_KEY" "Anthropic" "https://console.anthropic.com/settings/keys"
            creds_set "ANTHROPIC_AUTH_TYPE" "api_key"
            ;;
        *)
            die "Invalid choice."
            ;;
    esac
}

_auth_api_key() {
    local key_name="$1"
    local display_name="$2"
    local url="$3"

    local existing
    existing=$(creds_resolve "$key_name" 2>/dev/null) || true

    if [ -n "$existing" ]; then
        local masked="${existing:0:8}...${existing: -4}"
        info "Current $display_name key: $masked"
        printf 'Replace? (y/N) '
        read -r reply
        if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
            return 0
        fi
    fi

    info "Get your $display_name API key from: $url"
    printf '%s API key: ' "$display_name"
    read -rs api_key
    printf '\n'

    if [ -z "$api_key" ]; then
        die "No key provided."
    fi

    creds_set "$key_name" "$api_key"
    success "$display_name key saved"
    _reload_proxy_if_running
}

_reload_proxy_if_running() {
    if command -v generate_caddyfile >/dev/null 2>&1; then
        generate_caddyfile
        if is_caddy_running; then
            caddy reload --config "$CADDY_FILE" --adapter caddyfile 2>/dev/null \
                && success "Caddy reloaded with new credentials" \
                || warn "Caddy reload failed — will pick up on next 'rl new'"
        fi
    fi
}

_auth_status() {
    local anthropic_key openai_key auth_type

    anthropic_key=$(creds_resolve "ANTHROPIC_API_KEY" 2>/dev/null) || true
    openai_key=$(creds_resolve "OPENAI_API_KEY" 2>/dev/null) || true
    auth_type=$(creds_get "ANTHROPIC_AUTH_TYPE")

    printf '\n'
    if [ -n "$anthropic_key" ]; then
        local masked="${anthropic_key:0:12}...${anthropic_key: -4}"
        local type_label="api_key"
        [ "$auth_type" = "oauth" ] && type_label="oauth"
        printf '  Anthropic: %s%s%s (%s, %s)\n' "$GREEN" "configured" "$RESET" "$type_label" "$masked"
    else
        printf '  Anthropic: %snot set%s\n' "$YELLOW" "$RESET"
    fi

    if [ -n "$openai_key" ]; then
        local masked="${openai_key:0:8}...${openai_key: -4}"
        printf '  OpenAI:    %s%s%s (%s)\n' "$GREEN" "configured" "$RESET" "$masked"
    else
        printf '  OpenAI:    %snot set%s\n' "$YELLOW" "$RESET"
    fi

    # Refresh daemon status
    local pid_file="$CREDS_DIR/refreshd.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
        printf '  Refresh:   %srunning%s (pid %s)\n' "$GREEN" "$RESET" "$(cat "$pid_file")"
    elif [ "$auth_type" = "oauth" ]; then
        printf '  Refresh:   %sstopped%s (run rl auth anthropic to restart)\n' "$YELLOW" "$RESET"
    fi
    printf '\n'

    if [ -z "$anthropic_key" ] && [ -z "$openai_key" ]; then
        info "Run 'rl auth anthropic' or 'rl auth openai' to configure."
    fi
}
