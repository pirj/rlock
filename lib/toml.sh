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
