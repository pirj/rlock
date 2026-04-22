# Plugin Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor rlock from a monolithic CLI into a base + plugin architecture where users activate only the plugins they need and third parties can add their own.

**Architecture:** Thin base (aq wrapper + SSH + plugin framework) dispatches to convention-based plugins. Each plugin is a directory with a `plugin.toml` manifest and `plugin.sh` hooks. Plugins are discovered from `$PROJECT_DIR/plugins/` (core) and `~/.config/rl/plugins/` (third-party). Dependencies are resolved via topological sort. Hooks run as subprocesses.

**Tech Stack:** Bash 5.x, BATS (testing), ShellCheck (linting), aq (QEMU wrapper)

**Spec:** `docs/superpowers/specs/2026-04-22-plugin-architecture-design.md`

---

## File Structure

**Kept (modified):**
- `bin/rl` — rewritten as base dispatcher
- `lib/ui.sh` — unchanged
- `lib/util.sh` — slimmed down, add plugin state functions, absorb `wait_for_ssh` and `is_vm_running`

**New:**
- `lib/toml.sh` — flat TOML parser (2 functions)
- `lib/plugin.sh` — plugin framework (discovery, deps, activation, hooks, commands)
- `plugins/git/plugin.toml` + `plugin.sh`
- `plugins/auth-proxy/plugin.toml` + `plugin.sh` + `commands/auth.sh`
- `plugins/agent-claude-code/plugin.toml` + `plugin.sh` + `commands/claude.sh`
- `plugins/agent-codex/plugin.toml` + `plugin.sh` + `commands/codex.sh`
- `test/test_helper/common.bash` — shared BATS helpers
- `test/toml.bats` — TOML parser tests
- `test/plugin_discovery.bats` — plugin discovery tests
- `test/dependency_resolution.bats` — dependency resolution tests
- `test/activation.bats` — trigger detection and host dep tests
- `test/dispatch.bats` — hook and command dispatch tests
- `KNOWN-LIMITATIONS.md`

**Deleted after migration:**
- `lib/vm.sh` — split between base and plugins
- `lib/ssh.sh` — `wait_for_ssh` absorbed into `util.sh`, `cmd_code` moved to agent plugins
- `lib/proxy.sh` — moved to auth-proxy plugin
- `lib/creds.sh` — moved to auth-proxy plugin
- `lib/agent.sh` — moved to agent plugins

---

### Task 1: Test Infrastructure + TOML Parser

**Files:**
- Create: `test/test_helper/common.bash`
- Create: `test/toml.bats`
- Create: `lib/toml.sh`

- [ ] **Step 1: Install BATS test helpers**

```bash
mkdir -p test/test_helper
git submodule add https://github.com/bats-core/bats-support test/test_helper/bats-support
git submodule add https://github.com/bats-core/bats-assert test/test_helper/bats-assert
```

- [ ] **Step 2: Create shared test helper**

Create `test/test_helper/common.bash`:

```bash
#!/usr/bin/env bash

_common_setup() {
    load 'bats-support/load'
    load 'bats-assert/load'

    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LIB_DIR="$PROJECT_ROOT/lib"
}
```

- [ ] **Step 3: Write failing tests for TOML parser**

Create `test/toml.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    source "$LIB_DIR/toml.sh"

    TEST_TOML="$BATS_TEST_TMPDIR/test.toml"
}

@test "toml_get reads string value" {
    cat > "$TEST_TOML" <<'EOF'
description = "Git gateway"
EOF
    run toml_get "$TEST_TOML" "description"
    assert_success
    assert_output "Git gateway"
}

@test "toml_get returns empty for missing key" {
    cat > "$TEST_TOML" <<'EOF'
description = "Git gateway"
EOF
    run toml_get "$TEST_TOML" "nonexistent"
    assert_success
    assert_output ""
}

@test "toml_get_array reads array values" {
    cat > "$TEST_TOML" <<'EOF'
deps = ["auth-proxy", "git"]
EOF
    run toml_get_array "$TEST_TOML" "deps"
    assert_success
    assert_line --index 0 "auth-proxy"
    assert_line --index 1 "git"
}

@test "toml_get_array returns empty for empty array" {
    cat > "$TEST_TOML" <<'EOF'
deps = []
EOF
    run toml_get_array "$TEST_TOML" "deps"
    assert_success
    assert_output ""
}

@test "toml_get_array returns empty for missing key" {
    cat > "$TEST_TOML" <<'EOF'
description = "something"
EOF
    run toml_get_array "$TEST_TOML" "deps"
    assert_success
    assert_output ""
}

@test "toml_get_array reads single-element array" {
    cat > "$TEST_TOML" <<'EOF'
triggers = [".git"]
EOF
    run toml_get_array "$TEST_TOML" "triggers"
    assert_success
    assert_output ".git"
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `bats test/toml.bats`
Expected: FAIL — `lib/toml.sh` does not exist yet.

- [ ] **Step 5: Implement TOML parser**

Create `lib/toml.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Parse a string value from a flat TOML file.
# Usage: toml_get file key
# Prints the value (unquoted) or empty string if key not found.
toml_get() {
    local file="$1" key="$2"
    sed -n "s/^${key} *= *\"\(.*\)\"/\1/p" "$file"
}

# Parse an array value from a flat TOML file.
# Usage: toml_get_array file key
# Prints one element per line. Empty output if key missing or array empty.
toml_get_array() {
    local file="$1" key="$2"
    local line
    line=$(grep "^${key} *= *\[" "$file" 2>/dev/null) || return 0
    echo "$line" | sed 's/^[^[]*\[//; s/\].*//' | tr ',' '\n' | sed -n 's/.*"\([^"]*\)".*/\1/p'
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bats test/toml.bats`
Expected: All 6 tests PASS.

- [ ] **Step 7: Run ShellCheck**

Run: `shellcheck lib/toml.sh`
Expected: No warnings.

- [ ] **Step 8: Commit**

```bash
git add test/ lib/toml.sh .gitmodules
git commit -m "feat: add BATS test infrastructure and TOML parser"
```

---

### Task 2: Plugin Discovery

**Files:**
- Create: `lib/plugin.sh`
- Create: `test/plugin_discovery.bats`

- [ ] **Step 1: Write failing tests for plugin discovery**

Create `test/plugin_discovery.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    source "$LIB_DIR/toml.sh"

    # Override plugin dirs to use temp directories
    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    source "$LIB_DIR/plugin.sh"
}

@test "discover_plugins finds core plugins" {
    mkdir -p "$PLUGIN_CORE_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git gateway"
EOF
    run discover_plugins
    assert_success
    assert_output "git"
}

@test "discover_plugins finds user plugins" {
    mkdir -p "$PLUGIN_USER_DIR/custom"
    cat > "$PLUGIN_USER_DIR/custom/plugin.toml" <<'EOF'
description = "Custom plugin"
EOF
    run discover_plugins
    assert_success
    assert_output "custom"
}

