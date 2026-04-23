#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

provision() {
    local vm="$1"
    aq exec "$vm" sh <<'PROVISION'
set -eu
apk add nodejs npm build-base python3

# Install Claude Code globally
npm install -g @anthropic-ai/claude-code

# Install mise for env var management
apk add mise

# Configure mise with proxy URLs for rlock user
su -l rlock -c '
    mkdir -p ~/.claude

    cat > ~/mise.toml <<MISE
[env]
ANTHROPIC_BASE_URL = "http://10.0.2.2:9110"
ANTHROPIC_API_KEY = "dummy"
MISE

    cat > ~/.claude/settings.json <<SETTINGS
{
    "permissions": {
        "allow": [],
        "deny": [],
        "additionalDirectories": []
    },
    "bypassPermissions": true
}
SETTINGS

    # Ensure mise activates in bash
    echo "eval \"\$(mise activate bash)\"" >> ~/.bashrc
'

# Verify installation
su -l rlock -c "claude --version" && echo "AGENT_OK" || echo "AGENT_FAIL"
PROVISION
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
