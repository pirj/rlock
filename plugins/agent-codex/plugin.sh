#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

provision() {
    local vm="$1"
    aq exec "$vm" sh <<'PROVISION'
set -eu
apk add nodejs npm build-base python3

# Install Codex globally
npm install -g @openai/codex

# Install mise for env var management (if not already present)
apk add mise 2>/dev/null || true

# Configure mise with proxy URLs for rlock user
su -l rlock -c '
    mkdir -p ~/.codex

    # Add OpenAI env vars to mise.toml (append if exists)
    if [ -f ~/mise.toml ]; then
        grep -q "OPENAI_BASE_URL" ~/mise.toml || cat >> ~/mise.toml <<MISE
OPENAI_BASE_URL = "http://10.0.2.2:9111/v1"
OPENAI_API_KEY = "dummy"
MISE
    else
        cat > ~/mise.toml <<MISE
[env]
OPENAI_BASE_URL = "http://10.0.2.2:9111/v1"
OPENAI_API_KEY = "dummy"
MISE
    fi

    cat > ~/.codex/config.toml <<CONFIG
openai_base_url = "http://10.0.2.2:9111/v1"
CONFIG

    # Ensure mise activates in bash
    grep -q "mise activate" ~/.bashrc || echo "eval \"\$(mise activate bash)\"" >> ~/.bashrc
'

# Verify installation
su -l rlock -c "codex --version" && echo "AGENT_OK" || echo "AGENT_FAIL"
PROVISION
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
