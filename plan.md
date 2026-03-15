# Plan: dev-vm-manager

## Goals

1. **Reproducible VM creation** — a single command (`create-dev-vm dev-1`) creates a fully working dev VM from nothing. No manual steps except GPG passphrase.
2. **Clean teardown** — `destroy-dev-vm dev-1` removes everything. No stale state.
3. **Idempotent provisioning** — running `provision.sh` on an already-provisioned VM is safe and fast.
4. **Tested** — smoke tests verify the VM is healthy before and after provisioning.
5. **Single VM at a time** — the system creates one VM per invocation. Known VMs (dev-1, dev-2) are defined in config.sh.
6. **Leverage yadm as source of truth** — cloud-init does the bare minimum (user, SSH, hostname). Everything else — desktop, tools, config — is yadm bootstrap's job, keeping VMs and host OS in sync.
7. **Portable** — no hardcoded machine-specific values. Must work across multiple developer workstations.

### Success Criteria

1. `create-dev-vm dev-1` detects existing VM and prompts to overwrite.
2. The system is fully self-contained: one command delivers a working VM regardless of starting state.
3. Package installs are fast on repeat runs via local apt cache.

## Architecture Decisions

### Why Incus (not Terraform + libvirt)

Terraform's libvirt provider had persistent bugs across v0.8 and v0.9: volume permissions (qcow2 owned by root, QEMU can't write), computed-value crashes, stale state incompatibilities between provider versions. These are not fixable from our side. Incus manages KVM/QEMU directly, handles disk ownership, networking, and device attachment without an intermediate abstraction layer. VM creation that took hours of debugging with Terraform works first try with Incus.

### Why DHCP (not static IPs)

Static IPs were a workaround for unreliable libvirt DHCP (stale dnsmasq leases, timing races). Incus manages its own DHCP via incusbr0 reliably. The script discovers the assigned IP at runtime via `incus list` and updates /etc/hosts.

### Why cloud-init is minimal

Cloud-init only does what's needed for SSH access: create user `steve`, install `openssh-server`, set hostname. Desktop environment, dev tools, and all other software are installed by yadm bootstrap. This keeps a single source of truth for environment configuration and means VMs and host OS stay in sync.

### Why separate provision.sh from VM creation

Incus creates infrastructure (VM, disk, network). provision.sh handles interactive prompts (GPG passphrase) and multi-step SSH provisioning (yadm clone, decrypt, bootstrap, test).

### Why virtiofs for ~/dev and ~/Pictures

- `~/dev` is shared so AI agents inside VMs can edit code that's also accessible from the host
- `~/Pictures` is shared for screenshot workflows
- Only these two dirs — no host filesystem access beyond them (blast radius protection)
- Incus manages virtiofs via disk devices (no manual memfd/shared config needed)

### Why apt-cacher-ng

Cinnamon desktop + dev tools = ~1.2 GB of packages. Without caching, every VM rebuild or yadm bootstrap re-run downloads all of it from the internet (~15-20 min). apt-cacher-ng runs on the host and transparently caches .debs. First run is slow; every subsequent run pulls from local disk.

This benefits:
- **VM rebuilds** — the primary use case. destroy + create cycles during development are fast.
- **yadm bootstrap re-runs** — re-running bootstrap on the host or a VM hits cache.
- **New VMs on the same host** — dev-2 gets the same cached packages dev-1 already downloaded.

It does NOT help the first yadm bootstrap on a truly fresh machine (nothing in cache yet). But every run after that is cached.

## Tasks

### Phase 1: Incus + Host Setup
- [x] Install incus, configure incus-admin group, `incus admin init --minimal`
- [x] Download and cache base image (`images:ubuntu/24.04/cloud` as `dev-vm-ubuntu-2404`)
- [x] Install apt-cacher-ng on host
- [x] Pre-warm apt cache with cinnamon-desktop-environment and dev tools (~1.2 GB)
- [ ] Write setup.sh (install incus + apt-cacher-ng, init incus, download base image)

### Phase 2: VM Creation Scripts
- [x] Write config.sh (VM names, resources, image, paths)
- [x] Write cloud-init/user-data.tpl (minimal: user, SSH, hostname, apt proxy)
- [x] Write create-dev-vm (image cache check, incus init, devices, start, DHCP discovery, smoke test, provision)
- [x] Write destroy-dev-vm (incus delete, /etc/hosts cleanup, SSH key cleanup)
- [x] Write smoke-test.sh (incus checks, SSH, cloud-init status)
- [ ] Test: `create-dev-vm dev-1` end-to-end
- [ ] Test: `create-dev-vm dev-2` while dev-1 exists
- [ ] Verify virtiofs shared directories work inside VM
- [ ] Verify SPICE console works with Cinnamon desktop (`incus console dev-1 --type vga`)

### Phase 3: Provisioning
- [x] Write provision.sh (yadm deploy: install yadm/gh, copy creds, clone, decrypt, bootstrap, test)
- [ ] Handle GPG pinentry timeout (set pinentry-timeout 0 before decrypt)
- [ ] Test: provision.sh on a fresh VM passes all yadm tests

### Phase 4: yadm Integration
- [ ] Add apt-cacher-ng to yadm bootstrap (install early, before bulk package installs)
- [ ] Add cinnamon-desktop-environment, lightdm, slick-greeter, gnome-terminal, spice-vdagent to yadm bootstrap package list (if not already there)
- [ ] Add lightdm autologin config to yadm (write /etc/lightdm/lightdm.conf.d/90-autologin.conf)
- [ ] Add `systemctl set-default graphical.target` to yadm bootstrap
- [ ] Ensure yadm bootstrap detects and uses apt-cacher-ng proxy when available
- [ ] Test: yadm bootstrap on fresh VM installs full desktop + tools

### Phase 5: Cleanup
- [ ] Remove create-dev-vm.py from yadm
- [ ] Remove create-dev-vm.sh from yadm
- [ ] Update deploy-vm.sh to call provision.sh or remove it
- [ ] Update yadm bootstrap to reference this project
- [ ] Update CLAUDE.md, README.md for current architecture
- [ ] Remove cloud-init/network-config.tpl (no longer used)

## Known Issues

- Incus containers fail on this host (cgroup mount error) — use VMs only
- UEFI VMs don't support internal snapshots — use qcow2 file copies for backups
- GPG pinentry has a default timeout — must set `pinentry-timeout 0` before decrypt
- Ubuntu Noble cloud images need `openssh-server` explicitly (not in base image)
- `images:ubuntu/24.04` (non-cloud) has no cloud-init — must use `images:ubuntu/24.04/cloud`
