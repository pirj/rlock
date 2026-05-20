#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------
# Generic TOML helpers — no rlock-specific state, no plugin-protocol
# assumptions baked in. Functions take a TOML file path + key/section
# arguments and operate purely on the file. Safe to source from
# downstream consumers:
#
#   * rlock itself — `bin/rl` uses these to parse `plugin.toml`
#     manifests and project-local rlock state.
#   * Distributions on top of rlock (bakeri.sh, ai.rlock) — source via
#     `source "${RL_LIB_DIR}/toml.sh"` (RL_LIB_DIR is exported by rlock
#     into every plugin's environment) for distribution-specific config
#     files such as `bakeri.toml`. Don't reach into rlock's plugin
#     internals — keep this file the only shared surface.
#
# Anything added here must work for any TOML file, not just rlock's
# plugin manifests. If you need rlock-specific semantics, put them in
# `lib/plugin.sh` instead.
# ---------------------------------------------------------------------

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

# Parse a string value from a [section] in a TOML file.
# Usage: toml_get_in_section file section key
# Prints the value (unquoted) or empty string if section/key not found.
toml_get_in_section() {
    local file="$1" section="$2" key="$3"
    awk -v sec="[$section]" -v k="$key" '
        $0 == sec { in_sec = 1; next }
        /^\[/     { in_sec = 0; next }
        in_sec && $0 ~ "^" k " *= *\"" {
            sub("^" k " *= *\"", ""); sub("\".*", "")
            print; exit
        }
    ' "$file"
}

# Parse an array value from a [section] in a TOML file.
# Usage: toml_get_array_in_section file section key
# Prints one element per line. Empty output if section/key missing or
# array empty. Single-line array form only (`key = ["a", "b"]`); the
# multi-line form (`key = [\n "a",\n "b",\n]`) is intentionally not
# supported — keep it simple, and TOML allows the single-line form
# everywhere.
toml_get_array_in_section() {
    local file="$1" section="$2" key="$3"
    awk -v sec="[$section]" -v k="$key" '
        $0 == sec { in_sec = 1; next }
        /^\[/     { in_sec = 0; next }
        in_sec && $0 ~ "^" k " *= *\\[" {
            sub("^[^[]*\\[", "")
            sub("\\].*", "")
            n = split($0, items, ",")
            for (i = 1; i <= n; i++) {
                if (match(items[i], /"[^"]*"/)) {
                    print substr(items[i], RSTART + 1, RLENGTH - 2)
                }
            }
            exit
        }
    ' "$file"
}

# Validate that no table header repeats in a TOML file.
# TOML 1.0 forbids re-declaring a table — `[fruit]` … `[fruit]` is an
# error. Catches the common copy-paste mistake when projects grow
# `[prebuild.foo]` / `[prebuild.bar]` style sections. Subtables (`[a.b]`
# vs `[a]`) are *not* flagged — they're distinct tables.
#
# Usage: toml_validate file
# Returns 0 if clean, 1 (with stderr message listing the offenders) if
# any header appears more than once.
toml_validate() {
    local file="$1"
    local dups
    # Match table headers `[anything-without-brackets]` only — `[[array
    # -of-tables]]` syntax is intentionally not supported, and repeated
    # `[[…]]` lines (which TOML *does* allow) wouldn't be flagged here
    # because the grep requires single brackets. Trailing comments /
    # whitespace are stripped before deduping.
    dups=$(grep -E '^\[[^][]+\]' "$file" 2>/dev/null \
        | sed -E 's/[[:space:]]*#.*$//' \
        | sort | uniq -d)
    if [[ -n "$dups" ]]; then
        echo "Error: $file has duplicate table headers (TOML forbids this):" >&2
        printf '  %s\n' $dups >&2
        return 1
    fi
    return 0
}
