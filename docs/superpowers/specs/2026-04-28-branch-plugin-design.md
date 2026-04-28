# Branch Plugin for rlock

**Date:** 2026-04-28
**Status:** Draft

## Problem

Developers regularly check out different git branches in the same repository — feature branches, PR reviews, experiments. With current rlock, one repository directory has one VM. When the user switches git branches, the VM still has the previous branch's code and dependency state. This forces a choice between:

- One messy VM with mixed state from multiple branches
- Manual `rl rm && rl new` per branch (slow — repackages run every time)

The goal: per-branch VM isolation with fast switching, leveraging qcow2 backing chains so a new branch inherits its ancestor's environment without re-running provisioning.

## Solution

A `branch` plugin that maps each git branch to its own VM. VMs are stored as qcow2 chains: a child branch uses its ancestor branch's VM snapshot as backing file. The active VM is resolved dynamically from the current git branch — no `.rl/vm-name` file required.

## Plugin Structure

```
plugins/branch/
  plugin.toml
  plugin.sh           # implements resolve_vm and rm hooks
  commands/
    branch.sh         # rl branch — create VM for current git branch
```

### plugin.toml

```toml
description = "Per-branch VM isolation with qcow2 snapshot inheritance"
deps = ["git"]
host_deps = ["qemu-img", "git"]
triggers = []
commands = ["branch"]
```

- Depends on `git` plugin (need to push code into the VM).
- Host deps: `qemu-img` for snapshot operations, `git` for branch resolution.
- No triggers — explicitly activated.
- One command: `branch`.

## VM Naming

Format: `<sanitized-branch>@<short-sha-base>`

