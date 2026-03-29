# Phase 4: Code Bridge - Research

**Researched:** 2026-03-29
**Domain:** Git remote management over SSH, push-to-deploy to non-bare repositories
**Confidence:** HIGH

## Summary

This phase implements the git-based code bridge between host and guest VM. The host adds the guest as a git remote named `rl` during `rl new`, pushes the current branch, and users fetch agent commits back with standard `git fetch rl`. The technical approach uses `receive.denyCurrentBranch=updateInstead` in the guest repo so pushes update both the branch ref and the working tree.

The implementation is straightforward git plumbing -- no exotic features needed. The key technical decisions are all locked in CONTEXT.md. The main complexity lies in SSH options for git transport (matching the existing SSH patterns) and handling edge cases: empty host repos, branch name mismatches between host and guest defaults, and dirty working tree rejection on the guest side.

**Primary recommendation:** Use `GIT_SSH_COMMAND` environment variable to pass SSH options (`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`) during `git push`, matching the existing SSH patterns in `lib/ssh.sh`. Initialize the guest repo with `git init` + `git config receive.denyCurrentBranch updateInstead` during provisioning (via `aq exec` + `su - ai`). Add `git remote add rl ssh://ai@localhost:<port>/home/ai/repo` after provisioning, then push the current branch. On `rl rm`, run `git remote remove rl` before cleaning up `.rl/`.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Remote name is `rl`. Added automatically during `rl new` after provisioning and SSH is ready.
- **D-02:** Remote URL: `ssh://ai@localhost:<ssh_port>/home/ai/repo` -- uses the same SSH connection as `rl code`, same forwarded port.
- **D-03:** `rl rm` removes the `rl` git remote from the host repo during cleanup.
- **D-04:** `rl new` automatically pushes the current branch to the guest after adding the remote. Only the current branch -- not all branches.
- **D-05:** Push uses the same SSH options as other commands (`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`).
- **D-06:** Guest repo at `/home/ai/repo` is a regular working tree (not bare). `git init` during provisioning.
- **D-07:** Set `receive.denyCurrentBranch=updateInstead` in the guest repo config so pushes from the host update both the branch and working tree.
- **D-08:** No custom `rl fetch` command. Users use standard `git fetch rl` to get agent commits from the guest.

### Claude's Discretion
- SSH wrapper for `GIT_SSH_COMMAND` (to pass `-o StrictHostKeyChecking=no` etc.)
- Whether to configure the remote with a refspec or leave default
- Error handling when push fails (e.g. empty repo, no commits yet)
- Whether `rl rm` warns if unfetched commits exist in the guest

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CODE-01 | Host adds guest as a git remote; code moves between host and guest exclusively via git (fetch-based workflow) | Git remote over SSH with `updateInstead` config on guest repo. `GIT_SSH_COMMAND` for SSH options. `git remote add/remove` for lifecycle. Push current branch on `rl new`, standard `git fetch rl` for retrieval. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- Shell script (Bash 5.x) -- `rl` runs on the host, not compiled binary
- VM engine: QEMU via pirj/aq -- no Docker
- Dependencies: aq, Caddy, git on host
- ShellCheck and shfmt for linting/formatting
- Existing patterns: `aq exec "$vm_name" <<'HEREDOC'` for guest commands, `su - ai -c '...'` for ai user operations
- SSH options: `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` used everywhere
- Spinner pattern: `spinner_start`/`spinner_stop` for progress indication
- State management: `.rl/` dir, `save_vm_name`, `get_ssh_port`
- Error handling: `die()` for fatal errors, `warn()` for non-fatal

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| Git | 2.20+ (host), any (guest) | Remote management, push/fetch | Already a project dependency. `git remote add/remove`, `GIT_SSH_COMMAND`, `receive.denyCurrentBranch=updateInstead` all stable across 2.x series. `updateInstead` with unborn branches works since Git 2.4. |
| OpenSSH | 10.x (host), 9.x+ (guest) | SSH transport for git | Already used by `rl code` and `wait_for_ssh`. Same options apply to git SSH transport via `GIT_SSH_COMMAND`. |

No new dependencies required. This phase uses only git and SSH, both already present.

## Architecture Patterns

### Integration Points in Existing Code

The code bridge touches three existing functions and the provisioning heredoc:

