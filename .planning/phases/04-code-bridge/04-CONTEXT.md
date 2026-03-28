# Phase 4: Code Bridge - Context

**Gathered:** 2026-03-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Code moves between host and guest exclusively via git. Host adds guest as a git remote during `rl new`, pushes the current branch, and can fetch agent commits back. No filesystem mounts or shared directories.

</domain>

<decisions>
## Implementation Decisions

### Git Remote Setup
- **D-01:** Remote name is `rl`. Added automatically during `rl new` after provisioning and SSH is ready.
- **D-02:** Remote URL: `ssh://ai@localhost:<ssh_port>/home/ai/repo` — uses the same SSH connection as `rl code`, same forwarded port.
- **D-03:** `rl rm` removes the `rl` git remote from the host repo during cleanup.

### Initial Code Transfer
- **D-04:** `rl new` automatically pushes the current branch to the guest after adding the remote. Only the current branch — not all branches.
- **D-05:** Push uses the same SSH options as other commands (`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`).

### Guest Repo
- **D-06:** Guest repo at `/home/ai/repo` is a regular working tree (not bare). `git init` during provisioning.
- **D-07:** Set `receive.denyCurrentBranch=updateInstead` in the guest repo config so pushes from the host update both the branch and working tree.

### Fetch Workflow
- **D-08:** No custom `rl fetch` command. Users use standard `git fetch rl` to get agent commits from the guest.

### Claude's Discretion
- SSH wrapper for `GIT_SSH_COMMAND` (to pass `-o StrictHostKeyChecking=no` etc.)
- Whether to configure the remote with a refspec or leave default
- Error handling when push fails (e.g. empty repo, no commits yet)
- Whether `rl rm` warns if unfetched commits exist in the guest

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 1 artifacts (SSH, state management)
- `lib/ssh.sh` — SSH connection patterns, `get_ssh_port()`, `wait_for_ssh()`
- `lib/util.sh` — `get_vm_name()`, `save_vm_name()`, `.rl/` state dir

### Phase 3 artifacts (ai user, repo path)
- `lib/vm.sh` — `cmd_new()` provisioning (creates `/home/ai/repo`), `cmd_rm()` cleanup
- `lib/agent.sh` — agent installation runs after provisioning

### Requirements
- `.planning/REQUIREMENTS.md` §Code Bridge — CODE-01

### Stack
- `CLAUDE.md` §SSH/tmux Session Pattern — SSH connection flags, port forwarding
- `CLAUDE.md` §QEMU Networking Pattern — guest IP, host gateway, SSH forwarding

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `get_ssh_port()` — reads SSH port from aq state, used for remote URL
- `cmd_new()` — provisioning flow where git init and remote add hook in
- `cmd_rm()` — cleanup flow where remote remove hooks in
- SSH options pattern — `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` used everywhere

### Established Patterns
- `aq exec "$vm_name" <<'HEREDOC'` — guest command execution for `git init` + config
- `spinner_start`/`spinner_stop` — progress for push operation
- Provisioning runs as root, but git repo belongs to `ai` user (use `su - ai`)

### Integration Points
- `cmd_new()` after provisioning and agent install — add remote, push current branch
- `cmd_rm()` before `.rl/` cleanup — remove git remote
- Guest provisioning heredoc — add `git init` + `receive.denyCurrentBranch` config

</code_context>

<specifics>
## Specific Ideas

No specific requirements — standard git remote over SSH.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 04-code-bridge*
*Context gathered: 2026-03-29*