@test "discover_plugins merges core and user, sorted unique" {
    mkdir -p "$PLUGIN_CORE_DIR/git" "$PLUGIN_CORE_DIR/auth-proxy"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    cat > "$PLUGIN_CORE_DIR/auth-proxy/plugin.toml" <<'EOF'
description = "Auth proxy"
EOF
    mkdir -p "$PLUGIN_USER_DIR/custom"
    cat > "$PLUGIN_USER_DIR/custom/plugin.toml" <<'EOF'
description = "Custom"
EOF
    run discover_plugins
    assert_success
    assert_line --index 0 "auth-proxy"
    assert_line --index 1 "custom"
    assert_line --index 2 "git"
}

@test "discover_plugins skips directories without plugin.toml" {
    mkdir -p "$PLUGIN_CORE_DIR/broken"
    # No plugin.toml
    run discover_plugins
    assert_success
    assert_output ""
}

@test "plugin_dir returns core plugin path" {
    mkdir -p "$PLUGIN_CORE_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    run plugin_dir "git"
    assert_success
    assert_output "$PLUGIN_CORE_DIR/git"
}

@test "plugin_dir prefers user plugin over core" {
    mkdir -p "$PLUGIN_CORE_DIR/git" "$PLUGIN_USER_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Core git"
EOF
    cat > "$PLUGIN_USER_DIR/git/plugin.toml" <<'EOF'
description = "User git"
EOF
    run plugin_dir "git"
    assert_success
    assert_output "$PLUGIN_USER_DIR/git"
}

@test "plugin_dir fails for unknown plugin" {
    run plugin_dir "nonexistent"
    assert_failure
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/plugin_discovery.bats`
Expected: FAIL — `lib/plugin.sh` does not exist yet.

- [ ] **Step 3: Implement plugin discovery**

Create `lib/plugin.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Plugin directory paths — overridable for testing
PLUGIN_CORE_DIR="${PLUGIN_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins" && pwd)}"
PLUGIN_USER_DIR="${PLUGIN_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/rl/plugins}"

