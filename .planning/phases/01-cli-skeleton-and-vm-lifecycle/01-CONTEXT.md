# Phase 1: CLI Skeleton and VM Lifecycle - Context

**Gathered:** 2026-03-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Create the `rl` CLI tool with subcommands for VM lifecycle: `rl new` (create per-repo VM with SSH, tmux, git), `rl code` (connect to VM tmux session), `rl status` (check if airlock exists), `rl rm` (destroy VM). The CLI dispatches subcommands via a modular lib/ structure. Caddy proxy, agent installation, and git remote setup are separate phases.

</domain>

<decisions>
## Implementation Decisions

### VM Naming
- **D-01:** VMs are auto-named from the current repo directory name (e.g. `ailockr`). No custom naming support in v1.
- **D-02:** Per-VM state (ports, PIDs, configs) lives in `.rl/` inside the repo directory. Add `.rl/` to `.gitignore`.
- **D-03:** If `rl new` is run when a VM already exists, error with hint: "VM already exists. Use `rl code` to connect or `rl rm` to destroy."

### Session Experience
- **D-04:** User lands in `ash` (Alpine default shell) — no extra packages needed.
- **D-05:** Working directory on connect is `~/repo` — the repo checkout inside the VM.
- **D-06:** Single tmux window per session. User splits/creates windows as needed.

### Output Style
- **D-07:** Quiet by default with progress during slow operations (VM boot, package install).
- **D-08:** Progress indicator: braille code spinner (two chars wide, clockwise rotation) on the left, step label on the right. Each step overwrites the previous line (carriage return, no newline until done).
- **D-09:** Colored output with auto-detection — colors when terminal supports it, plain when piped.
- **D-10:** `rl status` outputs a compact one-liner: e.g. "ailockr: running (pid 1234, ssh:2222)"

### Error Behavior
- **D-11:** Missing dependencies (aq, Caddy) produce a clear error with install hint: "aq not found. Install: brew install pirj/tap/aq"
- **D-12:** SSH failure on `rl code` fails immediately with error and suggests `rl status` to check VM state. No auto-retry.

### Claude's Discretion
- Exact braille spinner character sequence (as long as it's 2-char wide and clockwise)
- CLI help text formatting
- Internal lib/ module boundaries and sourcing strategy
- SSH key generation approach for host-to-guest access
- How aq is invoked (direct CLI calls vs wrapper functions)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

No external specs — requirements fully captured in decisions above. The `pirj/aq` tool is referenced but not documented in this repo.

### Research
- `.planning/research/STACK.md` — Recommended stack, Bash 5.x choice, ShellCheck enforcement
- `.planning/research/ARCHITECTURE.md` — CLI dispatch pattern, lib/ module structure, per-VM state dirs
- `.planning/research/PITFALLS.md` — Shell portability issues, orphaned QEMU processes, SSH key management

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- None — greenfield project, no existing code.

### Established Patterns
- None — this phase establishes the patterns (CLI dispatch, lib/ structure, output formatting).

### Integration Points
- `aq` CLI — external dependency for VM creation, start, stop, SSH. Must be installed on host.
- `.rl/` directory — new state directory created per repo, will be used by later phases (Caddy config in Phase 2, git remote info in Phase 4).

</code_context>

<specifics>
## Specific Ideas

- The braille spinner should feel smooth and professional — two characters wide, rotating clockwise, similar to ora/cli-spinners style but in pure shell
- Status one-liner should be grep-friendly for scripting: "name: state (details)"

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-cli-skeleton-and-vm-lifecycle*
*Context gathered: 2026-03-24*
