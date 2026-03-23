# Pitfalls Research

**Domain:** VM-based AI agent isolation CLI tool (QEMU + Caddy + shell script)
**Researched:** 2026-03-24
**Confidence:** HIGH (most pitfalls verified via official docs and multiple community sources)

## Critical Pitfalls

### Pitfall 1: Caddy Binds to All Interfaces, Leaking API Keys to the Network

**What goes wrong:**
Caddy's default behavior is to bind to the wildcard (0.0.0.0) interface. If the Caddyfile does not explicitly `bind 127.0.0.1`, the reverse proxy that injects Authorization headers with API keys becomes accessible to every device on the local network. Any machine on the same WiFi or LAN can hit the proxy endpoint and use the user's Anthropic/OpenAI API keys.

**Why it happens:**
Caddy's `bind` directive only accepts a host, not a port, and must be set explicitly. Developers test on localhost, see it working, and never realize the proxy is also listening on all external interfaces. The QEMU guest reaches the host via 10.0.2.2 regardless of which interface Caddy listens on, so the misconfiguration is invisible during development.

**How to avoid:**
Always include `bind 127.0.0.1` in the Caddyfile site block. Verify with `lsof -i :<port>` or `ss -tlnp` that the listening socket is bound to 127.0.0.1, not 0.0.0.0. Add a startup check in the `lr` script that validates the bind address before accepting connections.

**Warning signs:**
- `netstat` or `lsof` shows Caddy listening on `*:<port>` or `0.0.0.0:<port>`
- Caddy logs show connections from unexpected source IPs
- API usage spikes from unknown sources

**Phase to address:**
Phase 1 (Caddy proxy setup) -- this must be correct from the first line of the Caddyfile. No "fix later."

---

### Pitfall 2: Pushing to a Non-Bare Repository Silently Fails or Corrupts the Working Tree

**What goes wrong:**
The design has the host adding the guest as a git remote. When the guest pushes to the host's working repository (non-bare), git refuses the push by default with `receive.denyCurrentBranch`. Developers then set `receive.denyCurrentBranch=ignore` or `updateInstead`, which either silently leaves the working tree out of sync (ignore) or can cause data loss if the host has uncommitted changes (updateInstead).

**Why it happens:**
Git is designed to prevent pushes to checked-out branches in non-bare repos. The natural workflow (guest pushes code to host) collides directly with this protection. Most tutorials suggest bare repos, but here the host repo IS the user's working repo.

**How to avoid:**
Do NOT push from guest to host's checked-out branch. Instead, use a pull-based workflow: the guest commits to its own branch, and `lr` on the host runs `git fetch guest <branch>` then `git merge` or `git cherry-pick`. Alternatively, push to a separate branch on the host that is never checked out. The `lr code` command should handle the fetch/merge step automatically after the session ends.

**Warning signs:**
- Host working tree does not reflect pushed commits
- `git status` on host shows unexpected changes after a push from guest
- Error messages about `receive.denyCurrentBranch`

**Phase to address:**
Phase 1 (git remote setup) -- the git workflow design must be correct before any coding sessions happen.

---

### Pitfall 3: QEMU Guest Cannot Reach Host's Caddy Proxy Due to macOS Firewall or Bind Address

**What goes wrong:**
The QEMU guest tries to reach Caddy at `10.0.2.2:<port>` (the SLIRP gateway), but the connection is refused or times out. This happens because: (a) macOS Application Layer Firewall silently blocks unsigned binaries from accepting inbound connections, (b) Caddy is bound to 127.0.0.1 which does not accept connections arriving via the QEMU gateway interface, or (c) the port is blocked by a host firewall rule.

**Why it happens:**
QEMU user-mode networking (SLIRP) routes guest traffic through the host's network stack. When the guest connects to 10.0.2.2, traffic arrives at the host as if from an external source -- but 127.0.0.1 only accepts traffic from the loopback interface. macOS also prompts "Do you want to allow incoming connections?" for unsigned binaries, and users may click "Deny" without understanding the consequence.