# Discover all available plugins.
# Prints plugin names (one per line), sorted alphabetically.
discover_plugins() {
    local dir plugin_dir_path
    for dir in "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"; do
        [[ -d "$dir" ]] || continue
        for plugin_dir_path in "$dir"/*/; do
            [[ -f "${plugin_dir_path}plugin.toml" ]] || continue
            basename "$plugin_dir_path"
        done
    done | sort -u
}

# Get the directory path for a named plugin.
# User plugins take precedence over core plugins.
# Returns 1 if plugin not found.
plugin_dir() {
    local name="$1"
    if [[ -f "$PLUGIN_USER_DIR/$name/plugin.toml" ]]; then
        echo "$PLUGIN_USER_DIR/$name"
    elif [[ -f "$PLUGIN_CORE_DIR/$name/plugin.toml" ]]; then
        echo "$PLUGIN_CORE_DIR/$name"
    else
        return 1
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/plugin_discovery.bats`
Expected: All 7 tests PASS.

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck lib/plugin.sh`
Expected: No warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/plugin.sh test/plugin_discovery.bats
git commit -m "feat: add plugin discovery"
```

---

### Task 3: Dependency Resolution

**Files:**
- Modify: `lib/plugin.sh`
- Create: `test/dependency_resolution.bats`

- [ ] **Step 1: Write failing tests for dependency resolution**

Create `test/dependency_resolution.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/plugin.sh"
}

_make_plugin() {
    local name="$1" deps="${2:-}"
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
description = "$name plugin"
deps = [$deps]
EOF
}

@test "resolve_deps returns single plugin with no deps" {
    _make_plugin "git"
    run resolve_deps "git"
    assert_success
    assert_output "git"
}

@test "resolve_deps includes dependency before dependent" {
    _make_plugin "auth-proxy"
    _make_plugin "agent-claude-code" '"auth-proxy"'
    run resolve_deps "agent-claude-code"
    assert_success
    assert_line --index 0 "auth-proxy"
    assert_line --index 1 "agent-claude-code"
}

@test "resolve_deps handles transitive dependencies" {
    _make_plugin "base-tools"
    _make_plugin "auth-proxy" '"base-tools"'
    _make_plugin "agent-claude-code" '"auth-proxy"'
    run resolve_deps "agent-claude-code"
    assert_success
    assert_line --index 0 "base-tools"
    assert_line --index 1 "auth-proxy"
    assert_line --index 2 "agent-claude-code"
}

@test "resolve_deps deduplicates shared dependencies" {
    _make_plugin "auth-proxy"
    _make_plugin "agent-claude-code" '"auth-proxy"'
    _make_plugin "agent-codex" '"auth-proxy"'
    run resolve_deps "agent-claude-code" "agent-codex"
    assert_success
    # auth-proxy should appear exactly once
    local count
    count=$(echo "$output" | grep -c "^auth-proxy$")
    [[ "$count" -eq 1 ]]
}

@test "resolve_deps prints auto-inclusion notice to stderr" {
    _make_plugin "auth-proxy"
    _make_plugin "agent-claude-code" '"auth-proxy"'
    run --separate-stderr resolve_deps "agent-claude-code"
    assert_success
    # stderr should contain the notice
    [[ "$stderr" == *"Including auth-proxy (required by agent-claude-code)"* ]]
}

@test "resolve_deps detects circular dependency" {
    _make_plugin "a" '"b"'
    _make_plugin "b" '"a"'
    run resolve_deps "a"
    assert_failure
    assert_output --partial "Circular dependency"
}

@test "resolve_deps errors on missing dependency" {
    _make_plugin "agent-claude-code" '"nonexistent"'
    run resolve_deps "agent-claude-code"
    assert_failure
    assert_output --partial "requires 'nonexistent'"
    assert_output --partial "not installed"
}

@test "resolve_deps preserves order of independent plugins" {
    _make_plugin "git"
    _make_plugin "auth-proxy"
    run resolve_deps "git" "auth-proxy"
    assert_success
    assert_line --index 0 "git"
    assert_line --index 1 "auth-proxy"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/dependency_resolution.bats`
Expected: FAIL — `resolve_deps` not defined.

- [ ] **Step 3: Implement dependency resolution**

Append to `lib/plugin.sh`:

```bash
# Resolve plugin dependencies via depth-first topological sort.
# Usage: resolve_deps plugin1 plugin2 ...
# Prints resolved list (deps first) one per line to stdout.
# Prints auto-inclusion notices to stderr.
# Exits non-zero on circular or missing dependencies.
resolve_deps() {
    local -a input=("$@")
    local -a resolved=()
    local -A visited=()
    local -A in_stack=()

    _visit() {
        local plugin="$1"
        local parent="${2:-}"

        if [[ -n "${in_stack[$plugin]:-}" ]]; then
            echo "Circular dependency detected involving '$plugin'" >&2
            return 1
        fi
        [[ -z "${visited[$plugin]:-}" ]] || return 0

        local pdir
        if ! pdir=$(plugin_dir "$plugin"); then
            if [[ -n "$parent" ]]; then
                echo "Plugin '$parent' requires '$plugin', but '$plugin' is not installed" >&2
            else
                echo "Plugin '$plugin' is not installed" >&2
            fi
            return 1
        fi

        in_stack[$plugin]=1

        local dep
        while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            if [[ -z "${visited[$dep]:-}" ]]; then
                # Check if this dep was explicitly requested
                local explicit=0
                local i
                for i in "${input[@]}"; do
                    [[ "$i" == "$dep" ]] && explicit=1 && break
                done
                if [[ $explicit -eq 0 ]]; then
                    echo "Including $dep (required by $plugin)" >&2
                fi
            fi
            _visit "$dep" "$plugin"
        done < <(toml_get_array "$pdir/plugin.toml" "deps")

        unset "in_stack[$plugin]"
        visited[$plugin]=1
        resolved+=("$plugin")
    }

    local plugin
    for plugin in "${input[@]}"; do
        _visit "$plugin" ""
    done

    printf '%s\n' "${resolved[@]}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/dependency_resolution.bats`
Expected: All 8 tests PASS.

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck lib/plugin.sh`
Expected: No warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/plugin.sh test/dependency_resolution.bats
git commit -m "feat: add plugin dependency resolution"
```

---

### Task 4: Trigger Detection + Host Dep + Command Conflict Checks

**Files:**
- Modify: `lib/plugin.sh`
- Create: `test/activation.bats`

- [ ] **Step 1: Write failing tests**

Create `test/activation.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/plugin.sh"

    # Create a fake project directory for trigger detection
    PROJECT="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT"
}

_make_plugin() {
    local name="$1"
    shift
    mkdir -p "$PLUGIN_CORE_DIR/$name"
    cat > "$PLUGIN_CORE_DIR/$name/plugin.toml" <<EOF
$@
EOF
}

# --- Trigger detection ---

@test "detect_triggers finds plugins with matching triggers" {
    _make_plugin "git" 'description = "Git"
triggers = [".git"]'
    mkdir -p "$PROJECT/.git"
    run detect_triggers "$PROJECT" "git"
    assert_success
    assert_output "git"
}

@test "detect_triggers skips plugins without matching triggers" {
    _make_plugin "git" 'description = "Git"
triggers = [".git"]'
    # No .git in PROJECT
    run detect_triggers "$PROJECT" "git"
    assert_success
    assert_output ""
}

@test "detect_triggers skips already-activated plugins" {
    _make_plugin "git" 'description = "Git"
triggers = [".git"]'
    mkdir -p "$PROJECT/.git"
    run detect_triggers "$PROJECT" "git" "git"
    assert_success
    assert_output ""
}

@test "detect_triggers skips plugins with no triggers field" {
    _make_plugin "auth-proxy" 'description = "Auth proxy"'
    run detect_triggers "$PROJECT" "auth-proxy"
    assert_success
    assert_output ""
}

# --- Host dependency checking ---

@test "check_host_deps passes when all deps available" {
    _make_plugin "git" 'description = "Git"
host_deps = ["bash", "cat"]'
    run check_host_deps "git"
    assert_success
}

@test "check_host_deps fails on missing binary" {
    _make_plugin "git" 'description = "Git"
host_deps = ["nonexistent_binary_xyz"]'
    run check_host_deps "git"
    assert_failure
    assert_output --partial "requires 'nonexistent_binary_xyz'"
}

# --- Command conflict detection ---

@test "check_command_conflicts passes with no conflicts" {
    _make_plugin "agent-claude-code" 'description = "Claude"
commands = ["claude"]'
    _make_plugin "git" 'description = "Git"
commands = []'
    run check_command_conflicts "agent-claude-code" "git"
    assert_success
}

@test "check_command_conflicts detects duplicate commands" {
    _make_plugin "plugin-a" 'description = "A"
commands = ["code"]'
    _make_plugin "plugin-b" 'description = "B"
commands = ["code"]'
    run check_command_conflicts "plugin-a" "plugin-b"
    assert_failure
    assert_output --partial "Command 'code' claimed by both"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/activation.bats`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement activation functions**

Append to `lib/plugin.sh`:

```bash
# Detect plugins whose triggers match files in the project directory.
# Usage: detect_triggers project_dir available_plugin1 [already_activated1 ...]
# First arg is project dir. Remaining args: all available plugin names.
# Set ACTIVATED_PLUGINS env var (space-separated) to skip those.
# Prints matched plugin names (one per line).
detect_triggers() {
    local project_dir="$1"
    shift
    local -a available=()
    local -a already_activated=()
    local parsing_activated=0

    # Split args: available plugins come first, then after a sentinel we get activated ones
    # Actually, let's use a simpler interface: pass available as args, set env var for activated
    for arg in "$@"; do
        available+=("$arg")
    done

    local plugin
    for plugin in "${available[@]}"; do
        # Skip if already activated
        local skip=0
        local activated
        for activated in ${ACTIVATED_PLUGINS:-}; do
            [[ "$activated" == "$plugin" ]] && skip=1 && break
        done
        [[ $skip -eq 1 ]] && continue

        local pdir
        pdir=$(plugin_dir "$plugin") || continue
        local trigger
        while IFS= read -r trigger; do
            [[ -n "$trigger" ]] || continue
            if [[ -e "$project_dir/$trigger" ]]; then
                echo "$plugin"
                break
            fi
        done < <(toml_get_array "$pdir/plugin.toml" "triggers")
    done
}

# Check that all host dependencies for given plugins are available.
# Usage: check_host_deps plugin1 plugin2 ...
# Exits non-zero with message if any binary is missing.
check_host_deps() {
    local plugin
    for plugin in "$@"; do
        local pdir
        pdir=$(plugin_dir "$plugin") || continue
        local dep
        while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            if ! command -v "$dep" > /dev/null 2>&1; then
                echo "Plugin '$plugin' requires '$dep' on the host" >&2
                return 1
            fi
        done < <(toml_get_array "$pdir/plugin.toml" "host_deps")
    done
}

# Check that no two activated plugins claim the same command.
# Usage: check_command_conflicts plugin1 plugin2 ...
# Exits non-zero with message if a conflict is found.
check_command_conflicts() {
    local -A seen_commands=()
    local plugin
    for plugin in "$@"; do
        local pdir
        pdir=$(plugin_dir "$plugin") || continue
        local cmd
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] || continue
            if [[ -n "${seen_commands[$cmd]:-}" ]]; then
                echo "Command '$cmd' claimed by both ${seen_commands[$cmd]} and $plugin" >&2
                return 1
            fi
            seen_commands[$cmd]="$plugin"
        done < <(toml_get_array "$pdir/plugin.toml" "commands")
    done
}
```

- [ ] **Step 4: Fix detect_triggers tests to use ACTIVATED_PLUGINS env var**

Update the "skips already-activated plugins" test in `test/activation.bats`:

```bash
@test "detect_triggers skips already-activated plugins" {
    _make_plugin "git" 'description = "Git"
triggers = [".git"]'
    mkdir -p "$PROJECT/.git"
    ACTIVATED_PLUGINS="git" run detect_triggers "$PROJECT" "git"
    assert_success
    assert_output ""
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/activation.bats`
Expected: All 7 tests PASS.

- [ ] **Step 6: Run ShellCheck**

Run: `shellcheck lib/plugin.sh`
Expected: No warnings.

- [ ] **Step 7: Commit**

```bash
git add lib/plugin.sh test/activation.bats
git commit -m "feat: add trigger detection, host dep and command conflict checks"
```

---

### Task 5: Hook Dispatch + Command Dispatch

**Files:**
- Modify: `lib/plugin.sh`
- Create: `test/dispatch.bats`

- [ ] **Step 1: Write failing tests**

Create `test/dispatch.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_CORE_DIR="$BATS_TEST_TMPDIR/core_plugins"
    PLUGIN_USER_DIR="$BATS_TEST_TMPDIR/user_plugins"
    mkdir -p "$PLUGIN_CORE_DIR" "$PLUGIN_USER_DIR"

    # Provide RL_LIB_DIR for plugins that source shared libs
    export RL_LIB_DIR="$LIB_DIR"

    source "$LIB_DIR/toml.sh"
    source "$LIB_DIR/plugin.sh"
}

@test "run_hook calls provision hook" {
    mkdir -p "$PLUGIN_CORE_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    cat > "$PLUGIN_CORE_DIR/git/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
set -euo pipefail
provision() { echo "provisioned:$1"; }
if declare -f "$1" > /dev/null 2>&1; then "$1" "${@:2}"; fi
PLUGIN
    chmod +x "$PLUGIN_CORE_DIR/git/plugin.sh"

    run run_hook "git" "provision" "test-vm"
    assert_success
    assert_output "provisioned:test-vm"
}

@test "run_hook silently skips undefined hooks" {
    mkdir -p "$PLUGIN_CORE_DIR/git"
    cat > "$PLUGIN_CORE_DIR/git/plugin.toml" <<'EOF'
description = "Git"
EOF
    cat > "$PLUGIN_CORE_DIR/git/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
set -euo pipefail
provision() { echo "provisioned"; }
if declare -f "$1" > /dev/null 2>&1; then "$1" "${@:2}"; fi
PLUGIN
    chmod +x "$PLUGIN_CORE_DIR/git/plugin.sh"

    run run_hook "git" "start" "test-vm"
    assert_success
    assert_output ""
}

@test "run_hook returns failure on hook error" {
    mkdir -p "$PLUGIN_CORE_DIR/broken"
    cat > "$PLUGIN_CORE_DIR/broken/plugin.toml" <<'EOF'
description = "Broken"
EOF
    cat > "$PLUGIN_CORE_DIR/broken/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
set -euo pipefail
provision() { echo "failing" >&2; exit 1; }
if declare -f "$1" > /dev/null 2>&1; then "$1" "${@:2}"; fi
PLUGIN
    chmod +x "$PLUGIN_CORE_DIR/broken/plugin.sh"

    run run_hook "broken" "provision" "test-vm"
    assert_failure
}

@test "run_hook skips plugin with no plugin.sh" {
    mkdir -p "$PLUGIN_CORE_DIR/minimal"
    cat > "$PLUGIN_CORE_DIR/minimal/plugin.toml" <<'EOF'
description = "Minimal"
EOF
    # No plugin.sh
    run run_hook "minimal" "provision" "test-vm"
    assert_success
    assert_output ""
}

@test "dispatch_command finds and runs command script" {
    mkdir -p "$PLUGIN_CORE_DIR/agent-claude-code/commands"
    cat > "$PLUGIN_CORE_DIR/agent-claude-code/plugin.toml" <<'EOF'
description = "Claude Code"
commands = ["claude"]
EOF
    cat > "$PLUGIN_CORE_DIR/agent-claude-code/commands/claude.sh" <<'CMD'
#!/usr/bin/env bash
echo "claude:$*"
CMD
    chmod +x "$PLUGIN_CORE_DIR/agent-claude-code/commands/claude.sh"

    # Simulate active plugins
    ACTIVE_PLUGINS="agent-claude-code"
    run dispatch_command "claude" "arg1" "arg2"
    assert_success
    assert_output "claude:arg1 arg2"
}

@test "dispatch_command fails for unknown command" {
    ACTIVE_PLUGINS=""
    run dispatch_command "nonexistent"
    assert_failure
    assert_output --partial "Unknown command"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/dispatch.bats`
Expected: FAIL — `run_hook` and `dispatch_command` not defined.

- [ ] **Step 3: Implement hook and command dispatch**

Append to `lib/plugin.sh`:

```bash
# Run a hook on a plugin.
# Usage: run_hook plugin_name hook_name [args...]
# Runs plugin.sh as a subprocess with the hook name as first arg.
# Returns 0 if plugin has no plugin.sh or hook is not defined.
# Returns the hook's exit code otherwise.
run_hook() {
    local plugin="$1" hook="$2"
    shift 2
    local pdir
    pdir=$(plugin_dir "$plugin") || return 0
    local plugin_sh="$pdir/plugin.sh"
    [[ -f "$plugin_sh" ]] || return 0
    RL_LIB_DIR="${RL_LIB_DIR:-$LIB_DIR}" bash "$plugin_sh" "$hook" "$@"
}

# Dispatch a plugin command.
# Usage: dispatch_command command_name [args...]
# Reads ACTIVE_PLUGINS (space-separated) to know which plugins to search.
# Finds the plugin that declares this command and runs its command script.
dispatch_command() {
    local cmd_name="$1"
    shift

    local plugin
    for plugin in ${ACTIVE_PLUGINS:-}; do
        local pdir
        pdir=$(plugin_dir "$plugin") || continue
        local cmd
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] || continue
            if [[ "$cmd" == "$cmd_name" ]]; then
                local cmd_script="$pdir/commands/${cmd_name}.sh"
                if [[ -f "$cmd_script" ]]; then
                    RL_LIB_DIR="${RL_LIB_DIR:-$LIB_DIR}" bash "$cmd_script" "$@"
                    return $?
                fi
            fi
        done < <(toml_get_array "$pdir/plugin.toml" "commands")
    done

    echo "Unknown command: $cmd_name" >&2
    return 1
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/dispatch.bats`
Expected: All 6 tests PASS.

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck lib/plugin.sh`
Expected: No warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/plugin.sh test/dispatch.bats
git commit -m "feat: add hook dispatch and command dispatch"
```

---

### Task 6: Update lib/util.sh + Rewrite bin/rl

**Files:**
- Modify: `lib/util.sh`
- Modify: `bin/rl`

- [ ] **Step 1: Read current lib/util.sh and lib/ssh.sh**

Read `lib/util.sh` and `lib/ssh.sh` to understand the functions being kept, moved, or removed.

- [ ] **Step 2: Update lib/util.sh**

Keep: `die`, `check_dependency`, `get_vm_name`, `get_saved_vm_name`, `resolve_vm_name`, `save_vm_name`, `ensure_rl_dir`, `get_ssh_port`.

Remove: `check_all_deps` (replaced by per-plugin `host_deps`).

Move in from `lib/ssh.sh`: `wait_for_ssh`.

Move in from `lib/vm.sh`: `is_vm_running`.

Add new: `save_active_plugins`, `get_active_plugins`.

Add `wait_for_ssh` (from `lib/ssh.sh` — copy the function as-is):

```bash
# Wait for SSH connectivity to a VM.
# Usage: wait_for_ssh vm_name timeout_seconds
# Returns 0 on success, 1 on timeout.
wait_for_ssh() {
    local vm_name="$1"
    local timeout="${2:-60}"
    local deadline=$((SECONDS + timeout))

    # Phase 1: wait for ssh-port.conf
    while [[ $SECONDS -lt $deadline ]]; do
        [[ -f "$AQ_STATE_DIR/$vm_name/ssh-port.conf" ]] && break
        sleep 1
    done
    [[ $SECONDS -lt $deadline ]] || return 1

    local port
    port=$(get_ssh_port "$vm_name")

    # Phase 2: wait for SSH to accept connections
    while [[ $SECONDS -lt $deadline ]]; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p "$port" root@localhost true 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}
```

Add `is_vm_running` (from `lib/vm.sh`):

```bash
# Check if a VM is currently running.
# Usage: is_vm_running vm_name
is_vm_running() {
    local vm_name="$1"
    local pid_file="$AQ_STATE_DIR/$vm_name/process.pid"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(<"$pid_file")
    kill -0 "$pid" 2>/dev/null
}
```

Add plugin state functions:

```bash
# Save the list of activated plugins.
# Usage: save_active_plugins plugin1 plugin2 ...
save_active_plugins() {
    ensure_rl_dir
    printf '%s\n' "$@" > "$RL_DIR/plugins"
}

# Read the list of activated plugins.
# Prints plugin names one per line. Empty if no plugins file.
get_active_plugins() {
    local plugins_file="$RL_DIR/plugins"
    [[ -f "$plugins_file" ]] || return 0
    cat "$plugins_file"
}
```

- [ ] **Step 3: Rewrite bin/rl**

Read current `bin/rl`, then rewrite as the base dispatcher:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
export RL_LIB_DIR="$LIB_DIR"

source "$LIB_DIR/ui.sh"
source "$LIB_DIR/util.sh"
source "$LIB_DIR/toml.sh"
source "$LIB_DIR/plugin.sh"

cmd_help() {
    cat <<'USAGE'
Usage: rl <command> [args...]

Commands:
  new [plugins...]   Create a new airlock VM
  rm                 Destroy the airlock VM
  status             Show airlock status
  ssh                SSH into the VM
  help               Show this help

Plugins are activated during 'rl new'. Additional commands
are provided by activated plugins.
USAGE
}

cmd_new() {
    local -a requested=("$@")

    # Check base host deps
    check_dependency "aq" "Install from https://github.com/pirj/aq"
    check_dependency "ssh" "Install OpenSSH"

    # Discover available plugins
    local -a available
    mapfile -t available < <(discover_plugins)

    # If no plugins requested, detect triggers and prompt
    if [[ ${#requested[@]} -eq 0 ]]; then
        local -a triggered
        mapfile -t triggered < <(detect_triggers "$(pwd)" "${available[@]}")
        for plugin in "${triggered[@]}"; do
            [[ -n "$plugin" ]] || continue
            local desc
            desc=$(toml_get "$(plugin_dir "$plugin")/plugin.toml" "description")
            local answer
            read -rp "Include ${desc:-$plugin}? (Y/n) " answer
            if [[ "${answer:-Y}" =~ ^[Yy]$ ]]; then
                requested+=("$plugin")
            fi
        done
    fi

    # Resolve dependencies
    local -a resolved
    if [[ ${#requested[@]} -gt 0 ]]; then
        mapfile -t resolved < <(resolve_deps "${requested[@]}")
    fi

    # Check for triggered plugins not yet in the resolved list
    if [[ ${#resolved[@]} -gt 0 ]]; then
        local -a extra_triggered
        ACTIVATED_PLUGINS="${resolved[*]}" mapfile -t extra_triggered < <(detect_triggers "$(pwd)" "${available[@]}")
        for plugin in "${extra_triggered[@]}"; do
            [[ -n "$plugin" ]] || continue
            local desc
            desc=$(toml_get "$(plugin_dir "$plugin")/plugin.toml" "description")
            local answer
            read -rp "Include ${desc:-$plugin}? (Y/n) " answer
            if [[ "${answer:-Y}" =~ ^[Yy]$ ]]; then
                # Re-resolve with the new plugin
                mapfile -t resolved < <(resolve_deps "${resolved[@]}" "$plugin")
            fi
        done
    fi

    # Check host deps and command conflicts
    if [[ ${#resolved[@]} -gt 0 ]]; then
        check_host_deps "${resolved[@]}"
        check_command_conflicts "${resolved[@]}"
    fi

    # Create VM
    local vm_name
    vm_name=$(get_vm_name)

    if [[ -d "$AQ_STATE_DIR/$vm_name" ]]; then
        die "Airlock '$vm_name' already exists. Run 'rl rm' first."
    fi

    spinner_start "Creating VM"
    aq new "$vm_name"
    aq start "$vm_name"
    spinner_stop "VM created"

    save_vm_name "$vm_name"

    spinner_start "Waiting for SSH"
    if ! wait_for_ssh "$vm_name" 60; then
        die "SSH connection timed out"
    fi
    spinner_stop "SSH ready"

    # Base provisioning: create ai user, install essentials
    spinner_start "Provisioning base environment"
    aq exec "$vm_name" sh <<'BASE_PROVISION'
set -eu
sed -i 's/^#\(.*community\)/\1/' /etc/apk/repositories
apk update
apk add bash curl sudo
adduser -D ai
echo "ai ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ai
mkdir -p /home/ai/.ssh
cp /root/.ssh/authorized_keys /home/ai/.ssh/
chown -R ai:ai /home/ai/.ssh
chmod 700 /home/ai/.ssh
chmod 600 /home/ai/.ssh/authorized_keys
BASE_PROVISION
    spinner_stop "Base environment ready"

    # Run plugin provision hooks
    local plugin
    for plugin in "${resolved[@]}"; do
        spinner_start "Provisioning: $plugin"
        if ! run_hook "$plugin" "provision" "$vm_name"; then
            spinner_stop "FAILED: $plugin"
            die "Plugin '$plugin' provisioning failed. VM left for debugging (rl ssh to inspect, rl rm to clean up)."
        fi
        spinner_stop "Provisioned: $plugin"
    done

    # Run plugin start hooks
    for plugin in "${resolved[@]}"; do
        run_hook "$plugin" "start" "$vm_name" || true
    done

    # Save activated plugins
    if [[ ${#resolved[@]} -gt 0 ]]; then
        save_active_plugins "${resolved[@]}"
    fi

    success "Airlock ready"
    if [[ ${#resolved[@]} -gt 0 ]]; then
        info "Active plugins: ${resolved[*]}"
    fi
}

cmd_rm() {
    local vm_name
    vm_name=$(resolve_vm_name) || die "No airlock found in this directory"

    # Run rm hooks in reverse order
    local -a plugins
    mapfile -t plugins < <(get_active_plugins)
    local i
    for ((i=${#plugins[@]}-1; i>=0; i--)); do
        local plugin="${plugins[$i]}"
        [[ -n "$plugin" ]] || continue
        run_hook "$plugin" "rm" "$vm_name" || warn "Plugin '$plugin' cleanup failed"
    done

    # Destroy VM
    spinner_start "Destroying VM"
    aq rm "$vm_name" || warn "aq rm failed for '$vm_name'"
    spinner_stop "VM destroyed"

    rm -rf "$RL_DIR"
    success "Airlock removed"
}

cmd_status() {
    local vm_name
    vm_name=$(resolve_vm_name) || die "No airlock found in this directory"

    local state
    if is_vm_running "$vm_name"; then
        local pid port
        pid=$(<"$AQ_STATE_DIR/$vm_name/process.pid")
        port=$(get_ssh_port "$vm_name")
        state="${GREEN}running${RESET} (PID $pid, SSH port $port)"
    else
        state="${YELLOW}stopped${RESET}"
    fi

    echo "Airlock: $vm_name"
    echo "VM:      $state"

    local -a plugins
    mapfile -t plugins < <(get_active_plugins)
    if [[ ${#plugins[@]} -gt 0 ]]; then
        echo "Plugins: ${plugins[*]}"
    fi
}

cmd_ssh() {
    local vm_name
    vm_name=$(resolve_vm_name) || die "No airlock found in this directory"

    if ! is_vm_running "$vm_name"; then
        info "Starting stopped VM..."
        aq start "$vm_name"
        if ! wait_for_ssh "$vm_name" 60; then
            die "SSH connection timed out"
        fi
    fi

    local port
    port=$(get_ssh_port "$vm_name")
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p "$port" ai@localhost
}

# Main dispatch
case "${1:-help}" in
    new)    shift; cmd_new "$@" ;;
    rm)     cmd_rm ;;
    status) cmd_status ;;
    ssh)    cmd_ssh ;;
    help)   cmd_help ;;
    *)
        # Try plugin command dispatch
        _plugins=()
        mapfile -t _plugins < <(get_active_plugins)
        if [[ ${#_plugins[@]} -gt 0 ]]; then
            ACTIVE_PLUGINS="${_plugins[*]}" dispatch_command "$@"
        else
            die "Unknown command: $1. Run 'rl help' for usage."
        fi
        ;;
esac
```

- [ ] **Step 4: Run ShellCheck on both files**

Run: `shellcheck lib/util.sh bin/rl`
Expected: No warnings. Fix any issues found.

- [ ] **Step 5: Commit**

```bash
git add bin/rl lib/util.sh
git commit -m "feat: rewrite base dispatcher with plugin framework"
```

---

### Task 7: git Plugin

**Files:**
- Create: `plugins/git/plugin.toml`
- Create: `plugins/git/plugin.sh`

- [ ] **Step 1: Read current git-related code in lib/vm.sh**

Read `lib/vm.sh` to extract the git remote setup, push, and cleanup logic.

- [ ] **Step 2: Create plugin.toml**

Create `plugins/git/plugin.toml`:

```toml
description = "Git gateway between host and guest"
deps = []
host_deps = ["git"]
triggers = [".git"]
commands = []
```

- [ ] **Step 3: Create plugin.sh**

Create `plugins/git/plugin.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

provision() {
    local vm="$1"
    aq exec "$vm" sh <<'PROVISION'
set -eu
apk add git
su -l ai -c '
    mkdir -p ~/repo
    cd ~/repo
    git init
    git config receive.denyCurrentBranch updateInstead
'
PROVISION
}

start() {
    local vm="$1"
    local port
    port=$(get_ssh_port "$vm")
    local remote_url="ssh://ai@localhost:$port/home/ai/repo"
    local ssh_cmd="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $port"

    echo ""
    info "Git remote command:"
    echo "  git remote add rl $remote_url"
    echo "  git config core.sshCommand \"$ssh_cmd\""
    echo ""

    local answer
    read -rp "Add git remote now? (Y/n) " answer
    if [[ "${answer:-Y}" =~ ^[Yy]$ ]]; then
        git remote add rl "$remote_url" 2>/dev/null || warn "Remote 'rl' already exists"
        git config core.sshCommand "$ssh_cmd"

        # Push current branch if on one
        local branch
        branch=$(git symbolic-ref --short HEAD 2>/dev/null) || true
        if [[ -n "$branch" ]]; then
            spinner_start "Pushing $branch to guest"
            git push rl "$branch" 2>/dev/null
            spinner_stop "Code pushed"
        else
            warn "Detached HEAD — skipping push. Push manually with: git push rl HEAD:main"
        fi
    fi
}

rm() {
    local vm="$1"
    git remote remove rl 2>/dev/null || true
    git config --unset core.sshCommand 2>/dev/null || true
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

- [ ] **Step 4: Run ShellCheck**

Run: `shellcheck plugins/git/plugin.sh`
Expected: No warnings.

- [ ] **Step 5: Commit**

```bash
git add plugins/git/
git commit -m "feat: extract git plugin"
```

---

### Task 8: auth-proxy Plugin

**Files:**
- Create: `plugins/auth-proxy/plugin.toml`
- Create: `plugins/auth-proxy/plugin.sh`
- Create: `plugins/auth-proxy/commands/auth.sh`

- [ ] **Step 1: Read current lib/proxy.sh and lib/creds.sh**

Read both files to understand the full credential store, OAuth import, Caddy lifecycle, and auth command logic.

- [ ] **Step 2: Create plugin.toml**

Create `plugins/auth-proxy/plugin.toml`:

```toml
description = "API key proxy (Caddy reverse proxy for credential injection)"
deps = []
host_deps = ["caddy"]
triggers = []
commands = ["auth"]
```

- [ ] **Step 3: Create plugin.sh**

Create `plugins/auth-proxy/plugin.sh` by combining the logic from `lib/proxy.sh` and `lib/creds.sh`. This is the largest plugin — it contains:
- Credential store functions (`creds_get`, `creds_set`, `creds_resolve`)
- OAuth import from macOS Keychain (`import_claude_oauth`, `refresh_oauth_token`, `refresh_if_needed`)
- Caddyfile generation (`generate_caddyfile`)
- Caddy lifecycle (`is_caddy_running`, `ensure_caddy_running`)
- Refresh daemon (`start_refresh_daemon`)

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

CREDS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rl"
CREDS_FILE="$CREDS_DIR/credentials"
CADDY_FILE="$CREDS_DIR/Caddyfile"
ANTHROPIC_PORT=9110
OPENAI_PORT=9111
KEYCHAIN_SERVICE="Claude Code-credentials"

# --- Credential store ---

creds_get() {
    local key="$1"
    [[ -f "$CREDS_FILE" ]] || return 0
    sed -n "s/^${key}=//p" "$CREDS_FILE" | tail -1
}

creds_set() {
    local key="$1" value="$2"
    mkdir -p "$CREDS_DIR"
    if [[ -f "$CREDS_FILE" ]]; then
        local tmp="$CREDS_FILE.tmp"
        grep -v "^${key}=" "$CREDS_FILE" > "$tmp" 2>/dev/null || true
        echo "${key}=${value}" >> "$tmp"
        mv "$tmp" "$CREDS_FILE"
    else
        echo "${key}=${value}" > "$CREDS_FILE"
    fi
    chmod 600 "$CREDS_FILE"
}

creds_resolve() {
    local key="$1"
    local val
    val=$(creds_get "$key")
    if [[ -z "$val" ]]; then
        val="${!key:-}"
    fi
    echo "$val"
}

# --- OAuth (macOS Keychain) ---

_read_keychain() {
    security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || return 1
}

import_claude_oauth() {
    local json
    json=$(_read_keychain) || return 1
    local token refresh
    token=$(echo "$json" | sed -n 's/.*"accessToken" *: *"\([^"]*\)".*/\1/p')
    refresh=$(echo "$json" | sed -n 's/.*"refreshToken" *: *"\([^"]*\)".*/\1/p')
    [[ -n "$token" ]] || return 1
    creds_set "ANTHROPIC_API_KEY" "$token"
    [[ -n "$refresh" ]] && creds_set "ANTHROPIC_REFRESH_TOKEN" "$refresh"
    creds_set "ANTHROPIC_AUTH_TYPE" "oauth"
    return 0
}

