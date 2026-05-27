#!/usr/bin/env bash
#
# _base — framework-level provisioning shared across every rlock
# distribution. Lifts the apk-add / rlock-user / sshd-hardening block
# that used to live inline in cmd_new into a proper snapshot layer with
# a constant snapshot_key, so the second cold `rl new` on the host —
# regardless of distribution (ai.rlock / snapcompose / anything future) —
# gets a cache hit instead of paying ~30 s of repeat provisioning.
#
# The leading underscore in the plugin name marks this as framework-
# internal: discover_plugins / detect_triggers skip names starting
# with `_`. The plugin is auto-prepended to the resolved chain by
# `rl new` and shouldn't be referenced by user-facing tools.

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

RECIPE_VERSION="v1"

# Constant key: this is a host-level layer shared across every project.
# Any project on the host that resolves to this recipe version hits the
# same cached snapshot. Bump the version string when the recipe below
# changes meaningfully.
snapshot_key() {
    printf '_base-recipe-%s' "$RECIPE_VERSION" | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    aq exec "$vm" sh <<'BASE_PROVISION'
set -eu
# Enlarge /tmp — default tmpfs is too small for compiling runtimes.
mount -o remount,size=1G /tmp

# Enable Alpine's community repo (mise lives there).
sed -i 's/^#\(.*community\)/\1/' /etc/apk/repositories
apk update
apk add bash curl sudo openssh-server-pam

# Non-root user that downstream provisioning runs as.
adduser -D -s /bin/bash rlock
echo "rlock ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/rlock
mkdir -p /home/rlock/.ssh
cp /root/.ssh/authorized_keys /home/rlock/.ssh/
chown -R rlock:rlock /home/rlock/.ssh
chmod 700 /home/rlock/.ssh
chmod 600 /home/rlock/.ssh/authorized_keys

# sshd hardening. AllowTcpForwarding and X11Forwarding already off in sshd_config.
cat > /etc/ssh/sshd_config.d/base.conf <<'SSHD'
# Allow locked accounts (no password) to authenticate via pubkey.
# The rlock user has no password by design — keys are the only auth method.
UsePAM yes

# Default is "yes". Disable — pubkey only, no password prompts.
PasswordAuthentication no

# Default is "yes". Disable — prevents challenge-response password fallback.
KbdInteractiveAuthentication no

# Default is "yes". Disable — agent in the VM must not reach host SSH keys.
AllowAgentForwarding no

# Default is "yes". Disable — aq already shows its own motd.
PrintMotd no

# Default is "prohibit-password" (matches our intent). Be explicit:
# root can SSH in for provisioning, but only via pubkey.
PermitRootLogin prohibit-password
SSHD
rc-service sshd restart
BASE_PROVISION
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
