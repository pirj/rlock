# Phase 1: CLI Skeleton and VM Lifecycle - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-24
**Phase:** 01-cli-skeleton-and-vm-lifecycle
**Areas discussed:** VM naming, Session experience, Output style, Error behavior

---

## VM Naming

| Option | Description | Selected |
|--------|-------------|----------|
| Auto from repo dir | VM named after current directory — simplest, one VM per repo | ✓ |
| Custom name required | `rl new myname` — allows multiple VMs per repo | |
| Auto + optional override | `rl new` uses repo dir name, `rl new myname` overrides | |

**User's choice:** Auto from repo dir
**Notes:** Simplest approach for v1. Multi-VM per repo deferred.

### VM State Location

| Option | Description | Selected |
|--------|-------------|----------|
| ~/.local/state/ailockr/ | XDG-compliant, standard for state data | |
| .rl/ in repo dir | Colocated with the repo — visible, easy to inspect | ✓ |
| You decide | Claude picks | |

**User's choice:** .rl/ in repo dir
**Notes:** User prefers colocation with repo for visibility.

### VM Collision

| Option | Description | Selected |
|--------|-------------|----------|
| Error + hint | "VM already exists. Use `rl code` to connect or `rl rm` to destroy." | ✓ |
| Auto-connect | Silently connect to existing VM | |
| Ask to replace | "VM exists. Replace it? (y/n)" | |

**User's choice:** Error + hint
**Notes:** Explicit errors preferred over silent behavior.

---

## Session Experience

### Shell

| Option | Description | Selected |
|--------|-------------|----------|
| ash (Alpine default) | Already installed, lightweight, BusyBox-based | ✓ |
| bash | More familiar, needs apk add | |
| zsh | Richest experience, needs apk add | |

**User's choice:** ash (Alpine default)
**Notes:** No extra packages.

### Working Directory

| Option | Description | Selected |
|--------|-------------|----------|
| ~/repo (clone dir) | Land directly in the repo checkout | ✓ |
| Home (~) | Standard home directory | |
| You decide | Claude picks | |

**User's choice:** ~/repo
**Notes:** None.

### tmux Structure

| Option | Description | Selected |
|--------|-------------|----------|
| Single window | One session, one window — simple | ✓ |
| Two windows | Agent session + shell for manual work | |
| You decide | Claude picks | |

**User's choice:** Single window
**Notes:** User creates additional windows as needed.

---

## Output Style

### Verbosity

| Option | Description | Selected |
|--------|-------------|----------|
| Quiet + progress | Minimal output, progress during slow ops | ✓ |
| Verbose by default | Show each step | |
| Silent + exit codes | No output on success | |

**User's choice:** Quiet + progress
**Notes:** None.

### Color

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, with auto-detect | Colors when terminal, plain when piped | ✓ |
| No colors | Plain text only | |
| You decide | Claude picks | |

**User's choice:** Yes, with auto-detect
**Notes:** None.

### Progress Indicator

| Option | Description | Selected |
|--------|-------------|----------|
| Step labels | One line per step | |
| Spinner | Animated spinner with step name | |
| Dots | Simple dots/ellipsis | |
| Custom (Other) | Braille spinner + step label, overwriting | ✓ |

**User's choice:** Braille code spinner (two chars wide, clockwise) on the left, step label on the right. Each step overwrites the previous line via carriage return.
**Notes:** Very specific UX requirement — braille rotation must be clockwise, two chars wide.

### Status Format

| Option | Description | Selected |
|--------|-------------|----------|
| Compact one-liner | "ailockr: running (pid 1234, ssh:2222)" | ✓ |
| Multi-line summary | Name, state, ports, uptime, disk usage | |
| You decide | Claude picks | |

**User's choice:** Compact one-liner
**Notes:** Fits in a prompt, grep-friendly.

---

## Error Behavior

### Missing Dependencies

| Option | Description | Selected |
|--------|-------------|----------|
| Error + install hint | "aq not found. Install: brew install pirj/tap/aq" | ✓ |
| Auto-install | Attempt automatic install | |
| Just error | Let user figure it out | |

**User's choice:** Error + install hint
**Notes:** Clear guidance without being presumptuous.

### SSH Failure

| Option | Description | Selected |
|--------|-------------|----------|
| Retry with timeout | Retry for 30s, then fail | |
| Fail immediately | Show error, suggest rl status | ✓ |
| You decide | Claude picks | |

**User's choice:** Fail immediately
**Notes:** No auto-retry. User checks status and retries manually.

---

## Claude's Discretion

- Exact braille spinner character sequence
- CLI help text formatting
- Internal lib/ module boundaries
- SSH key generation approach
- aq invocation strategy

## Deferred Ideas

None — discussion stayed within phase scope.