refresh_if_needed() {
    local auth_type
    auth_type=$(creds_get "ANTHROPIC_AUTH_TYPE")
    [[ "$auth_type" == "oauth" ]] || return 0
    import_claude_oauth || warn "OAuth token refresh failed"
}

# --- Caddy ---

generate_caddyfile() {
    local anthropic_key openai_key
    anthropic_key=$(creds_resolve "ANTHROPIC_API_KEY")
    openai_key=$(creds_resolve "OPENAI_API_KEY")

    mkdir -p "$CREDS_DIR"
    cat > "$CADDY_FILE" <<EOF
{
    admin localhost:2020
}

http://:${ANTHROPIC_PORT} {
    bind 127.0.0.1
    request_header x-api-key "${anthropic_key}"
    reverse_proxy https://api.anthropic.com {
        header_up Host api.anthropic.com
    }
}

http://:${OPENAI_PORT} {
    bind 127.0.0.1
    request_header Authorization "Bearer ${openai_key}"
    reverse_proxy https://api.openai.com {
        header_up Host api.openai.com
    }
}
EOF
    chmod 600 "$CADDY_FILE"
}

is_caddy_running() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ANTHROPIC_PORT}/" 2>/dev/null) || return 1
    [[ "$code" != "000" ]]
}

start_refresh_daemon() {
    local pid_file="$CREDS_DIR/refreshd.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
        return 0
    fi
    (
        while true; do
            sleep 300
            local auth_type
            auth_type=$(creds_get "ANTHROPIC_AUTH_TYPE")
            [[ "$auth_type" == "oauth" ]] || continue
            local old_key
            old_key=$(creds_get "ANTHROPIC_API_KEY")
            import_claude_oauth 2>/dev/null || continue
            local new_key
            new_key=$(creds_get "ANTHROPIC_API_KEY")
            if [[ "$old_key" != "$new_key" ]]; then
                generate_caddyfile
                caddy reload --config "$CADDY_FILE" 2>/dev/null || true
            fi
        done
    ) &
    echo $! > "$pid_file"
    disown
}

