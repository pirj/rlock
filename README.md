# ai.rlock

Run AI coding agents in full "danger mode" — completely isolated inside QEMU virtual machines. Code stays in the VM, secrets stay on your machine, and the only bridge is git.

## The Problem

AI coding agents like Claude Code and Codex are powerful but dangerous. They execute arbitrary shell commands, modify files, and install packages. Running them on your host machine means:

- A hallucinated `rm -rf /` away from disaster
- API keys and SSH credentials exposed to untrusted code
- No rollback when an agent trashes your project

Containers (Docker) share the host kernel — a determined agent can escape. You need real isolation.

### Supply Chain Risk

AI agents install packages. Those packages can be compromised. When an agent runs `npm install` or `pip install` on your host, a backdoored dependency gets full access to your filesystem, credentials, and network.

This isn't hypothetical:

- **LiteLLM (March 2026)** — Attackers backdoored the [litellm PyPI package](https://docs.litellm.ai/blog/security-update-march-2026) (3.4M downloads/day) via a poisoned Trivy GitHub Action in CI/CD. The compromised versions included a credential stealer that exfiltrated API keys and environment variables — exactly the secrets AI proxy tools handle.
- **event-stream (2018)** — A maintainer [transferred ownership](https://www.blackduck.com/blog/malicious-dependency-supply-chain.html) of a popular npm package (2M downloads/week) to a stranger who injected code targeting cryptocurrency wallets with balances over 100 BTC.
- **PyTorch nightly (2022)** — A dependency confusion attack on `torchtriton` let attackers run arbitrary code on machines installing PyTorch nightly builds, exfiltrating hostname, username, and `.gitconfig`.

With `rl`, a compromised package installs inside the VM. It sees dummy API keys, has no access to your host filesystem, and can't reach your SSH keys or git credentials. The blast radius is one disposable VM.

## How It Works

`rl` creates a lightweight virtual machine per repository using [aq](https://github.com/pirj/aq) (QEMU, Alpine Linux). The VM has no access to your host filesystem, credentials, or network identity.

```
┌─────────────────────────────────────┐
│            Host Machine             │
│  ┌────────────────┐                 │
│  │ Caddy Proxy    │ :9110 Anthropic │
│  │ (injects       │ :9111 OpenAI    │
│  │  auth headers) │                 │
│  └───────┬────────┘                 │
│          │ 10.0.2.2                 │
│  ════════╪══════════════════════    │
│          │ QEMU VM                  │
│  ┌───────┴───────────────────┐      │
│  │  ↕ git only               │      │
│  │  Alpine Linux             │      │
│  │  Claude Code / Codex      │      │
│  └───────────────────────────┘      │
└─────────────────────────────────────┘
```

1. **VM isolation** — the agent runs inside a QEMU VM with its own kernel. No shared filesystem, no host access.
2. **Secret injection** — API keys never enter the VM. A Caddy reverse proxy on the host intercepts API requests and injects real credentials. The VM only has dummy keys.
3. **Git bridge** — code moves between host and guest exclusively via git. The host adds the guest as a remote over SSH.

## Commands

### `rl new`

Create a new isolated VM for the current repository.

```
$ rl new
  ✓ API proxy ready
  ✓ VM created
  ✓ VM booted
  ✓ SSH ready
  ✓ Guest provisioned
Airlock ready: ai.rlock
```

Provisions an Alpine VM with git, tmux, bash, and mise-en-place. Starts the Caddy proxy if not already running. The VM name is derived from the current directory.

### `rl code`

Connect to the VM's coding session via SSH + tmux.

```
$ rl code
```

Attaches to (or creates) a tmux session inside the VM at `/root/repo`. If the VM is stopped, starts it automatically. Detach with `Ctrl-B D` — the session persists.

### `rl status`

Show the current repo's airlock status.

```
$ rl status
ai.rlock: running (pid 12345, ssh :2222)
```

### `rl rm`

Destroy the VM and clean up local state.

```
$ rl rm
Removed airlock: ai.rlock
```

Destroys the VM via `aq rm` and removes the `.rl/` state directory. The Caddy proxy keeps running for other airlocks.

### `rl auth`

Configure API keys for AI agents. Keys are stored in `~/.config/rl/credentials` (chmod 600).

```
$ rl auth anthropic    # Set Anthropic API key (for Claude Code)
$ rl auth openai       # Set OpenAI API key (for Codex)
$ rl auth status       # Show which credentials are configured
```

Keys can also be provided via environment variables (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). The credential store takes priority over env vars.

### `rl help`

Show usage information.

## Prerequisites

| Dependency | Install |
|------------|---------|
| [aq](https://github.com/pirj/aq) | `git clone https://github.com/pirj/aq` |
| [QEMU](https://www.qemu.org) | `brew install qemu` / `apt install qemu-system` |
| [Caddy](https://caddyserver.com) | `brew install caddy` / `apt install caddy` |
| git | Pre-installed on macOS/Linux |
| ssh | Pre-installed on macOS/Linux |

## Quick Start

```sh
# Install prerequisites (macOS)
brew install qemu caddy

# Clone and set up aq
git clone https://github.com/pirj/aq
export PATH="$PWD/aq:$PATH"

# Configure API keys
rl auth anthropic

# Create an airlock and start coding
cd your-project
rl new
rl code
```

## p.rlock
