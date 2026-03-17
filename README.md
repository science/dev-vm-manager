# dev-vm-manager

Automated creation and provisioning of isolated dev VMs using Incus (KVM/QEMU).

## Problem

Dev VMs need to be created and re-created from scratch, provisioned with a full desktop and dev tools, and configured with yadm dotfiles — reproducibly and without manual steps beyond a single GPG passphrase prompt.

## Project Goals

1. **Isolated dev environments** — VMs are fully isolated from the host OS filesystem, except specific shared mounts (`~/dev` and `~/Pictures`). These VMs host Claude Code AI development.
2. **Reproducible setup** — `create-dev-vm dev-1` produces the same result every time regardless of starting state.
3. **yadm as source of truth** — Desktop, dev tools, and all configuration are managed by yadm bootstrap, keeping VMs and host OS in sync from one source of truth.
4. **Portable** — works across multiple developer workstations with no hardcoded machine-specific values.

## VMs

| Name | Purpose |
|------|---------|
| dev-1 | General dev VM |
| dev-2 | General dev VM |

Ubuntu 24.04 (Noble), 8 GiB RAM, 4 vCPUs, 40 GB disk, virtiofs mounts for `~/dev` and `~/Pictures`. IPs assigned via DHCP.

## Usage

```bash
# First time: install dependencies
./setup.sh

# Create a VM (handles everything end-to-end)
./create-dev-vm dev-1

# Destroy a VM
./destroy-dev-vm dev-1

# Access the VM
ssh steve@dev-1
incus console dev-1 --type vga
```

## How It Works

1. **create-dev-vm** creates a bare VM with Incus, configures a user and SSH via `incus exec`, installs openssh-server
2. **provision.sh** adds shared directories (stop/start cycle), installs yadm/gh, copies auth credentials from host, clones dotfiles, decrypts secrets (GPG passphrase — the only interactive step), runs yadm bootstrap

## Structure

```
.
├── README.md           # This file
├── CLAUDE.md           # AI assistant guidance
├── plan.md             # Architecture decisions and tasks
├── config.sh           # Shared configuration (VM names, resources, paths)
├── setup.sh            # Install incus + apt-cacher-ng
├── create-dev-vm       # Main entry point: create + configure + provision
├── destroy-dev-vm      # Tear down a VM cleanly
├── provision.sh        # yadm deployment (shared dirs, auth, clone, bootstrap)
├── cloud-init/         # Templates (historical, not currently used)
│   └── user-data.tpl
└── tests/
    └── smoke-test.sh   # Quick VM health check
```

## Dependencies

- Host: Ubuntu 24.04 with KVM support
- Incus (installed via `setup.sh`)
- apt-cacher-ng on host (optional, for fast VM package caching — VMs are clients, not servers)
- SSH key at `~/.ssh/id_ed25519.pub`
- yadm dotfiles repo: `https://github.com/science/dotfiles.git`

## Relationship to yadm dotfiles

This project is **not** tracked by yadm. It lives in `~/dev/dev-vm-manager/` as its own git repo. The provisioning script calls yadm to deploy and test dotfiles on the new VM.

apt-cacher-ng is installed on host machines via yadm bootstrap (gated on `! is_vm_machine`). VMs are configured as clients by `create-dev-vm` at VM creation time — they proxy apt through the host's bridge IP. This means host machines serve cached packages to all their VMs without the VMs needing apt-cacher-ng themselves.
