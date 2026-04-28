#!/usr/bin/env bash
set -euo pipefail

# Sanitize a string for use as a directory/VM name.
# Replaces /, :, \, and other unsafe chars with underscore.
_branch_sanitize() {
    local s="$1"
    printf '%s' "$s" | tr '/:\134' '___' | tr -cd 'A-Za-z0-9._@-' | sed 's/__*/_/g'
}

# Get current git branch name (empty on detached HEAD).
_branch_current() {
    git symbolic-ref --short HEAD 2>/dev/null
}

# Determine base sha for a branch (where it diverged from a known root).
# Tries: origin/main, origin/master, main, master.
# If branch IS one of these, or none exist, base = current HEAD.
_branch_base_sha() {
    local branch="$1"
    local candidates="origin/main origin/master main master"
    local cand sha

    # If branch itself is a root branch, return its HEAD
    case "$branch" in
        main|master|origin/main|origin/master)
            git rev-parse --short=7 HEAD 2>/dev/null
            return 0
            ;;
    esac

    for cand in $candidates; do
        if git rev-parse --verify --quiet "$cand" > /dev/null 2>&1; then
            sha=$(git merge-base HEAD "$cand" 2>/dev/null) || continue
            git rev-parse --short=7 "$sha"
            return 0
        fi
    done

    # No root branch found — use current HEAD
    git rev-parse --short=7 HEAD 2>/dev/null
}

# Compute the VM name for the current branch.
# Format: <sanitized-branch>@<short-sha-base>
# Returns non-zero on detached HEAD or non-git directory.
_branch_vm_name() {
    local branch
    branch=$(_branch_current) || return 1
    [[ -n "$branch" ]] || return 1
    local base_sha
    base_sha=$(_branch_base_sha "$branch") || return 1
    [[ -n "$base_sha" ]] || return 1
    echo "$(_branch_sanitize "$branch")@${base_sha}"
}

# Find a snapshot.qcow2 belonging to a VM whose name ends with @<sha>.
# Usage: _branch_find_ancestor_snapshot <short-sha>
# Outputs the absolute path to snapshot.qcow2, or empty if none found.
_branch_find_ancestor_snapshot() {
    local sha="$1"
    local aq="${AQ_STATE_DIR:-$HOME/.local/share/aq}"
    [[ -d "$aq" ]] || return 0
    local dir
    for dir in "$aq"/*; do
        [[ -d "$dir" ]] || continue
        case "$(basename "$dir")" in
            *@"$sha")
                if [[ -f "$dir/snapshot.qcow2" ]]; then
                    echo "$dir/snapshot.qcow2"
                    return 0
                fi
                ;;
        esac
    done
}
