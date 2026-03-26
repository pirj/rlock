# creds.sh -- Credential store management
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh and ui.sh to be sourced first.

# shellcheck shell=bash

# --- Constants ---

CREDS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rl"
CREDS_FILE="$CREDS_DIR/credentials"

# --- Credential Store ---

# Read a credential from the store. Returns empty string if not found.
creds_get() {
    local key="$1"
    if [ -f "$CREDS_FILE" ]; then
        grep "^${key}=" "$CREDS_FILE" 2>/dev/null | head -1 | cut -d= -f2-
    fi
}

# Set a credential in the store. Creates the store if it doesn't exist.
creds_set() {
    local key="$1"
    local value="$2"
    mkdir -p "$CREDS_DIR"

    if [ -f "$CREDS_FILE" ]; then
        # Remove existing key if present
        local tmp="$CREDS_FILE.tmp"
        grep -v "^${key}=" "$CREDS_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$CREDS_FILE"
    fi

    echo "${key}=${value}" >> "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
}

# Resolve a credential: check store first, then fall back to env var.
creds_resolve() {
    local key="$1"
    local stored
    stored=$(creds_get "$key")
    if [ -n "$stored" ]; then
        printf '%s' "$stored"
        return 0
    fi
    # Fall back to environment variable
    local env_val="${!key:-}"
    if [ -n "$env_val" ]; then
        printf '%s' "$env_val"
        return 0
    fi
    return 1
}

# --- Auth Command ---

cmd_auth() {
    local provider="${1:-}"

    if [ -z "$provider" ]; then
        cat <<'EOF'
usage: rl auth <provider>

providers:
  anthropic    Set Anthropic API key (for Claude Code)
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
            _auth_api_key "ANTHROPIC_API_KEY" "Anthropic" "https://console.anthropic.com/settings/keys"
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

    # Regenerate Caddyfile and reload if Caddy is running
    if command -v generate_caddyfile >/dev/null 2>&1; then
        generate_caddyfile
        if is_caddy_running; then
            caddy reload --config "$CADDY_FILE" --adapter caddyfile 2>/dev/null \
                && success "Caddy reloaded with new key" \
                || warn "Caddy reload failed — restart with 'rl new'"
        fi
    fi
}

_auth_status() {
    local anthropic_key openai_key

    anthropic_key=$(creds_resolve "ANTHROPIC_API_KEY" 2>/dev/null) || true
    openai_key=$(creds_resolve "OPENAI_API_KEY" 2>/dev/null) || true

    printf '\n'
    if [ -n "$anthropic_key" ]; then
        local masked="${anthropic_key:0:8}...${anthropic_key: -4}"
        printf '  Anthropic: %s%s%s (%s)\n' "$GREEN" "configured" "$RESET" "$masked"
    else
        printf '  Anthropic: %snot set%s\n' "$YELLOW" "$RESET"
    fi

    if [ -n "$openai_key" ]; then
        local masked="${openai_key:0:8}...${openai_key: -4}"
        printf '  OpenAI:    %s%s%s (%s)\n' "$GREEN" "configured" "$RESET" "$masked"
    else
        printf '  OpenAI:    %snot set%s\n' "$YELLOW" "$RESET"
    fi
    printf '\n'

    if [ -z "$anthropic_key" ] && [ -z "$openai_key" ]; then
        info "Run 'rl auth anthropic' or 'rl auth openai' to configure."
    fi
}