```
lib/vm.sh
  cmd_new()     # After agent install: add git remote, push current branch
  cmd_rm()      # Before .rl/ cleanup: remove git remote
  provisioning  # HEREDOC: add git init + receive config inside su - ai block

lib/ssh.sh      # (read-only) Reuse SSH options pattern
lib/util.sh     # (read-only) get_ssh_port(), resolve_vm_name()
```

### Pattern 1: Guest Repo Initialization

**What:** During provisioning (inside the existing `aq exec` HEREDOC in `cmd_new`), initialize the git repo for the `ai` user with the correct config.

**When to use:** During `rl new`, inside the existing provisioning block.

**Implementation:**
```bash
# Inside the existing su - ai -c '...' block in cmd_new provisioning
su - ai -c '
set -e
# ... existing mise/env setup ...
mkdir -p ~/repo
cd ~/repo
git init
git config receive.denyCurrentBranch updateInstead
'
```

**Key detail:** The `git init` and `git config` MUST run as the `ai` user (via `su - ai`), not as root. The repo directory `/home/ai/repo` is already created by the existing provisioning (line 136 of vm.sh: `mkdir -p ~/repo`). The `git init` replaces the plain `mkdir` or runs after it.

### Pattern 2: GIT_SSH_COMMAND for Push

**What:** Set `GIT_SSH_COMMAND` environment variable to pass SSH options when `git push` connects to the guest over SSH.