**How to avoid:**
Caddy must bind to `0.0.0.0` (or specifically to the internal gateway address) AND be restricted via Caddy's `remote_ip` matcher to only accept requests from the QEMU SLIRP subnet (10.0.2.0/24). This solves both the reachability problem and the API key leakage concern from Pitfall 1 simultaneously. On macOS, either code-sign the Caddy binary or instruct users to allow Caddy through the firewall during setup.

**Note:** This directly conflicts with Pitfall 1. The resolution is: bind to 0.0.0.0 but use `@allowed remote_ip 10.0.2.0/24 127.0.0.1` to restrict which source IPs can access the proxy. This is safer than bind-based restriction alone.

**Warning signs:**
- `curl http://10.0.2.2:<port>` from inside the VM returns "Connection refused"
- macOS firewall popup appears each time Caddy starts
- Caddy access logs show no incoming connections from the guest

**Phase to address:**
Phase 1 (Caddy proxy + networking) -- must be validated end-to-end with an actual QEMU guest before building anything else.

---

### Pitfall 4: Orphaned QEMU Processes and Disk Images Accumulate Silently

**What goes wrong:**
QEMU processes continue running after the user thinks the VM is stopped. Disk images (qcow2 files) pile up as users create VMs with `lr new` but never explicitly destroy them. With each VM using up to 1GB of disk, this silently consumes storage. Stale PID files point to recycled process IDs, causing the `lr` script to send signals to unrelated processes.

**Why it happens:**
Shell scripts that spawn background QEMU processes lack robust lifecycle management. If `lr` is interrupted (Ctrl+C, terminal close, SSH disconnect), the cleanup handler may not fire. QEMU does not respond to SIGHUP by default, so closing the terminal leaves the VM running. PID files become stale when QEMU crashes, and PID recycling means `kill $(cat pidfile)` can kill the wrong process.

