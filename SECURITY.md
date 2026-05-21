# Security policy

## Scope

rlock provides VM-level isolation between host and guest via QEMU. The
guest runs an Alpine VM and the framework configures sshd / a non-root
`rlock` user / per-VM Ed25519 keys. Anything that lets:

- guest code escape the VM,
- host credentials leak into the guest unsolicited,
- plugin protocol bugs widen the attack surface (e.g. arbitrary command
  execution from an untrusted `plugin.toml`),

is a security issue and should be reported privately.

## Out of scope

- Code that runs **inside** the guest VM exfiltrating data through
  channels the host explicitly enabled (e.g. user-configured
  network access, user-supplied SSH agent forwarding). The guest is
  not a sandbox against the user's own configuration — it's a
  sandbox against the host being compromised by guest code.
- Issues in upstream QEMU, the Linux kernel, Alpine packages, etc.
  Report those to their respective projects.
- Plugin-pack-specific issues (bakeri.sh, ai.rlock, anything in
  `~/.config/rl/plugins/`) — report to the plugin pack's repo.

## Reporting

Open a private security advisory on this repo via GitHub's
[security advisories interface](https://github.com/pirj/rlock/security/advisories/new).

If GitHub advisories aren't suitable, email pirjsuka@gmail.com with
"rlock security" in the subject.

Don't open a public issue for a credible vulnerability before the
maintainer has acknowledged it.

## Supported versions

Only the `main` branch and the most recent tagged release receive
security fixes. Pin to a tag in production and watch the changelog.