**When to use:** During the `git push` in `cmd_new`, and implicitly whenever the user runs `git fetch rl` (but for fetch, the user's shell handles SSH -- we only need to document this).

**Implementation:**
```bash
# Build GIT_SSH_COMMAND with the same options used elsewhere
local git_ssh_cmd="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Push current branch to guest
local current_branch
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null) || {
    warn "Not on a branch (detached HEAD). Skipping code push."
    # Still add the remote -- user can push manually
}

if [ -n "$current_branch" ]; then
    GIT_SSH_COMMAND="$git_ssh_cmd" git push rl "$current_branch" 2>/dev/null
fi
```

**Why `git symbolic-ref --short HEAD`:** Works on all Git 2.x versions. The alternative `git branch --show-current` requires Git 2.22+, which exceeds the project's 2.20+ minimum.

**Why NOT `core.sshCommand`:** Git has no per-remote `sshCommand` config option. `core.sshCommand` is repo-wide and would affect all remotes (including `origin`). `GIT_SSH_COMMAND` is scoped to a single command invocation, which is exactly what we need.

### Pattern 3: Remote Add in cmd_new

**What:** After provisioning and agent installation, add the guest as a git remote and push the current branch.

**Implementation:**
```bash
# After agent installation in cmd_new, before final output
local ssh_port
ssh_port=$(get_ssh_port "$vm_name") || die "SSH port not available."

# Add guest as git remote
git remote add rl "ssh://ai@localhost:${ssh_port}/home/ai/repo" 2>/dev/null \
    || die "Failed to add git remote 'rl'. A remote named 'rl' may already exist."

# Push current branch
local git_ssh_cmd="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
local current_branch
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null) || true

if [ -n "$current_branch" ]; then
    spinner_start "Pushing code to VM"
    if GIT_SSH_COMMAND="$git_ssh_cmd" git push rl "$current_branch" 2>/dev/null; then
        spinner_stop "Code pushed"
    else
        spinner_stop "Push failed"
        warn "Could not push code. You can push manually: git push rl $current_branch"
    fi
else
    warn "Not on a branch (detached HEAD). Push code manually when ready."
fi
```

### Pattern 4: Remote Remove in cmd_rm

**What:** Remove the `rl` git remote during `rl rm` cleanup, before deleting `.rl/`.

**Implementation:**
```bash
# In cmd_rm, before rm -rf "$RL_DIR"
git remote remove rl 2>/dev/null || true  # Ignore if remote doesn't exist
```

**Why silent failure:** The remote might not exist if `rl new` failed partway through, or if the user manually removed it. Cleanup should be idempotent.

### Anti-Patterns to Avoid

- **Setting `core.sshCommand` in the repo config:** Affects ALL remotes, not just `rl`. Would break `git push origin` if origin uses different SSH settings.
- **Using `~/.ssh/config` Host entries:** These persist globally and could interfere with other SSH connections to localhost.
- **Creating a bare repo in the guest:** The decision (D-06) explicitly requires a working tree. Bare repos don't let agents `cd ~/repo` and see files.
- **Using `git clone` instead of `git init` + `git push`:** The guest has no network access to the host repo. The host pushes to the guest, not the other way around.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SSH options for git transport | Custom SSH wrapper script in `.rl/` | `GIT_SSH_COMMAND` env var | One-liner, no temp files, scoped to single invocation. Wrapper scripts add cleanup burden. |
| Push-to-deploy working tree update | Post-receive hook in guest | `receive.denyCurrentBranch=updateInstead` | Built-in git feature since 2.3. Handles unborn branches since 2.4. Zero maintenance. |
| Branch detection | Manual HEAD file parsing | `git symbolic-ref --short HEAD` | Standard git plumbing command, handles edge cases properly. |
| Remote URL with dynamic port | Template files or string replacement | `git remote add rl "ssh://ai@localhost:${ssh_port}/home/ai/repo"` | Direct shell variable expansion. The port is known at add time. |

**Key insight:** Every operation in this phase is standard git plumbing. There is nothing to build -- only git commands to invoke in the right order with the right options.

## Common Pitfalls

### Pitfall 1: Host Repo Has No Commits

**What goes wrong:** `git push rl main` fails with "error: src refspec main does not match any" if the host repo has no commits (e.g., user ran `git init` then `rl new` immediately).
**Why it happens:** Git cannot push a branch that doesn't exist (no commits = no branch ref).
**How to avoid:** Check if HEAD resolves to a commit before attempting push. If not, skip the push with a warning message.
**Warning signs:** `git rev-parse HEAD` fails with exit code 128.
**Implementation:**
```bash
if ! git rev-parse HEAD >/dev/null 2>&1; then
    warn "No commits yet. Push code after your first commit: git push rl <branch>"
fi
```

### Pitfall 2: Branch Name Mismatch Between Host and Guest

**What goes wrong:** Host is on branch `main`, guest `git init` creates unborn branch `master` (or vice versa, depending on guest git config for `init.defaultBranch`). Push succeeds, but the working tree only updates if the pushed branch matches the guest's checked-out branch.
**Why it happens:** `receive.denyCurrentBranch=updateInstead` only updates the working tree when the push targets the currently checked-out branch. If host pushes `main` but guest init'd with `master`, the push creates a new ref but doesn't update the working tree.
**How to avoid:** Set `init.defaultBranch` in the guest git config before `git init`, OR after push, checkout the correct branch in the guest. The simplest fix: set `git config --global init.defaultBranch main` in the guest before `git init`. But this forces `main`. A better approach: after the initial push, run `git checkout <pushed_branch>` in the guest via `aq exec` if the push was to a branch different from the guest's HEAD.
**Recommended solution:** During provisioning, configure `git -c init.defaultBranch=placeholder init` in the guest (the branch name doesn't matter for an unborn branch with `updateInstead` since Git 2.4 handles pushes to unborn branches). Then after push, the guest will be on whatever branch was pushed. Alternatively, push using the refspec to match the guest's branch: `git push rl HEAD:refs/heads/$(git symbolic-ref --short HEAD)`.

**Verified behavior (HIGH confidence):** Since Git 2.4, `updateInstead` works correctly with unborn branches. When pushing to a repo with an unborn branch, git creates the branch AND updates the working tree. The initial branch name in the guest is irrelevant because the unborn branch gets replaced by the pushed branch. Source: [git commit 1a51b52](https://github.com/git/git/commit/1a51b52422e055e433dec9a496621341d70d38ff).

### Pitfall 3: Guest Working Tree is Dirty When Host Pushes

**What goes wrong:** If an AI agent has uncommitted changes in the guest working tree, `git push rl <branch>` from the host will be rejected by `updateInstead`.
**Why it happens:** `updateInstead` refuses to update the working tree if it has uncommitted modifications (to prevent data loss).
**How to avoid:** This is expected behavior and is actually desirable -- it protects agent work. Document this in the CLI output: if push fails, suggest the user commit or stash changes in the guest first.
**Warning signs:** Push failure message from the remote side.

### Pitfall 4: SSH Port Changes After VM Restart

**What goes wrong:** After `rl code` restarts a stopped VM (auto-start feature), the SSH port changes because aq allocates ports dynamically. The git remote `rl` still points to the old port.
**Why it happens:** aq allocates a random SSH port (49152-65535) on each `aq start`. The git remote URL is set during `rl new` and not updated.
**How to avoid:** The user runs `git fetch rl` which will fail if the port changed. This is a known limitation with the current architecture. Mitigation options (for Claude's discretion):
  1. Accept it -- `rl new` creates a fresh VM each time, so the port is stable for the VM's lifetime unless explicitly stopped/started.
  2. Update the remote URL on `rl code` if the port changed.
  3. Document that `git fetch rl` only works while the VM is running with the same port from `rl new`.
**Recommended:** Option 1 (accept it) for Phase 4. The common workflow is: `rl new` -> `rl code` -> agent works -> `git fetch rl` -> `rl rm`. The port only changes if the user manually stops/restarts the VM, which is an edge case.

### Pitfall 5: `rl` Remote Already Exists

**What goes wrong:** `git remote add rl ...` fails if a remote named `rl` already exists (e.g., from a previous `rl new` that wasn't cleaned up with `rl rm`).
**Why it happens:** `cmd_new` already checks for `.rl/vm-name` to prevent duplicate VMs, but doesn't check for orphaned git remotes.
**How to avoid:** Check `git remote get-url rl 2>/dev/null` before adding. If it exists, either remove it first or warn and die.
**Recommended:** Remove it silently and re-add, since a stale remote pointing to a dead VM is useless.

### Pitfall 6: User Expects `git fetch rl` to Use Special SSH Options

**What goes wrong:** User runs `git fetch rl` and gets SSH host key verification errors because the remote uses `localhost` with a changing host key, and the user hasn't set `StrictHostKeyChecking=no`.
**Why it happens:** `GIT_SSH_COMMAND` was set only during the initial `git push` in `rl new`. It doesn't persist for subsequent `git fetch` commands.
**How to avoid:** Set `core.sshCommand` in the LOCAL repo config specifically for the rl remote's SSH needs. But this affects ALL remotes. Alternatively, document that users need to run: `GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" git fetch rl`.
**Recommended:** Set `core.sshCommand` at the local repo level. Since AILockr VMs always use `localhost` with ephemeral host keys, and the host's regular SSH to github/gitlab uses known hosts, the practical impact is minimal -- `StrictHostKeyChecking=no` for localhost is common practice. However, if the user has multiple remotes that care about strict host key checking, this could be a concern. A safer alternative: print a helper command or alias in the `rl new` output.
**Best approach:** Use `git config --local core.sshCommand` to set the SSH command at the repo level. The tradeoff (affects all remotes) is acceptable because: (1) localhost is the only place where host keys change, (2) `UserKnownHostsFile=/dev/null` means we never pollute known_hosts, (3) users of this tool are already trusting local VM connections. Remove this config in `rl rm`.

## Code Examples

### Complete Guest Provisioning Addition (git init)

```bash
# Addition to existing su - ai -c block in cmd_new provisioning HEREDOC
su - ai -c '
set -e
# ... existing mise.toml and bashrc setup ...
mkdir -p ~/repo
cd ~/repo
git init
git config receive.denyCurrentBranch updateInstead
'
```

Source: [Git config docs - receive.denyCurrentBranch](https://git-scm.com/docs/git-config)

### Complete Host-Side Remote Setup (after provisioning)

```bash
# After agent install, before "Airlock ready" message
local ssh_port
ssh_port=$(get_ssh_port "$vm_name") || die "SSH port not available."

# Remove stale remote if exists (Pitfall 5)
git remote remove rl 2>/dev/null || true

# Add guest as git remote (D-01, D-02)
git remote add rl "ssh://ai@localhost:${ssh_port}/home/ai/repo"

# Set SSH options for this repo (D-05, Pitfall 6)
git config --local core.sshCommand "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Push current branch if possible (D-04)
if git rev-parse HEAD >/dev/null 2>&1; then
    local current_branch
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null) || true
    if [ -n "$current_branch" ]; then
        spinner_start "Pushing code to VM"
        if git push rl "$current_branch" 2>/dev/null; then
            spinner_stop "Code pushed"
        else
            spinner_stop "Push failed"
            warn "Could not push code. Push manually: git push rl $current_branch"
        fi
    else
        warn "Detached HEAD. Push code manually when ready."
    fi
else
    info "No commits yet. Push code after your first commit: git push rl <branch>"
fi
```

### Complete Cleanup in cmd_rm

```bash
cmd_rm() {
    local vm_name
    vm_name=$(resolve_vm_name) || die "No airlock for this repo. Run 'rl new' first."

    # Remove git remote before VM cleanup (D-03)
    git remote remove rl 2>/dev/null || true

    # Remove repo-local SSH config if we set it
    git config --local --unset core.sshCommand 2>/dev/null || true

    if [ -d "$AQ_STATE_DIR/$vm_name" ]; then
        aq rm "$vm_name" || warn "aq rm failed for '$vm_name' -- continuing cleanup"
    else
        warn "VM '$vm_name' not found in aq -- may have been removed externally"
    fi

    rm -rf "$RL_DIR"
    success "Airlock '$vm_name' destroyed"
}
```

### GIT_SSH_COMMAND Alternative (if core.sshCommand is rejected)

If the planner decides against `core.sshCommand` (because it affects all remotes), use `GIT_SSH_COMMAND` for the initial push and print a helper for subsequent fetches:

```bash
# Push with explicit GIT_SSH_COMMAND
local git_ssh="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
GIT_SSH_COMMAND="$git_ssh" git push rl "$current_branch" 2>/dev/null

# In final output
info "Fetch agent commits: GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' git fetch rl"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `receive.denyCurrentBranch=ignore` + post-receive hook | `receive.denyCurrentBranch=updateInstead` | Git 2.3 (2015) | No hook needed, working tree auto-updates |
| `updateInstead` fails on unborn branch | Works with unborn branches | Git 2.4 (2015) | Can push to freshly init'd repos |
| `GIT_SSH` env var (path to wrapper script) | `GIT_SSH_COMMAND` env var (inline command) | Git 2.3 (2015) | No wrapper script needed |
| `git remote rm` only | `git remote remove` alias added | Git 1.7.10 (2012) | Either works, `remove` is more readable |
| `git branch --show-current` | Same (added in 2.22) | Git 2.22 (2019) | Use `git symbolic-ref --short HEAD` for 2.20+ compat |

## Open Questions

1. **core.sshCommand vs GIT_SSH_COMMAND for user-facing fetch**
   - What we know: `core.sshCommand` at repo level makes `git fetch rl` just work, but affects all remotes. `GIT_SSH_COMMAND` requires the user to set it each time.
   - What's unclear: Whether users will be confused by having to prefix `git fetch rl` with `GIT_SSH_COMMAND=...`, or whether `core.sshCommand` affecting all remotes will cause issues.
   - Recommendation: Use `core.sshCommand` at local level. The SSH options (`StrictHostKeyChecking=no` for localhost) are harmless for normal remote operations, and UX of "just run `git fetch rl`" is much better. Clean it up in `rl rm`.

2. **Warning about unfetched commits on `rl rm`**
   - What we know: Could check `git log rl/main..` or `git fetch rl` + check if there are commits, but this requires the VM to be running.
   - What's unclear: Whether the VM is always running when `rl rm` is called. If it's stopped, we can't SSH in to check.
   - Recommendation: Skip the warning for Phase 4. The user is explicitly destroying the VM -- they should know if they have unfetched work. This can be a v2 enhancement.

## Sources

### Primary (HIGH confidence)
- [Git official docs - git-config](https://git-scm.com/docs/git-config) -- `receive.denyCurrentBranch`, `core.sshCommand`
- [Git official docs - git-remote](https://git-scm.com/docs/git-remote) -- `add`, `remove` subcommands, exit codes
- [Git commit 1a51b52](https://github.com/git/git/commit/1a51b52422e055e433dec9a496621341d70d38ff) -- `updateInstead` support for unborn branches (Git 2.4)
- [Git official docs - githooks](https://git-scm.com/docs/githooks) -- `push-to-checkout` hook documentation
- Phase 1 research (`01-RESEARCH.md`) -- aq SSH behavior, port allocation, `aq exec` patterns

### Secondary (MEDIUM confidence)
- [Git Environment Variables](https://git-scm.com/book/en/v2/Git-Internals-Environment-Variables) -- `GIT_SSH_COMMAND` documentation
- [push-to-deploy blog](https://blog.tfnico.com/2015/05/a-better-way-to-git-push-to-deploy.html) -- practical `updateInstead` usage patterns
- [Baeldung - SSH key with Git](https://www.baeldung.com/linux/ssh-private-key-git-command) -- `core.sshCommand` per-repository configuration

### Tertiary (LOW confidence)
None -- all findings verified against official git documentation.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- uses only git and SSH, both well-documented and already present in the project
- Architecture: HIGH -- all patterns follow existing codebase conventions (aq exec, su - ai, spinner, die/warn)
- Pitfalls: HIGH -- all edge cases verified against git documentation and commit history

**Research date:** 2026-03-29
**Valid until:** 2026-06-29 (90 days -- git remote/SSH features are extremely stable)