**How to avoid:**
1. Record the PID AND the process start time (or use a unique identifier via QEMU's `-name` flag) to detect stale PIDs.
2. Use `trap` to clean up on EXIT, INT, TERM, and HUP.
3. Validate PID ownership before sending signals: check that the process name matches `qemu-system-*`.
4. Implement `lr list` to show running VMs and `lr cleanup` to find and kill orphaned QEMU processes.
5. Use `qemu-img info` to track disk image sizes and warn when total disk usage exceeds a threshold.
6. On graceful shutdown, send SIGTERM first, wait, then SIGKILL only as a fallback.

**Warning signs:**
- `ps aux | grep qemu` shows processes the user did not expect
- Disk usage grows steadily in the VM storage directory
- `lr` commands report "VM already running" when the user thinks it is stopped
- `kill` errors about "No such process" from stale PID files

**Phase to address:**
Phase 1 (VM lifecycle via aq) for basic cleanup, Phase 2 (hardening) for robust orphan detection and `lr cleanup` command.

---

### Pitfall 5: Claude Code / Codex Refuse to Work Through the Proxy Due to TLS or Certificate Issues

**What goes wrong:**
Claude Code throws `SELF_SIGNED_CERT_IN_CHAIN` errors when connecting through Caddy. Codex CLI silently fails or returns authentication errors. The AI agents are installed and configured but cannot actually reach the API, making the entire tool useless.

**Why it happens:**
Caddy automatically provisions TLS certificates, including self-signed ones for non-public addresses. When Claude Code or Codex connect to `https://10.0.2.2:<port>`, they encounter Caddy's self-signed certificate. Node.js (which Claude Code runs on) rejects self-signed certificates by default. The guest VM does not have Caddy's CA certificate in its trust store. Additionally, if using `http://` instead of `https://`, some API clients may silently upgrade to HTTPS or refuse plaintext connections.

**How to avoid:**
Configure the Caddy reverse proxy to serve HTTP (not HTTPS) on the internal proxy port. Since traffic between guest and host never leaves the machine (SLIRP is in-process), TLS on this hop adds complexity without security benefit. Use Caddy's `http://` scheme explicitly in the site address. Set `ANTHROPIC_BASE_URL=http://10.0.2.2:<port>` and `OPENAI_BASE_URL=http://10.0.2.2:<port>` in the guest. If HTTPS is required, export `NODE_EXTRA_CA_CERTS` pointing to Caddy's root CA certificate copied into the guest.

**Warning signs:**
- Claude Code shows "connection refused" or SSL/TLS errors in the guest
- Codex CLI hangs or returns non-descriptive errors
- `curl -v http://10.0.2.2:<port>` from the guest returns unexpected redirect to HTTPS

**Phase to address:**
Phase 1 (proxy + agent configuration) -- cannot validate the core value proposition without working API connectivity.

---

### Pitfall 6: Shell Script Breaks Across macOS and Linux Due to GNU vs BSD Utility Differences

**What goes wrong:**
The `lr` shell script works on the developer's machine but breaks on users' machines. Common breakage: `sed -i` requires an empty string argument on macOS BSD sed (`sed -i ''`) but not on GNU sed. `readlink -f` does not exist on macOS. `grep -P` (Perl regex) is not available on macOS. `mktemp` has different flag semantics. Array syntax works in bash but not in POSIX sh (relevant since the constraint says "POSIX sh or bash").

**Why it happens:**
macOS ships BSD userland utilities that have subtly different flags and behavior from their GNU counterparts on Linux. The shebang `#!/bin/sh` invokes different shells: dash on Debian/Ubuntu, ash on Alpine, bash (old version 3.2) on macOS. Developers test on one platform and assume portability.

**How to avoid:**
1. Pick bash explicitly (`#!/usr/bin/env bash`) if using any bash-isms (arrays, `[[ ]]`, process substitution). Do not use `#!/bin/sh` with bash features.
2. Avoid `sed -i` entirely -- use `sed 'expression' file > tmp && mv tmp file` pattern.
3. Use `command -v` instead of `which` for checking binary availability.
4. Replace `readlink -f` with a POSIX-compatible function.
5. Use `printf` instead of `echo -e`.
6. Run ShellCheck in CI on every commit.
7. Test on both macOS and Alpine (the guest OS) since the script runs on the host (macOS/Linux) AND parts may run inside the guest (Alpine/ash).

**Warning signs:**
- ShellCheck warnings about non-portable constructs
- User bug reports that mention a different OS than the developer uses
- `[: unexpected operator` or `bad option` errors in CI or user logs

**Phase to address:**
Phase 1 (initial script creation) -- establish the shell dialect and portability rules from the first line of code. Enforce with ShellCheck in CI.

---

### Pitfall 7: qcow2 Disk Image Grows Beyond the 1GB Virtual Size on Host Disk

**What goes wrong:**
The qcow2 thin-provisioned disk image starts small but the file on the host grows to match or exceed the 1GB virtual size and never shrinks, even after the guest deletes files. With many VMs, host disk usage balloons unexpectedly.

**Why it happens:**
qcow2 is thin-provisioned: it only allocates host disk space as the guest writes data. But when the guest deletes files, the filesystem only marks blocks as free -- it does not zero them or issue TRIM/discard commands. The qcow2 image can only grow, never shrink, unless explicit maintenance is performed. Alpine Linux with apk cache, npm/node_modules, Claude Code installation, and Codex can easily fill 1GB.

**How to avoid:**
1. Consider whether 1GB is sufficient. Claude Code native installer plus Codex plus a meaningful codebase may exceed 1GB. Test the actual disk usage of a fully provisioned VM and size accordingly.
2. Enable virtio-blk with `discard=unmap` in QEMU args so guest TRIM operations actually free host disk space.
3. Run `fstrim -a` inside the guest periodically or on shutdown.
4. Document disk usage expectations for users and provide `lr disk-usage` or similar.

**Warning signs:**
- `du -sh` on the VM storage directory shows much more than expected
- Guest reports "No space left on device" during package installation
- Host disk fills up after creating several VMs

**Phase to address:**
Phase 1 (VM creation) for correct sizing, Phase 2 for TRIM/discard and disk management.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Hardcoding 10.0.2.2 gateway IP | Works immediately with QEMU SLIRP defaults | Breaks if aq or QEMU changes network config; impossible to run multiple VMs with different networks | MVP only -- extract to a config variable early |
| Storing Caddy config inline in the shell script | Single-file tool, no extra files to manage | Impossible to customize; messy quoting; hard to validate Caddyfile syntax | Never -- use a template file from the start |
| Skipping PID file validation (just `kill $(cat pidfile)`) | Simple, fewer lines of code | Kills wrong process after PID recycling; silent failures on stale files | Never -- always validate PID ownership |
| Using `receive.denyCurrentBranch=ignore` for git push | Guest can push directly to host | Host working tree silently becomes inconsistent | Never -- use fetch-based workflow or separate branch |
| Installing Claude Code via npm in guest | Familiar, well-documented | Requires Node.js + npm in guest (large), version pinning issues, musl compatibility concerns | Only if native installer fails on Alpine |
| Not cleaning up SSH known_hosts entries | One less step in VM lifecycle | known_hosts fills with stale entries; strict host checking failures on VM IP reuse | MVP only -- automate removal on `lr destroy` |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Claude Code + ANTHROPIC_BASE_URL | Setting HTTPS URL that triggers self-signed cert errors | Use `http://` for the internal proxy hop; Caddy handles HTTPS to the real API upstream |
| Codex CLI + OPENAI_BASE_URL | Assuming env var alone is enough; Codex also checks config.toml which may override | Set both the env var AND ensure no conflicting `openai_base_url` in `~/.codex/config.toml` inside the guest |
| Caddy + upstream API | Not setting the Host header; Anthropic/OpenAI APIs may reject requests with wrong Host | Use `header_up Host api.anthropic.com` (or api.openai.com) in the reverse_proxy block |
| Git remote via SSH | Using default SSH port 22 but QEMU hostfwd maps a different host port to guest port 22 | Use the forwarded port consistently; set the git remote URL with the correct port: `ssh://user@localhost:<forwarded_port>/path` |
| Alpine apk + Claude Code | Missing `libgcc`, `libstdc++`, `ripgrep` packages for the native installer | Run `apk add libgcc libstdc++ ripgrep` and `export USE_BUILTIN_RIPGREP=0` before installing |
| Alpine apk + Codex CLI | Codex is a Rust binary; may not have an Alpine/musl build available | Verify Codex provides a musl-compatible binary; if not, this is a blocker requiring alternative approach (e.g., glibc compat layer or building from source) |
| QEMU SLIRP + ICMP | Using `ping 10.0.2.2` to test connectivity | ICMP does not work through SLIRP; use `curl` or `nc` to test TCP connectivity instead |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| SLIRP networking overhead on large API responses | Slow streaming of Claude Code responses; noticeable latency vs direct API access | Acceptable for this use case; large payloads are rare in API traffic. Only switch to TAP/vmnet if users report actual latency issues | Unlikely to be a real problem -- API traffic is small payloads |
| qcow2 copy-on-write fragmentation | VM becomes sluggish after many write cycles; I/O-heavy operations (npm install, git clone) slow down | Use `preallocation=metadata` when creating the image if performance matters; run `qemu-img convert` to defragment | After heavy guest-side package installation or large repos |
| Starting Caddy per-session vs running as daemon | Each `lr code` invocation takes 1-2 seconds extra to start Caddy | Run Caddy as a persistent background daemon with `lr` managing its lifecycle; use Caddy's API to hot-reload config for new VMs | Noticeable at 3+ VMs or frequent session start/stop |
| SSH connection setup overhead | Each `lr code` takes 1-3 seconds for SSH handshake + host key verification | Use SSH connection multiplexing (`ControlMaster`, `ControlPath`, `ControlPersist`) in SSH config | Annoying but not a blocker at single-VM scale |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Caddy config file contains API keys in plaintext | Any process or user on the host can read API keys from the Caddyfile | Read API keys from environment variables using Caddy's `{env.ANTHROPIC_API_KEY}` placeholder syntax, never hardcode in the Caddyfile |
| Copying host SSH keys into the guest (via `--config ssh`) | Guest now has host's SSH identity; a compromised agent could use them | Never copy private SSH keys. Generate fresh keypairs for each VM. If the guest needs git access, use the host git remote approach instead |
| API key visible in process arguments | `ps aux` on host shows the full Caddy command line including any API keys passed as args | Use environment variables or config files (with proper permissions), never pass secrets as CLI arguments |
| Guest can probe host network services via 10.0.2.2 | AI agent could discover and interact with any service on the host's localhost | Accept this as inherent to the SLIRP architecture. Document the risk. For sensitive host services, bind them to specific interfaces other than 0.0.0.0, or use firewall rules |
| Opt-in config copying (`--config git`) leaks tokens | Git config may contain GitHub tokens, credential helpers, or signing keys | Parse and sanitize copied configs: only copy `user.name`, `user.email`, and safe aliases. Strip credentials, token helpers, and signing configuration |
| tmux session exposes previous session data | If VM is reused, tmux scrollback may contain sensitive output from prior sessions | Clear tmux history on session start with `tmux clear-history`; or use fresh tmux sessions per `lr code` invocation |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Silent failure when Caddy or QEMU is not installed | User runs `lr new`, gets cryptic error or nothing happens | Check all dependencies (`aq`, `caddy`, `git`, `qemu`) on first run; print clear error with install instructions for each missing dep |
| No feedback during VM boot | `lr new` takes 10-30 seconds for Alpine to boot; user thinks it hung | Print progress indicators: "Creating disk image... Starting VM... Waiting for SSH... Installing packages... Done." |
| SSH host key changes on VM recreation | User destroys and recreates a VM; SSH refuses to connect with "REMOTE HOST IDENTIFICATION HAS CHANGED" | Automatically remove the old host key entry when destroying a VM; use a dedicated `known_hosts` file for `lr` VMs |
| `lr code` fails but leaves orphaned processes | User must manually find and kill QEMU and Caddy processes | Implement robust error handling: if SSH connection fails, shut down the VM; if Caddy fails to start, do not start the VM |
| No visibility into what is running | User forgets whether a VM is running for a repo | Implement `lr status` showing: VM running/stopped, disk usage, last session time |
| Unclear how to get code out of the VM | User finishes a coding session but does not know how to merge changes back | Auto-run `git fetch guest` on session end; print "Changes available on branch guest/main. Run `git merge guest/main` to integrate." |

## "Looks Done But Isn't" Checklist

- [ ] **Caddy proxy works:** Guest can `curl` the proxy, but verify the Authorization header is actually being injected (test with `curl -v` and inspect upstream request headers)
- [ ] **API connectivity works:** Claude Code starts, but verify it can actually complete a prompt (not just start without errors -- some errors only appear on first API call)
- [ ] **Git remote works both directions:** Host can fetch from guest, but verify the guest can also fetch from host (needed for pulling in new code to work on)
- [ ] **VM has internet access:** Guest can reach proxy, but verify it can also reach external URLs (e.g., `curl https://example.com`) for docs and package installation
- [ ] **Config copying is safe:** `--config git` copies the file, but verify no tokens/credentials leaked (inspect the copied file in the guest)
- [ ] **VM cleanup works after crash:** `lr destroy` works for running VMs, but verify it also cleans up after QEMU crashes or `kill -9` (stale PID files, orphaned sockets)
- [ ] **Multiple VMs work simultaneously:** Single VM works, but verify port conflicts do not occur when two VMs are running (each needs unique SSH and proxy ports)
- [ ] **Script works on macOS AND Linux:** Tested on dev machine, but verify on the other platform (especially `sed`, `readlink`, `mktemp`, process management differences)

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| API keys exposed via Caddy misconfiguration | HIGH | Rotate all exposed API keys immediately; audit Caddy bind configuration; add IP restriction matcher |
| Orphaned QEMU processes | LOW | `pkill -f qemu-system`; remove stale PID files; add `lr cleanup` command for future |
| Git push corrupted host working tree | MEDIUM | `git reset --hard` on host to last known good commit; switch to fetch-based workflow; any uncommitted host changes are lost |
| qcow2 disk images filling host disk | LOW | `lr destroy` old VMs; `qemu-img convert` to reclaim space on kept images; add disk usage monitoring |
| SSH host key mismatch blocking connection | LOW | Remove offending entry from known_hosts; or delete and regenerate the `lr`-specific known_hosts file |
| Claude Code TLS errors in guest | LOW | Switch Caddy to HTTP for the internal hop; or copy Caddy's CA cert to guest and set `NODE_EXTRA_CA_CERTS` |
| Shell script fails on different OS | MEDIUM | Run ShellCheck; replace non-portable constructs; test on both macOS and Alpine; may require significant refactoring if bash-isms are pervasive |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Caddy binds to all interfaces (API key leak) | Phase 1: Proxy setup | `lsof -i :<port>` shows 127.0.0.1 or remote_ip matcher in place; test from external machine fails |
| Push to non-bare repo fails | Phase 1: Git remote setup | `git push` from guest; verify host working tree reflects changes via fetch workflow |
| Guest cannot reach proxy | Phase 1: Networking | `curl http://10.0.2.2:<port>` from inside guest returns 200 |
| Orphaned QEMU processes | Phase 1: Basic lifecycle; Phase 2: Robust cleanup | After `lr destroy`, `ps aux | grep qemu` shows no orphans; after kill -9 of `lr`, run `lr cleanup` |
| TLS/certificate errors | Phase 1: Agent configuration | Claude Code completes a real prompt from inside the guest |
| Shell portability | Phase 1: Script creation (ShellCheck from day 1) | CI runs on both macOS and Linux; ShellCheck passes with zero warnings |
| Disk image growth | Phase 1: Correct sizing; Phase 2: TRIM | `du -sh <image>` after guest deletes files shows reduced size (with TRIM); guest does not hit "disk full" during standard setup |
| API keys in Caddyfile plaintext | Phase 1: Caddy config | `grep -r "sk-" .` in project directory finds zero hardcoded keys |
| Config copy leaks secrets | Phase 2: Config management | Copied git config in guest contains no tokens or credential helpers |
| Multiple VM port conflicts | Phase 2: Multi-VM support | Two simultaneous VMs can both reach their respective proxies |

## Sources

- [Caddy bind directive documentation](https://caddyserver.com/docs/caddyfile/directives/bind)
- [Caddy reverse_proxy documentation](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Caddy automatic HTTPS documentation](https://caddyserver.com/docs/automatic-https)
- [QEMU networking documentation](https://www.qemu.org/docs/master/system/devices/net.html)
- [QEMU/Networking Wikibooks](https://en.wikibooks.org/wiki/QEMU/Networking)
- [QEMU networking on macOS](https://dev.to/krjakbrjak/qemu-networking-on-macos-549k)
- [Claude Code enterprise network configuration](https://code.claude.com/docs/en/network-config)
- [Claude Code advanced setup (Alpine requirements)](https://code.claude.com/docs/en/setup)
- [OpenAI Codex advanced configuration](https://developers.openai.com/codex/config-advanced)
- [OpenAI Codex configuration reference](https://developers.openai.com/codex/config-reference)
- [Git receive.denyCurrentBranch documentation](https://gist.github.com/mendeza/eaeafb1c0e018ffd472bc8fae2a8462c)
- [Shell script portability guide (POSIX)](https://oneuptime.com/blog/post/2026-02-13-posix-shell-compatibility/view)
- [Cross-platform shell: Linux vs macOS differences](https://tech-champion.com/programming/write-cross-platform-shell-linux-vs-macos-differences-that-break-production/)
- [SSH agent security pitfalls](https://rabexc.org/posts/pitfalls-of-ssh-agents)
- [SSH agent best practices (Teleport)](https://goteleport.com/blog/how-to-use-ssh-agent-safely/)
- [qcow2 disk space reclamation (Proxmox wiki)](https://pve.proxmox.com/wiki/Shrink_Qcow2_Disk_Files)
- [macOS firewall and QEMU networking workaround](https://gist.github.com/adityakunapuli/c005d2d6f2d9d163d97652a438876a27)
- [tmux zombie session issue](https://github.com/tmux/tmux/issues/298)
- [Alpine Linux Node.js/npm package issues](https://pkgs.alpinelinux.org/package/edge/community/x86/npm)
- [Caddy issue: binds to all interfaces unexpectedly](https://github.com/caddyserver/caddy/issues/6009)

---
*Pitfalls research for: VM-based AI agent isolation CLI tool*
*Researched: 2026-03-24*
