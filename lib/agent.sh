# agent.sh -- AI agent installation inside guest VMs
#
# This file is sourced by the rl entry point. Do not execute directly.
# Requires util.sh and ui.sh to be sourced first.

# shellcheck shell=bash

# --- Host Detection ---

# detect_host_agents -- find which agent binaries are available on the host
# Populates the DETECTED_AGENTS array.
detect_host_agents() {
    DETECTED_AGENTS=()
    if command -v claude >/dev/null 2>&1; then
        DETECTED_AGENTS+=("claude")
    fi
    if command -v codex >/dev/null 2>&1; then
        DETECTED_AGENTS+=("codex")
    fi
}

# --- Guest Installation ---

# install_agent_in_guest -- install an agent inside the guest VM
# Args: $1=vm_name, $2=agent_name
# Returns: 0 if output contains AGENT_OK, 1 otherwise
install_agent_in_guest() {
    local vm_name="$1"
    local agent="$2"
    local output

    case "$agent" in
        claude) output=$(_install_claude_code "$vm_name") ;;
        codex)  output=$(_install_codex "$vm_name") ;;
        *)      return 1 ;;
    esac

    echo "$output"
    if echo "$output" | grep -q "AGENT_OK"; then
        return 0
    fi
    return 1
}

# _install_claude_code -- install Claude Code inside the guest (D-04, D-05, D-07)
_install_claude_code() {
    local vm_name="$1"
    aq exec "$vm_name" <<'PROVISION_CLAUDE'
set -e

# Install Node.js, npm, and native deps (D-04, D-05)
apk add --no-cache nodejs npm libgcc libstdc++

# Install Claude Code globally, discard npm cache (Pitfall 6)
npm install -g @anthropic-ai/claude-code --cache /tmp/npm-cache
rm -rf /tmp/npm-cache

# Allow all tools — bypassPermissions is blocked when running as root,
# so we allow each tool explicitly instead (same effect, no root check)
mkdir -p /root/.claude
cat > /root/.claude/settings.json <<'SETTINGS'
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Edit",
      "Write",
      "Read",
      "Glob",
      "Grep",
      "WebSearch",
      "WebFetch",
      "NotebookEdit"
    ]
  }
}
SETTINGS

# Verify installation
claude --version >/dev/null 2>&1 || exit 1

echo "AGENT_OK"
PROVISION_CLAUDE
}

# _install_codex -- install Codex CLI inside the guest (D-08, D-09)
_install_codex() {
    local vm_name="$1"
    aq exec "$vm_name" <<'PROVISION_CODEX'
set -e

# Node.js may already be installed (if Claude Code was also requested)
apk add --no-cache nodejs npm

# Install Codex CLI globally (musl binary auto-selected by npm)
npm install -g @openai/codex --cache /tmp/npm-cache
rm -rf /tmp/npm-cache

# Write config.toml for base URL (belt-and-suspenders with mise env var, Pitfall 5)
mkdir -p /root/.codex
cat > /root/.codex/config.toml <<'CODEXCFG'
openai_base_url = "http://10.0.2.2:9111/v1"
CODEXCFG

# Verify installation
codex --version >/dev/null 2>&1 || exit 1

echo "AGENT_OK"
PROVISION_CODEX
}
