#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_DIR/plugin.sh"

# --- Auth Subcommands ---

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
    generate_caddyfile
    if is_caddy_running; then
        if caddy reload --config "$CADDY_FILE" --adapter caddyfile 2>/dev/null; then
            success "Caddy reloaded with new credentials"
        else
            warn "Caddy reload failed -- will pick up on next 'rl new'"
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

# --- Main Dispatch ---

case "${1:-status}" in
    anthropic) _auth_anthropic ;;
    openai)    _auth_api_key "OPENAI_API_KEY" "OpenAI" "https://platform.openai.com/api-keys" ;;
    status)    _auth_status ;;
    *)         die "Usage: rl auth [anthropic|openai|status]" ;;
esac
