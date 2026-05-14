#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
FIXTURE="$ROOT/test/fixtures/rails-pg-sample"

work=$(mktemp -d)
trap 'rl rm 2>/dev/null || true; rm -rf "$work"' EXIT
cp -r "$FIXTURE"/. "$work/"
cd "$work"
git init -q -b main
git -c commit.gpgsign=false -c user.email=t -c user.name=t add .
git -c commit.gpgsign=false -c user.email=t -c user.name=t commit -qm init

# Auto-answer Y to any interactive "Include plugin? (Y/n)" prompts.
# Without pipefail (intentional, see below): `yes` exits 141 with SIGPIPE
# once `rl` closes stdin, which would otherwise abort the script.
auto_y() {
    set +o pipefail 2>/dev/null || true
    yes | "$@"
    local rc=$?
    return $rc
}

echo ">>> Cold rl new (expect 5+ min)"
t0=$(date +%s)
auto_y rl new docker-compose
t_cold=$(( $(date +%s) - t0 ))
echo "Cold: ${t_cold}s"

rl rm

echo ">>> Warm rl new (expect <5s)"
t0=$(date +%s)
auto_y rl new docker-compose
t_warm=$(( $(date +%s) - t0 ))
echo "Warm: ${t_warm}s"

if [ "$t_warm" -gt 5 ]; then
    echo "FAIL: warm boot took ${t_warm}s, expected < 5s"
    exit 1
fi
echo "PASS"
