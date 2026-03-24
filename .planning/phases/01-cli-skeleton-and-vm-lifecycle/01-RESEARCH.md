# Phase 1: CLI Skeleton and VM Lifecycle - Research

**Researched:** 2026-03-24
**Domain:** Shell CLI tool wrapping pirj/aq for per-repo QEMU VM lifecycle
**Confidence:** HIGH

## Summary

Phase 1 creates the `rl` CLI with four subcommands (`new`, `code`, `status`, `rm`) that wrap the existing `pirj/aq` tool for VM lifecycle. The key insight from investigating the actual `aq` source (v1.6.0) is that aq already handles most VM mechanics: disk image creation from a shared base image, QEMU process management, SSH port allocation, and remote command execution. The `rl` tool is therefore a thin orchestration layer that (1) maps repo directories to VM names, (2) provisions the guest with tmux/git/openssh, (3) manages tmux session attach/create, and (4) stores per-repo state in `.rl/`.

Critical corrections from prior research: the host is ARM64 (Apple Silicon), so aq uses `qemu-system-aarch64` with HVF acceleration, NOT `qemu-system-x86_64`. Alpine version is 3.22.2, not 3.21.x. The CLI name is `rl`, not `lr`. SSH keys do NOT need per-VM generation -- aq copies the host's existing `~/.ssh/*.pub` into the base image at bootstrap time. The SSH port is ephemeral per-start (allocated dynamically via QEMU monitor), not stored persistently -- `aq stop` removes the port file.

**Primary recommendation:** Build `rl` as a Bash script compatible with macOS system bash 3.2 (avoid Bash 4+ features like associative arrays). Use `aq` as a black box for VM mechanics. Focus `rl` on: repo-to-VM name mapping, guest provisioning (tmux, git), tmux session management, state tracking in `.rl/`, and polished UX (spinner, colors, error messages).

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** VMs are auto-named from the current repo directory name (e.g. `ailockr`). No custom naming support in v1.
- **D-02:** Per-VM state (ports, PIDs, configs) lives in `.rl/` inside the repo directory. Add `.rl/` to `.gitignore`.
- **D-03:** If `rl new` is run when a VM already exists, error with hint: "VM already exists. Use `rl code` to connect or `rl rm` to destroy."
- **D-04:** User lands in `ash` (Alpine default shell) -- no extra packages needed.
- **D-05:** Working directory on connect is `~/repo` -- the repo checkout inside the VM.
- **D-06:** Single tmux window per session. User splits/creates windows as needed.
- **D-07:** Quiet by default with progress during slow operations (VM boot, package install).
- **D-08:** Progress indicator: braille code spinner (two chars wide, clockwise rotation) on the left, step label on the right. Each step overwrites the previous line (carriage return, no newline until done).
- **D-09:** Colored output with auto-detection -- colors when terminal supports it, plain when piped.
- **D-10:** `rl status` outputs a compact one-liner: e.g. "ailockr: running (pid 1234, ssh:2222)"
- **D-11:** Missing dependencies (aq, Caddy) produce a clear error with install hint: "aq not found. Install: brew install pirj/tap/aq"
- **D-12:** SSH failure on `rl code` fails immediately with error and suggests `rl status` to check VM state. No auto-retry.