# --- Hooks ---

start() {
    local vm="$1"
    refresh_if_needed
    generate_caddyfile
    if is_caddy_running; then
        caddy reload --config "$CADDY_FILE" 2>/dev/null || warn "Caddy reload failed"
    else
        caddy start --config "$CADDY_FILE" 2>/dev/null
        sleep 1
        if ! is_caddy_running; then
            die "Failed to start Caddy proxy"
        fi
    fi
    local auth_type
    auth_type=$(creds_get "ANTHROPIC_AUTH_TYPE")
    [[ "$auth_type" == "oauth" ]] && start_refresh_daemon
    success "API proxy running (Anthropic :$ANTHROPIC_PORT, OpenAI :$OPENAI_PORT)"
}

rm() {
    # Only stop Caddy if no other airlocks are using it.
    # Check for other .rl/ directories with active plugins containing auth-proxy.
    # For simplicity in v1: warn but don't stop Caddy.
    info "Caddy proxy left running (may be shared with other airlocks). Stop manually: caddy stop"
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

- [ ] **Step 4: Create auth command**

Create `plugins/auth-proxy/commands/auth.sh`. Extract the `cmd_auth`, `_auth_anthropic`, `_auth_api_key`, and `_auth_status` functions from `lib/creds.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_DIR/plugin.sh"

_auth_api_key() {
    local key_name="$1" display_name="$2" url="$3"
    local existing
    existing=$(creds_get "$key_name")
    if [[ -n "$existing" ]]; then
        local masked="${existing:0:8}...${existing: -4}"
        info "Current $display_name key: $masked"
        local answer
        read -rp "Replace? (y/N) " answer
        [[ "${answer:-N}" =~ ^[Yy]$ ]] || return 0
    fi
    info "Get your key at: $url"
    local key
    read -rsp "Enter $display_name API key: " key
    echo ""
    [[ -n "$key" ]] || die "No key provided"
    creds_set "$key_name" "$key"
    success "$display_name key saved"
    if is_caddy_running; then
        generate_caddyfile
        caddy reload --config "$CADDY_FILE" 2>/dev/null || warn "Caddy reload failed"
    fi
}

_auth_anthropic() {
    info "Attempting OAuth import from Claude Code keychain..."
    if import_claude_oauth; then
        local token
        token=$(creds_get "ANTHROPIC_API_KEY")
        local masked="${token:0:8}...${token: -4}"
        success "OAuth token imported: $masked"
        start_refresh_daemon
        if is_caddy_running; then
            generate_caddyfile
            caddy reload --config "$CADDY_FILE" 2>/dev/null || warn "Caddy reload failed"
        fi
        return 0
    fi
    warn "Keychain import failed"
    echo ""
    echo "Options:"
    echo "  1) Run 'claude login' first, then retry"
    echo "  2) Enter API key manually"
    local choice
    read -rp "Choice (1/2): " choice
    case "$choice" in
        1)
            info "Run 'claude login' in another terminal, then run 'rl auth anthropic' again"
            ;;
        2)
            _auth_api_key "ANTHROPIC_API_KEY" "Anthropic" "https://console.anthropic.com/settings/keys"
            ;;
        *)
            die "Invalid choice"
            ;;
    esac
}

_auth_status() {
    echo "=== Credential Status ==="
    echo ""
    local anthropic_key openai_key auth_type
    anthropic_key=$(creds_get "ANTHROPIC_API_KEY")
    openai_key=$(creds_get "OPENAI_API_KEY")
    auth_type=$(creds_get "ANTHROPIC_AUTH_TYPE")

    if [[ -n "$anthropic_key" ]]; then
        local masked="${anthropic_key:0:8}...${anthropic_key: -4}"
        echo "Anthropic: configured ($masked) [type: ${auth_type:-api-key}]"
    else
        echo "Anthropic: not configured"
    fi

    if [[ -n "$openai_key" ]]; then
        local masked="${openai_key:0:8}...${openai_key: -4}"
        echo "OpenAI:    configured ($masked)"
    else
        echo "OpenAI:    not configured"
    fi

    local pid_file="${CREDS_DIR}/refreshd.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
        echo "Refresh:   running (PID $(<"$pid_file"))"
    else
        echo "Refresh:   stopped"
    fi
}

# Main dispatch
case "${1:-status}" in
    anthropic) _auth_anthropic ;;
    openai)    _auth_api_key "OPENAI_API_KEY" "OpenAI" "https://platform.openai.com/api-keys" ;;
    status)    _auth_status ;;
    *)         die "Usage: rl auth [anthropic|openai|status]" ;;
esac
```

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck plugins/auth-proxy/plugin.sh plugins/auth-proxy/commands/auth.sh`
Expected: No warnings.

- [ ] **Step 6: Commit**

```bash
git add plugins/auth-proxy/
git commit -m "feat: extract auth-proxy plugin"
```

---

### Task 9: agent-claude-code Plugin

**Files:**
- Create: `plugins/agent-claude-code/plugin.toml`
- Create: `plugins/agent-claude-code/plugin.sh`
- Create: `plugins/agent-claude-code/commands/claude.sh`

- [ ] **Step 1: Read current agent and SSH code**

Read `lib/agent.sh` (Claude Code installation) and `lib/ssh.sh` (`cmd_code` function).

- [ ] **Step 2: Create plugin.toml**

Create `plugins/agent-claude-code/plugin.toml`:

```toml
description = "Claude Code AI agent"
deps = ["auth-proxy"]
host_deps = []
triggers = [".claude"]
commands = ["claude"]
```

- [ ] **Step 3: Create plugin.sh**

Create `plugins/agent-claude-code/plugin.sh`:

```bash
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

# Configure mise with proxy URLs for ai user
su -l ai -c '
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
su -l ai -c "claude --version" && echo "AGENT_OK" || echo "AGENT_FAIL"
PROVISION
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

- [ ] **Step 4: Create claude command**

Create `plugins/agent-claude-code/commands/claude.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

vm_name=$(resolve_vm_name) || die "No airlock found in this directory"

if ! is_vm_running "$vm_name"; then
    info "Starting stopped VM..."
    aq start "$vm_name"
    if ! wait_for_ssh "$vm_name" 60; then
        die "SSH connection timed out"
    fi
fi

port=$(get_ssh_port "$vm_name")
ssh -t -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "$port" ai@localhost "cd ~/repo && tmux new-session -A -s rl"
```

- [ ] **Step 5: Run ShellCheck**

Run: `shellcheck plugins/agent-claude-code/plugin.sh plugins/agent-claude-code/commands/claude.sh`
Expected: No warnings.

- [ ] **Step 6: Commit**

```bash
git add plugins/agent-claude-code/
git commit -m "feat: extract agent-claude-code plugin"
```

---

### Task 10: agent-codex Plugin

**Files:**
- Create: `plugins/agent-codex/plugin.toml`
- Create: `plugins/agent-codex/plugin.sh`
- Create: `plugins/agent-codex/commands/codex.sh`

- [ ] **Step 1: Create plugin.toml**

Create `plugins/agent-codex/plugin.toml`:

```toml
description = "OpenAI Codex AI agent"
deps = ["auth-proxy"]
host_deps = []
triggers = []
commands = ["codex"]
```

Note: no trigger — codex is explicitly requested or pulled in by the user. The original auto-detection of `codex` on host PATH is not a file trigger, and adding binary-detection triggers is out of scope for v1 plugin architecture.

- [ ] **Step 2: Create plugin.sh**

Create `plugins/agent-codex/plugin.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

provision() {
    local vm="$1"
    aq exec "$vm" sh <<'PROVISION'
set -eu
apk add nodejs npm build-base python3

# Install Codex globally
npm install -g @openai/codex

# Install mise for env var management (if not already present)
apk add mise 2>/dev/null || true

# Configure mise with proxy URLs for ai user
su -l ai -c '
    mkdir -p ~/.codex

    # Add OpenAI env vars to mise.toml (append if exists)
    if [ -f ~/mise.toml ]; then
        grep -q "OPENAI_BASE_URL" ~/mise.toml || cat >> ~/mise.toml <<MISE
OPENAI_BASE_URL = "http://10.0.2.2:9111/v1"
OPENAI_API_KEY = "dummy"
MISE
    else
        cat > ~/mise.toml <<MISE
[env]
OPENAI_BASE_URL = "http://10.0.2.2:9111/v1"
OPENAI_API_KEY = "dummy"
MISE
    fi

    cat > ~/.codex/config.toml <<CONFIG
openai_base_url = "http://10.0.2.2:9111/v1"
CONFIG

    # Ensure mise activates in bash
    grep -q "mise activate" ~/.bashrc || echo "eval \"\$(mise activate bash)\"" >> ~/.bashrc
'

# Verify installation
su -l ai -c "codex --version" && echo "AGENT_OK" || echo "AGENT_FAIL"
PROVISION
}

# Dispatch
if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
```

- [ ] **Step 3: Create codex command**

Create `plugins/agent-codex/commands/codex.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

vm_name=$(resolve_vm_name) || die "No airlock found in this directory"

if ! is_vm_running "$vm_name"; then
    info "Starting stopped VM..."
    aq start "$vm_name"
    if ! wait_for_ssh "$vm_name" 60; then
        die "SSH connection timed out"
    fi
fi

port=$(get_ssh_port "$vm_name")
ssh -t -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "$port" ai@localhost "cd ~/repo && tmux new-session -A -s rl"
```

- [ ] **Step 4: Run ShellCheck**

Run: `shellcheck plugins/agent-codex/plugin.sh plugins/agent-codex/commands/codex.sh`
Expected: No warnings.

- [ ] **Step 5: Commit**

```bash
git add plugins/agent-codex/
git commit -m "feat: extract agent-codex plugin"
```

---

### Task 11: Cleanup + ShellCheck + KNOWN-LIMITATIONS.md

**Files:**
- Delete: `lib/vm.sh`, `lib/ssh.sh`, `lib/proxy.sh`, `lib/creds.sh`, `lib/agent.sh`
- Create: `KNOWN-LIMITATIONS.md`

- [ ] **Step 1: Delete old library files**

```bash
git rm lib/vm.sh lib/ssh.sh lib/proxy.sh lib/creds.sh lib/agent.sh
```

- [ ] **Step 2: Run ShellCheck on all shell files**

```bash
shellcheck bin/rl lib/*.sh plugins/*/plugin.sh plugins/*/commands/*.sh
```

Fix any warnings found.

- [ ] **Step 3: Run all BATS tests**

```bash
bats test/
```

Expected: All tests pass.

- [ ] **Step 4: Create KNOWN-LIMITATIONS.md**

Create `KNOWN-LIMITATIONS.md`:

```markdown
# Known Limitations

## Plugin Architecture

- **No dynamic plugin activation** — plugins are determined at `rl new` time. Adding a plugin to a running airlock requires `rl rm` + `rl new`.
- **No `rl plugin install`** — third-party plugins must be manually placed in `~/.config/rl/plugins/`.
- **Flat TOML only** — plugin manifests support flat key-value pairs and simple arrays. No nested tables or complex structures.
- **No plugin versioning** — no version field, no compatibility checks between plugins.
- **No binary trigger detection** — triggers only match files/directories in the project root, not binaries on the host PATH.

## Guest Environment

- **musl vs glibc** — Alpine uses musl libc. Some projects with native extensions compiled for glibc may fail at runtime even when packages install successfully.
- **Alpine-only guest OS** — all plugins provision against Alpine Linux. Debian/Ubuntu-based workflows are not supported.
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove old monolithic lib files, add KNOWN-LIMITATIONS.md"
```

- [ ] **Step 6: Final integration smoke test (manual)**

Test the full flow manually:

```bash
cd /path/to/a/git/repo/with/.claude
rl new git claude-code
# Should: create VM, provision base + git + claude-code, start Caddy, prompt for git remote
rl status
# Should: show running VM with plugins listed
rl claude
# Should: SSH+tmux into VM
# Detach with Ctrl-B D
rl ssh
# Should: plain SSH into VM
rl rm
# Should: clean up everything
```
