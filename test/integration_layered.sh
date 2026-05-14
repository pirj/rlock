#!/usr/bin/env bash
set -euo pipefail

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

echo ">>> Cold rl new (expect 5+ min)"
t0=$(date +%s)
yes | rl new docker-compose
t_cold=$(( $(date +%s) - t0 ))
echo "Cold: ${t_cold}s"

rl rm

echo ">>> Warm rl new (expect <5s)"
t0=$(date +%s)
yes | rl new docker-compose
t_warm=$(( $(date +%s) - t0 ))
echo "Warm: ${t_warm}s"

if [ "$t_warm" -gt 5 ]; then
    echo "FAIL: warm boot took ${t_warm}s, expected < 5s"
    exit 1
fi
echo "PASS"