- `branch` — current git branch name
- `sha-base` — short sha (7 chars) of the commit where this branch first diverged from its parent (or HEAD if branch has no diverged commits yet)
- Sanitization: characters not allowed in directory names (`/`, `:`, `\`, etc.) replaced with `_`

Examples:
- `main@abc1234`
- `feature_user-auth@def5678`
- `feat_v2_redesign@abc1234`

The sha part is the **base** sha (divergence point), not the current HEAD. New commits to the branch update the VM's overlay but do not change its name. This means: same branch with new commits → same VM. Branch rebased onto a new base → new VM (because base sha changed).

## qcow2 Snapshot Chains

VMs are organized as a tree of qcow2 files with `backing_file` references:

```
~/.local/share/aq/<vm-name>/storage.qcow2  (overlay)
   └── backing: <ancestor-vm>/snapshot.qcow2
          └── backing: <ancestor-ancestor>/snapshot.qcow2
                 └── (eventually: aq's base Alpine image)
```

Each branch VM has two qcow2 files in its directory:
- `storage.qcow2` — the live, mutable disk (overlay on snapshot)
- `snapshot.qcow2` — the frozen post-provisioning state (used as backing by child branches)

`snapshot.qcow2` is created at the end of `rl branch` provisioning, before the user can make any changes. Child branches' `storage.qcow2` uses this `snapshot.qcow2` as their backing file. This implements the "inheritance" semantics: a child branch sees all packages and configuration from its ancestor, without re-running provisioning.

## Commands

### `rl branch`

Creates a VM for the current git branch.

```
1. Determine current git branch (`git symbolic-ref --short HEAD`)
2. Determine base sha (where this branch diverged from its parent):
   - Try in order: `origin/main`, `origin/master`, `main`, `master`
   - For each candidate that exists: `git merge-base HEAD <candidate>`
   - First successful merge-base wins
   - If branch IS main/master (or none of the above exist): base = current HEAD
3. Compute VM name: <sanitized-branch>@<short-sha>
4. If VM already exists → error: "VM '<name>' already exists"
5. Find ancestor snapshot:
   - Look for any existing VM whose snapshot.qcow2 matches an ancestor commit
     (search in ~/.local/share/aq/* for VMs with names ending @<sha>
     where <sha> is in `git log <branch>..HEAD --format=%h` of base)
   - If found → use its snapshot.qcow2 as backing
   - If not found → create from aq's base Alpine image (vanilla VM)
6. Create VM directory and storage.qcow2 with appropriate backing
7. Boot VM (aq start)
8. Run base provisioning (rlock user, sshd config, etc.) — only if no ancestor
   (otherwise inherited)
9. Run plugin provision/start hooks for activated plugins
10. Stop VM cleanly (so qcow2 is consistent)
11. Create snapshot.qcow2 (qemu-img convert from storage.qcow2)
12. Restart VM for use
13. Save activated plugins to .rl/plugins (for command dispatch)
```

### `rl branch rm`

Destroys the VM for the current git branch and prunes orphaned snapshots.

```
1. Determine current branch and VM name
2. Run plugin rm hooks in reverse order
3. Stop and remove VM (aq rm)
4. Delete VM directory
5. Prune: scan all VMs in ~/.local/share/aq/<repo>/
   For each VM whose snapshot.qcow2 has no children pointing to it:
     - If no live VM uses it as backing → can be considered for removal
     - But only remove if it represents a commit that's no longer
       reachable from any active branch's tracked history
   Pruning uses qemu-img rebase to flatten dependent chains where possible
   (so removing a mid-chain snapshot doesn't break descendants).
```

Pruning is best-effort and can be deferred — `rl branch rm` always succeeds even if pruning fails (logged as warning).

## resolve_vm Hook

A new standard hook for plugins that participate in VM resolution.

**Hook signature:** plugin.sh receives `resolve_vm` as `$1`. Plugin prints the VM name to stdout, or exits with empty output if it cannot determine a VM for this context.

**Base behavior change** (`lib/util.sh::resolve_vm_name`):

```
1. Read .rl/plugins (active plugins)
2. For each plugin in REVERSE dep order (most specific last):
   - Call run_hook plugin resolve_vm
   - If output is non-empty → that's the VM name, return it
3. If no plugin provided a name → fall back to existing behavior
   (read .rl/vm-name, then derive from directory name)
```

**Branch plugin's `resolve_vm` hook:**

```bash
resolve_vm() {
    # Only resolve if we're inside a git repo
    git rev-parse --is-inside-work-tree > /dev/null 2>&1 || return 0

    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return 0

    local base_sha
    base_sha=$(_branch_base_sha "$branch") || return 0

    echo "$(_sanitize "$branch")@${base_sha:0:7}"
}
```

If the branch plugin returns a name but the VM doesn't exist on disk, that's not an error from `resolve_vm` — it's an error from the consuming command (`rl ssh`, etc.) which checks existence and reports "Run `rl branch` first".

## Refactor: Centralize SSH Logic

Currently `bin/rl::cmd_ssh`, `plugins/agent-claude-code/commands/claude.sh`, and `plugins/agent-codex/commands/codex.sh` each implement their own SSH invocation with the same options. Centralize this in `lib/util.sh`:

```bash
# Run a command in the guest VM via SSH.
# Usage: do_ssh vm_name [command...]
# Without command — interactive shell. With command — exec it via -t.
# Auto-starts stopped VM and waits for SSH.
do_ssh() {
    local vm_name="$1"
    shift

    if ! is_vm_running "$vm_name"; then
        info "Starting stopped VM..."
        aq start "$vm_name"
        wait_for_ssh "$vm_name" 60 || die "SSH connection timed out"
    fi

    local port
    port=$(get_ssh_port "$vm_name")

    if [[ $# -eq 0 ]]; then
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p "$port" rlock@localhost
    else
        ssh -t -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p "$port" rlock@localhost "$@"
    fi
}
```

Update `cmd_ssh`, `claude.sh`, `codex.sh` to use `do_ssh`. This reduces duplication and means any improvement to SSH handling propagates everywhere.

## VM-Not-Found Behavior

When a command (`rl ssh`/`rl claude`/`rl codex`) calls `resolve_vm_name` and gets back a name, but the VM doesn't actually exist on disk:

```
Error: VM '<name>' not found.
Hint: Run 'rl branch' to create a VM for the current git branch.
```

This is checked in `do_ssh` (after `resolve_vm_name` returns). Branch plugin doesn't auto-create — explicit creation only.

## Push State Tracking

`rl status` is enhanced to show whether the VM is up to date with the local branch:

```
Airlock: feature_x@abc1234
VM:      running (PID 12345, SSH port 2222)
Plugins: auth-proxy, git, agent-claude-code, branch
Code:    behind by 3 commits (push: git push rl)
```

Implementation: `git ls-remote rl HEAD 2>/dev/null` returns the sha at the guest. Compare with local `git rev-parse HEAD`. If different — count commits, show hint.

If `rl` remote doesn't exist or VM not running — skip the line silently.

## Guest Hostname

The branch plugin sets the guest hostname to the (sanitized) branch name during its provision hook. This makes the shell prompt useful: `feature_x:~$` instead of inheriting from the directory name.

```bash
provision() {
    local vm="$1"
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return 0
    local hostname
    hostname=$(_sanitize "$branch")
    aq exec "$vm" sh -c "hostname '$hostname'; echo '$hostname' > /etc/hostname"
}
```

## Activated Plugins Persistence

When a child branch's VM is created with backing from an ancestor, it inherits the ancestor's installed packages — but `.rl/plugins` (the activated plugin list) is per-airlock, not per-branch. New approach:

- The branch plugin saves activated plugins inside the VM's directory: `~/.local/share/aq/<vm-name>/.rlock-plugins`
- Child VMs initialize their `.rlock-plugins` from the ancestor's
- `get_active_plugins` (in lib/util.sh) checks the VM-local file first, falls back to `.rl/plugins`

This way: if you activate `docker` on the main branch's VM, child branches inherit that activation.

## Error Handling

- **Not in a git repo** when running `rl branch` → error: "rl branch requires a git repository"
- **Detached HEAD** → error: "rl branch requires a named branch (currently in detached HEAD)"
- **VM already exists** → error: "VM '<name>' already exists"
- **No qemu-img on host** → caught by host_deps check at activation time
- **Backing snapshot missing** (e.g., user manually deleted) → fall back to creating from base, warn
- **Pruning fails** → log warning, continue (rm still succeeds)

## Known Limitations

Written to `KNOWN-LIMITATIONS.md` in the project root during implementation:

- **No automatic VM creation on branch switch** — switching git branches doesn't create a VM. Must run `rl branch` explicitly.
- **No git hooks** — branch plugin doesn't install post-checkout or post-merge hooks. Could be added later.
- **Manual changes lost in child branches** — child branches inherit the post-provisioning snapshot, not the live VM state. Manual experiments in a parent branch's VM don't propagate.
- **Pruning is conservative** — orphan snapshots may accumulate. `qemu-img rebase` flattening only happens for clearly safe cases.
- **Detached HEAD not supported** — checkout a sha → no branch → no VM.
- **Worktrees** — each git worktree has its own current branch, so `rl branch` works correctly per worktree. Worktrees that share commits will resolve to the same VM (by design).
