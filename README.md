# dev-vm-manager

Automated creation and provisioning of isolated KVM dev VMs using [Incus](https://linuxcontainers.org/incus/). Designed for AI-assisted development workflows where you want full desktop VMs with blast-radius protection for the host OS.

## Why

When using AI coding agents (Claude Code, etc.) for aggressive development, you want the agent to have full root access, install packages freely, and experiment without risk to your host system. These scripts create disposable Ubuntu VMs that:

- Share your code directory (`~/dev`) and Claude state (`~/.claude`) via virtiofs — so sessions, credentials, and repos are seamless across host and VMs
- Are fully provisioned with a Cinnamon desktop, version-managed dev tools (Python, Node, Ruby, Rust), and your dotfiles
- Can be destroyed and recreated from scratch in minutes
- Require exactly one manual step: a GPG passphrase prompt for encrypted secrets

## Quick Start

```bash
# Install Incus and dependencies
./setup.sh

# Symlink scripts into ~/.local/bin
./install.sh

# Create a VM (end-to-end: create, configure, provision, test)
create-dev-vm dev-1

# Boot / shutdown (supports multiple VMs)
boot-vm dev-1 dev-2
shutdown-vm dev-1 dev-2

# Destroy and rebuild
destroy-dev-vm dev-1
create-dev-vm dev-1

# SSH access
ssh steve@dev-1
```

## VM Specs

| Setting | Value |
|---------|-------|
| OS | Ubuntu 24.04 Noble |
| RAM | 8 GiB |
| vCPUs | 4 |
| Disk | 40 GB |
| Desktop | Cinnamon (LightDM autologin) |
| Display | SPICE (`boot-vm` opens console) |
| Network | DHCP via Incus bridge |
| Shared dirs | `~/dev`, `~/Pictures`, `~/.claude` (virtiofs) |

## How It Works

**`create-dev-vm`** handles everything:

1. Caches the Ubuntu base image locally (one-time download)
2. Creates the VM via `incus init` + `incus start`
3. Waits for DHCP IP, updates `/etc/hosts`
4. Configures user, SSH key, hostname, timezone, apt proxy via `incus exec`
5. Hands off to `provision.sh`

**`provision.sh`** deploys the environment:

1. Stops VM, adds virtiofs shared directories, restarts
2. Installs yadm + gh, copies GitHub and Claude auth from host
3. Clones dotfiles via yadm, decrypts secrets (GPG — the only manual step)
4. Runs `yadm bootstrap` which installs the full desktop, dev tools, version managers, and applies dconf settings
5. Reboots the VM to pick up all new services
6. Runs the dotfiles test suite

## Scripts

| Script | Purpose |
|--------|---------|
| `create-dev-vm` | Create and provision a VM end-to-end |
| `destroy-dev-vm` | Tear down a VM cleanly |
| `boot-vm` | Start VM(s), update /etc/hosts, open SPICE console |
| `shutdown-vm` | Graceful shutdown via systemd (works with Cinnamon desktop) |
| `provision.sh` | yadm deployment (called by create-dev-vm) |
| `install.sh` | Symlink scripts into ~/.local/bin |
| `setup.sh` | Install Incus and dependencies |
| `config.sh` | Shared configuration (VM names, resources, paths) |

## Dependencies

- Ubuntu 24.04 host with KVM support
- Incus (installed by `setup.sh`)
- SSH key at `~/.ssh/id_ed25519.pub`
- [yadm](https://yadm.io/) dotfiles repo for environment configuration
- apt-cacher-ng on host (optional, dramatically speeds up repeated builds)

## Design Decisions

- **No cloud-init.** VM configuration uses `incus exec` with standard OS commands. This avoids cloud-init's YAML quirks and ordering issues.
- **yadm is the source of truth.** These scripts install only the bare minimum (user, SSH, openssh-server). Everything else — desktop, dev tools, shell config — comes from yadm bootstrap.
- **Virtiofs over 9p.** Shared directories use virtiofs for near-native performance. Devices are added after user creation to avoid mount-point permission issues.
- **systemctl poweroff over ACPI.** Cinnamon's settings daemon blocks the ACPI power button signal, so `shutdown-vm` uses `incus exec systemctl poweroff` instead of `incus stop`.
- **Portable.** No hardcoded IPs, timezones, or bridge names. Everything is discovered at runtime.

## License

Apache 2.0 — see [LICENSE](LICENSE).