### Claude's Discretion
- Exact braille spinner character sequence (as long as it's 2-char wide and clockwise)
- CLI help text formatting
- Internal lib/ module boundaries and sourcing strategy
- SSH key generation approach for host-to-guest access
- How aq is invoked (direct CLI calls vs wrapper functions)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| VM-01 | User can create a new per-repo VM with `rl new` (Alpine Linux via aq, with tmux and git pre-installed) | aq API fully mapped: `aq new <name>` creates VM, `aq start <name>` boots it, `aq exec <name>` provisions. Guest provisioning via `aq exec` with `apk add tmux git`. |
| VM-02 | User can destroy a VM and clean up resources with `rl rm` | `aq rm <name>` handles QEMU process kill + disk cleanup. `rl rm` additionally removes `.rl/` state dir. |
| VM-03 | User can check if current repo has an attached airlock with `rl status` | `aq ls` shows VM status (On/Off). `.rl/vm-name` file maps repo to VM. Combine for one-liner output. |
| SESS-01 | User can SSH into VM and start or resume a tmux coding session with `rl code` | `aq console <name>` provides SSH. tmux `-A` flag on `new-session` handles attach-or-create. Working dir `~/repo` set during provisioning. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

CLAUDE.md contains GSD workflow enforcement directives:
- Use GSD entry points (`/gsd:quick`, `/gsd:debug`, `/gsd:execute-phase`) for all repo edits
- Do not make direct repo edits outside a GSD workflow unless explicitly asked

No additional coding conventions, testing rules, or security requirements are specified beyond GSD workflow rules.

## Standard Stack

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Bash | 3.2+ (system) | CLI scripting language | macOS ships 3.2.57 at `/bin/bash`. Homebrew bash not installed on this machine. Must target 3.2 to avoid requiring users to install Homebrew bash. Arrays, local vars, `[[ ]]` all work in 3.2. Avoid associative arrays (`declare -A`), `${var,,}`, `readarray`. |
| pirj/aq | 1.6.0 | QEMU Alpine VM lifecycle | Already installed at `~/.bin/aq`. Handles VM create/start/stop/destroy, SSH port allocation, remote exec, file copy. `rl` wraps this. |
| QEMU | 10.0.3 (aarch64) | VM hypervisor | Installed via Homebrew. Uses `qemu-system-aarch64` with HVF acceleration on Apple Silicon. NOT x86_64. |
| Alpine Linux | 3.22.2 (guest) | Guest OS | Version hardcoded in aq. Uses aarch64 ISO. |
| tmux | 3.5a (host) | Session persistence in guest | Installed on host. Will be installed in guest via `apk add tmux`. |
| OpenSSH | 9.9p2 (host) | SSH into guest | Pre-installed. aq handles SSH config (StrictHostKeyChecking=no, random port). |
| Git | 2.47.1 (host) | Version control | Pre-installed. Will be installed in guest via `apk add git`. |
| ShellCheck | 0.11.0 | Shell linting | Installed. Use for CI and development. |

### Supporting

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `tput` | Terminal color capability detection | Color auto-detection (D-09). Check `tput colors` and `[ -t 1 ]`. |
| `printf` | Formatted output, spinner rendering | Braille spinner (D-08), colored output. Prefer over `echo -e` for portability. |
| `flock` / `mkdir` | Lockfile for port allocation | If concurrent `rl new` is a concern. `mkdir` is atomic and works as a lock. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Bash 3.2 | Bash 5.x via Homebrew | Would require `brew install bash` as prerequisite. Gains associative arrays. Not worth the dependency. |
| Direct aq calls | aq wrapper functions | Wrapper adds indirection but enables mocking for tests. Direct calls are simpler for Phase 1. |
| `.rl/` in repo | `~/.local/state/ailockr/` | XDG-compliant but user decided D-02: state in repo dir. |

## Architecture Patterns

### Recommended Project Structure

```
ailockr/
  rl                          # Main entry point (executable bash script)
  lib/
    vm.sh                     # VM lifecycle (wraps aq new/start/stop/rm)
    ssh.sh                    # SSH + tmux session management
    ui.sh                     # Spinner, colors, formatted output
    util.sh                   # Shared utilities (error handling, dependency checks)
```

### Pattern 1: Case-Statement Command Dispatch

**What:** `rl` entry point parses `$1` as subcommand, sources only the needed lib/ modules, dispatches to handler function.

**When to use:** This exact phase -- small command set (4 commands + help).

**Example:**
```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Source shared utilities (always needed)
. "$LIB_DIR/util.sh"
. "$LIB_DIR/ui.sh"

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
  new)
    . "$LIB_DIR/vm.sh"
    . "$LIB_DIR/ssh.sh"
    cmd_new "$@"
    ;;
  code)
    . "$LIB_DIR/vm.sh"
    . "$LIB_DIR/ssh.sh"
    cmd_code "$@"
    ;;
  status)
    . "$LIB_DIR/vm.sh"
    cmd_status "$@"
    ;;
  rm)
    . "$LIB_DIR/vm.sh"
    cmd_rm "$@"
    ;;
  help|--help|-h)
    cmd_help
    ;;
  *)
    die "Unknown command '$cmd'. Run 'rl help' for usage."
    ;;
esac
```

### Pattern 2: Per-Repo State in `.rl/`

**What:** Each repo gets a `.rl/` directory storing the VM name mapping and any rl-specific metadata. The actual VM data (disk image, QEMU sockets, PID) lives in aq's directory (`~/.local/share/aq/<vm-name>/`). `.rl/` is the bridge between the two.

**State file layout:**
```
.rl/
  vm-name              # Contains the aq VM name (e.g., "ailockr")
```

The key insight is that `.rl/` is intentionally minimal. The heavy state is in aq's domain. `rl` only needs to know which aq VM name belongs to this repo.

### Pattern 3: aq Interface Contract

**What:** The `rl` CLI delegates all QEMU operations to `aq`. Here is the complete aq API as verified from source:

| aq command | What it does | rl usage |
|------------|-------------|----------|
| `aq new [-p host:guest ...] [name]` | Creates VM dir, copies base image, stores port forwards. Outputs VM name on stdout. | `rl new` calls this with repo dir name |
| `aq start <name>` | Boots QEMU, waits for login prompt, does first-boot setup if needed, allocates SSH port dynamically | `rl new` calls after `aq new` |
| `aq stop <name>` | Sends `quit` to QEMU monitor, removes `ssh-port.conf` | `rl rm` calls before cleanup |
| `aq exec <name> [cmd]` | SSH into VM and run command (or pipe stdin as script) | `rl new` uses for guest provisioning |
| `aq exec <name> < script.sh` | Pipe a script into the VM via SSH | Alternative provisioning approach |
| `aq scp [...] src dest` | SCP files to/from VM | Not needed in Phase 1 |
| `aq console <name>` | Interactive SSH session | `rl code` could use, but we need tmux wrapping |
| `aq rm <name>` | Stops VM + removes entire VM directory | `rl rm` calls this |
| `aq ls` | Lists VMs with status (On/Off) and SSH port | `rl status` reads from this |

**Critical aq behaviors discovered from source:**
- `aq new` outputs the VM name to stdout (after "Created:" on stderr)
- `aq start` allocates a random SSH port (49152-65535) dynamically via QEMU monitor -- NOT stored in hostfwd.conf
- `aq stop` DELETES `ssh-port.conf` -- the SSH port is ephemeral per-start
- `aq` uses the host's existing `~/.ssh/*.pub` for root SSH access (baked into base image during bootstrap)
- VM data lives in `~/.local/share/aq/<name>/`
- `is_vm_running` checks PID file + `kill -0`
- SSH connection uses: `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $PORT root@localhost`

### Pattern 4: SSH + tmux Session Attach

**What:** `rl code` SSHes into the VM and attaches/creates a tmux session with the working directory set to `~/repo`.

**Key commands:**
```bash
# Get SSH port from aq's state
SSH_PORT=$(cat "$HOME/.local/share/aq/$VM_NAME/ssh-port.conf")

# Attach or create tmux session, starting in ~/repo
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "$SSH_PORT" \
    root@localhost \
    -t "tmux new-session -A -s rl -c /root/repo"
```

The `-A` flag on `tmux new-session` is the attach-or-create idiom: if session `rl` exists, attach to it; otherwise create it. The `-c /root/repo` sets the default directory for new windows.

### Pattern 5: Braille Spinner with Step Labels

**What:** Two-character-wide braille spinner that overwrites the current line, with a step label to the right.

**Recommended character sequence (clockwise 8-dot braille):**
```
⣾ ⢿ ⡿ ⣷ ⣯ ⢟ ⡻ ⣽
```

These are single-character glyphs that appear to rotate clockwise. For a 2-char-wide effect, use two characters from the sequence offset by 4 positions to create a paired rotation feel.

**Implementation pattern:**
```bash
SPINNER_CHARS=('⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇')

spinner_start() {
  local msg="$1"
  local i=0
  while true; do
    printf '\r  %s %s' "${SPINNER_CHARS[$((i % ${#SPINNER_CHARS[@]}))]}" "$msg"
    i=$((i + 1))
    sleep 0.08
  done &
  SPINNER_PID=$!
}

spinner_stop() {
  kill "$SPINNER_PID" 2>/dev/null
  wait "$SPINNER_PID" 2>/dev/null
  printf '\r  %s\n' "$1"  # Final message with checkmark or done
}
```

Note: For a 2-char-wide spinner, pair two braille characters or use 8-dot braille (`⣾⢿` etc.) which are visually wider. The exact sequence is Claude's discretion per CONTEXT.md.

### Pattern 6: Color Auto-Detection

**What:** Detect terminal color support and disable when piped.

```bash
setup_colors() {
  if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$(tput colors 2>/dev/null)" -ge 8 ] 2>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
  else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
  fi
}
```

### Anti-Patterns to Avoid

- **Reimplementing aq:** Do not call `qemu-system-aarch64` directly. aq handles QEMU flags, base image management, first-boot setup, and SSH port allocation. Bypass aq only if it genuinely cannot do something.
- **Storing SSH port independently:** aq manages SSH port allocation (random port per-start, stored in `~/.local/share/aq/<name>/ssh-port.conf`). Do not generate or track a separate SSH port in `.rl/`.
- **Generating per-VM SSH keys:** aq bakes the host's `~/.ssh/*.pub` into the base image. All VMs share the host user's public key. This is fine for local-only VMs.
- **Using Bash 4+ features:** No associative arrays (`declare -A`), no case modification (`${var,,}`), no `readarray`/`mapfile`, no `coproc`. macOS system bash is 3.2.
- **Using `echo -e`:** Non-portable. Use `printf` instead.
- **Using `sed -i`:** Different syntax on macOS BSD sed vs GNU sed. Avoid entirely or use `sed '...' file > tmp && mv tmp file`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| VM creation and QEMU management | Custom QEMU invocation scripts | `aq new` / `aq start` / `aq stop` | aq handles base image, UEFI vars, disk creation, QEMU flags, first-boot setup, SSH port allocation. Hundreds of lines of complexity. |
| SSH into guest | Custom SSH wrapper with port tracking | `aq exec` for commands, aq's SSH port file for interactive sessions | aq already generates random ports and stores them. It handles StrictHostKeyChecking. |
| File copy to/from guest | Custom SCP wrapper | `aq scp` | Handles port lookup, SSH options, direction detection. |
| VM status checking | PID file parsing + process validation | aq's `is_vm_running` (via `aq ls`) | aq checks PID file + `kill -0` correctly. |
| Base image management | Alpine ISO download, bootstrap scripts | aq's `ensure_base_image` / `bootstrap_base_image` | aq handles ISO GPG verification, automated setup via tio/socat scripting, disk partitioning, first-boot resize. |

**Key insight:** aq does the hard QEMU work. `rl` is a UX and orchestration layer on top. The primary value `rl` adds is: (1) mapping repos to VMs, (2) guest provisioning with the right packages, (3) tmux session management, (4) polished terminal UX.

## Common Pitfalls

### Pitfall 1: SSH Port Not Available After `aq start`

**What goes wrong:** `aq start` returns, but the SSH port file (`ssh-port.conf`) isn't written yet, or SSH isn't listening in the guest yet.
**Why it happens:** `aq start` allocates the SSH port dynamically via QEMU monitor after the VM boots. There's a race between aq's port setup and `rl` trying to read the port file. Also, the guest's SSH daemon takes a few seconds to start after boot.
**How to avoid:** After `aq start`, wait for `ssh-port.conf` to exist, then poll SSH connectivity: `ssh -o ConnectTimeout=2 -p $PORT root@localhost true`. Retry with a timeout (e.g., 30 seconds).
**Warning signs:** "Connection refused" on SSH, missing `ssh-port.conf` file.

### Pitfall 2: VM Name Collision

**What goes wrong:** Two repos in different directories have the same directory name. `rl new` in both creates a name collision in aq.
**Why it happens:** Decision D-01 names VMs from the repo directory basename. `/home/user/work/myapp` and `/home/user/projects/myapp` both produce VM name `myapp`.
**How to avoid:** Check if aq VM already exists before creating. If collision detected, error with a clear message. The user can rename one directory or a future version can add suffixes.
**Warning signs:** `aq new myapp` fails because directory already exists in `~/.local/share/aq/`.

### Pitfall 3: `aq stop` Deletes SSH Port -- Cannot Reconnect

**What goes wrong:** If `rl` calls `aq stop` (e.g., for a restart), the SSH port file is deleted. On `aq start`, a NEW random port is allocated. Any cached port in `.rl/` becomes stale.
**Why it happens:** aq treats SSH ports as ephemeral per-start. `aq_stop()` runs `rm -f "$BASE_DIR/$VM_NAME/ssh-port.conf"`.
**How to avoid:** Always read the SSH port fresh from aq's state directory (`~/.local/share/aq/<name>/ssh-port.conf`), never cache it in `.rl/`. Design `rl` to tolerate the port changing between stops and starts.
**Warning signs:** SSH connection to old port fails with "Connection refused."

### Pitfall 4: Spinner Breaks When Not a TTY

**What goes wrong:** The braille spinner and carriage-return line overwriting produce garbage when output is piped or redirected.
**Why it happens:** Pipes don't support carriage return positioning. The spinner characters and `\r` get written literally to the file/pipe.
**How to avoid:** Gate spinner output on `[ -t 2 ]` (stderr is a TTY). When not a TTY, fall back to simple line-by-line progress: `Creating VM...`, `Installing packages...`, `Done.`
**Warning signs:** Garbled output in CI logs or when piping `rl new 2>&1 | tee log`.

### Pitfall 5: `rl rm` Fails to Clean Up If aq VM Was Already Deleted Manually

**What goes wrong:** User runs `aq rm myapp` directly, then `rl rm` in the repo fails because the aq VM is gone but `.rl/` still exists.
**Why it happens:** `.rl/vm-name` references an aq VM that no longer exists.
**How to avoid:** `rl rm` should handle the case where the aq VM doesn't exist: clean up `.rl/` anyway and print a note. Use `aq ls` or check directory existence rather than assuming the VM is present.
**Warning signs:** Error messages from aq about non-existent VM.

### Pitfall 6: macOS System Bash 3.2 Limitations

**What goes wrong:** Script uses `declare -A` (associative arrays), `${var,,}` (lowercase), `readarray`, or `|&` (pipe stderr) -- all Bash 4+ features that fail on macOS system bash.
**Why it happens:** Developer has Homebrew bash in their PATH but the shebang resolves to system bash, or the script is tested only on Linux.
**How to avoid:** Use `#!/bin/bash` (or `#!/usr/bin/env bash`). Run ShellCheck with `--shell=bash`. Test on macOS system bash explicitly. Use indexed arrays (work in 3.2), `tr '[:upper:]' '[:lower:]'` for case conversion, `while read` loops instead of `readarray`.
**Warning signs:** ShellCheck warnings about bash version compatibility. "bad substitution" errors on macOS.

### Pitfall 7: Guest Provisioning Fails Silently via `aq exec`

**What goes wrong:** `aq exec myapp 'apk add tmux git'` returns success even if the package install failed inside the VM.
**Why it happens:** `aq exec` pipes commands through SSH. If the remote command fails, the SSH exit code may not propagate correctly depending on how the command is structured (especially with heredocs).
**How to avoid:** Use explicit error checking in provisioning scripts: `set -e` at the top, check `apk add` exit codes, echo a sentinel string at the end and verify it appeared in output.
**Warning signs:** Packages not available in guest after provisioning. `which tmux` returns nothing.

## Code Examples

### VM Name from Repo Directory

```bash
# Get VM name from current directory (D-01)
get_vm_name() {
  basename "$(pwd)"
}
```

### `.rl/` State Management

```bash
RL_DIR=".rl"

ensure_rl_dir() {
  mkdir -p "$RL_DIR"
  # Add to .gitignore if not already there
  if [ -f .gitignore ]; then
    grep -qxF '.rl/' .gitignore || echo '.rl/' >> .gitignore
  else
    echo '.rl/' > .gitignore
  fi
}

get_saved_vm_name() {
  [ -f "$RL_DIR/vm-name" ] && cat "$RL_DIR/vm-name"
}

save_vm_name() {
  ensure_rl_dir
  printf '%s' "$1" > "$RL_DIR/vm-name"
}
```

### Reading SSH Port from aq State

```bash
AQ_STATE_DIR="$HOME/.local/share/aq"

get_ssh_port() {
  local vm_name="$1"
  local port_file="$AQ_STATE_DIR/$vm_name/ssh-port.conf"
  [ -f "$port_file" ] && cat "$port_file"
}

wait_for_ssh() {
  local vm_name="$1"
  local timeout="${2:-60}"
  local elapsed=0

  # Wait for port file to appear
  while [ ! -f "$AQ_STATE_DIR/$vm_name/ssh-port.conf" ] && [ "$elapsed" -lt "$timeout" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done

  local port
  port=$(get_ssh_port "$vm_name") || return 1

  # Wait for SSH to accept connections
  while [ "$elapsed" -lt "$timeout" ]; do
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -p "$port" root@localhost true 2>/dev/null; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}
```

### Dependency Checking with Install Hints (D-11)

```bash
check_dependency() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "$cmd not found. Install: $hint"
  fi
}

check_all_deps() {
  check_dependency "aq"    "brew install pirj/tap/aq"
  check_dependency "qemu-system-aarch64" "brew install qemu"
  check_dependency "git"   "brew install git"
  check_dependency "ssh"   "Install OpenSSH"
  check_dependency "tmux"  "brew install tmux"
}
```

### `rl status` One-Liner (D-10)

```bash
cmd_status() {
  local vm_name
  vm_name=$(get_saved_vm_name) || die "No airlock for this repo. Run 'rl new' first."

  if ! [ -d "$AQ_STATE_DIR/$vm_name" ]; then
    printf '%s: %snot found%s (VM may have been removed externally)\n' \
      "$vm_name" "$RED" "$RESET"
    return 1
  fi

  local pid_file="$AQ_STATE_DIR/$vm_name/process.pid"
  local port_file="$AQ_STATE_DIR/$vm_name/ssh-port.conf"

  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
    local pid ssh_info=""
    pid=$(cat "$pid_file")
    if [ -f "$port_file" ]; then
      ssh_info=", ssh:$(cat "$port_file")"
    fi
    printf '%s: %srunning%s (pid %s%s)\n' "$vm_name" "$GREEN" "$RESET" "$pid" "$ssh_info"
  else
    printf '%s: %sstopped%s\n' "$vm_name" "$YELLOW" "$RESET"
  fi
}
```

### `rl code` tmux Attach/Create (D-05, D-06, SESS-01)

```bash
cmd_code() {
  local vm_name
  vm_name=$(get_saved_vm_name) || die "No airlock for this repo. Run 'rl new' first."

  local ssh_port
  ssh_port=$(get_ssh_port "$vm_name") || die "VM '$vm_name' is not running. Run 'rl status' to check."

  # Fail immediately on SSH error (D-12)
  ssh -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -p "$ssh_port" \
      root@localhost \
      -t "cd /root/repo 2>/dev/null; tmux new-session -A -s rl" \
    || die "SSH connection failed. Run 'rl status' to check VM state."
}
```

### Guest Provisioning (VM-01)

```bash
provision_guest() {
  local vm_name="$1"

  spinner_start "Installing packages"
  aq exec "$vm_name" <<'SH'
set -e
apk add --no-cache tmux git
mkdir -p /root/repo
echo "PROVISION_COMPLETE"
SH
  spinner_stop "Packages installed"
}
```

## State of the Art

| Old Approach (from prior research) | Actual Approach (from aq source investigation) | Impact |
|-------------------------------------|-----------------------------------------------|--------|
| Generate per-VM SSH keys | Host's `~/.ssh/*.pub` baked into aq base image | No SSH key management needed in `rl` |
| Store SSH port persistently in `.rl/` | SSH port ephemeral per-start, read from aq state | Always read fresh from `~/.local/share/aq/<name>/ssh-port.conf` |
| Use `qemu-system-x86_64` | `qemu-system-aarch64` (Apple Silicon) | Architecture is ARM64, not x86 |
| Alpine 3.21.x | Alpine 3.22.2 | Updated in aq |
| CLI name `lr` | CLI name `rl` | User decision |
| State in `~/.local/state/ailockr/` | State in `.rl/` per repo (D-02) | User decision overrides architecture research |
| Per-VM Caddy proxy | Not in Phase 1 scope | Caddy is Phase 2 |
| Complex port allocation with lockfile | aq handles SSH port allocation internally | No port management needed in Phase 1 |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| aq | VM lifecycle | Yes | 1.6.0 | -- (required) |
| qemu-system-aarch64 | VM engine | Yes | 10.0.3 | -- (required) |
| bash | CLI runtime | Yes | 3.2.57 (system) | Target 3.2 features only |
| git | Version control | Yes | 2.47.1 | -- (required) |
| ssh | Guest access | Yes | 9.9p2 | -- (required) |
| tmux | Session management (host) | Yes | 3.5a | -- (required) |
| shellcheck | Linting | Yes | 0.11.0 | -- (dev only) |
| tput | Color detection | Yes | system | -- |
| tio | aq dependency | Yes | 3.9 | -- (aq required) |
| socat | aq dependency | Yes | 1.8.0.3 | -- (aq required) |
| caddy | API proxy | No | -- | Phase 2 (not needed for Phase 1) |
| shfmt | Code formatting | No | -- | Install later: `brew install shfmt` |
| bats-core | Testing | No | -- | Install later: `brew install bats-core` |
| Homebrew bash | Bash 5.x | No | -- | Use system bash 3.2, avoid 4+ features |

**Missing dependencies with no fallback:**
- None for Phase 1 execution. All required tools are present.

**Missing dependencies with fallback:**
- `shfmt` -- not installed, optional for formatting. Can install later.
- `bats-core` -- not installed, needed only for testing. Can install later.
- `caddy` -- not installed, but NOT needed for Phase 1. Required for Phase 2.

## Open Questions

1. **How does `rl new` provision the repo checkout into `~/repo`?**
   - What we know: `aq scp` can copy files. `aq exec` can run commands. Decision D-05 says working dir is `~/repo`.
   - What's unclear: Should `rl new` push the current repo into the VM immediately, or just create an empty `~/repo` directory? Pushing requires git remote setup which is Phase 4 (CODE-01).
   - Recommendation: Create `~/repo` as empty directory during provisioning. Note in `rl new` output that `rl code` will land there. Git remote setup is Phase 4.

2. **VM name collision across repos**
   - What we know: D-01 uses basename of repo dir. Two repos can have the same basename.
   - What's unclear: How likely this is and whether D-03's error message is sufficient.
   - Recommendation: D-03's error handles the "same repo, second new" case. For cross-repo collision, `aq new` will fail with "directory exists" -- catch this error and provide a helpful message.

3. **`aq start` auto-start on `rl code` for stopped VMs?**
   - What we know: D-12 says fail immediately on SSH errors. A stopped VM has no SSH port.
   - What's unclear: Should `rl code` auto-start a stopped VM, or require the user to run `rl new` again?
   - Recommendation: `rl code` should auto-start the VM if it exists but is stopped (since aq supports `aq start`). Only fail if the VM doesn't exist at all.

## Sources

### Primary (HIGH confidence)
- `/Users/pirj/.bin/aq` -- full source code of aq v1.6.0, all API behaviors verified directly
- `~/.local/share/aq/` -- actual aq state directory structure with existing VMs (o11y, victoria)
- Local tool verification: all versions checked via `--version` on the actual host machine

### Secondary (MEDIUM confidence)
- [Bash Braille Spinner Gist](https://gist.github.com/SamEureka/3e61942d37256550b40d0ffe75bc22c4) -- braille spinner character sequences
- [Braille Pattern CLI Loading Indicator](https://github.com/6/braille-pattern-cli-loading-indicator) -- clockwise/counterclockwise spinner patterns
- [Baeldung: Terminal Color Detection](https://www.baeldung.com/linux/terminal-colors) -- `tput colors` and TTY detection patterns
- [Greg's Wiki BashFAQ/037](https://mywiki.wooledge.org/BashFAQ/037) -- terminal color auto-detection best practices

### Tertiary (LOW confidence)
- None -- all findings verified from primary sources.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all tools verified on actual machine with actual versions
- Architecture: HIGH -- aq source code fully analyzed, API contract documented from source
- Pitfalls: HIGH -- derived from actual aq behavior (port deletion on stop, name collisions) rather than hypothetical concerns

**Research date:** 2026-03-24
**Valid until:** 2026-04-24 (stable -- aq is a local tool, unlikely to change without user action)
