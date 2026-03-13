# dev-vm-manager — AI Assistant Guide

## What This Project Does

Creates and provisions KVM/libvirt dev VMs using Terraform + cloud-init, then deploys yadm dotfiles via SSH. The host is `linux-bambam` (Ubuntu 24.04, Cinnamon desktop).

## Key Constraints

1. **Terraform manages infrastructure, provision.sh manages software.** Don't mix these — Terraform creates a bootable VM with SSH access, provision.sh does everything else.
2. **The only interactive step is GPG passphrase entry.** Everything else must be automated. Set `pinentry-timeout 0` in the VM's gpg-agent.conf before decrypting.
3. **VMs use static IPs via cloud-init network-config.** Do NOT use libvirt DHCP reservations — they are unreliable (stale leases, timing races, dnsmasq state issues). The cloud-init `network-config` file sets the IP before the guest OS touches the network.
4. **virtiofs requires `memorybacking source.type=memfd,access.mode=shared`** in the domain definition. Without this, virtiofs mounts fail silently.
5. **UEFI boot is required** (`firmware = "/usr/share/OVMF/OVMF_CODE.fd"`). Internal snapshots don't work with UEFI — use qcow2 file copies for backups.

## VM Specs

| Setting | Value |
|---------|-------|
| OS | Ubuntu 24.04 Noble (cloud image) |
| RAM | 8 GiB |
| vCPUs | 4 |
| Disk | 40 GB qcow2 |
| Network | libvirt default (192.168.122.0/24) |
| dev-1 IP | 192.168.122.101 |
| dev-2 IP | 192.168.122.102 |
| NIC | virtio (guest sees `enp1s0`) |
| Graphics | SPICE + virtio GPU |
| Shared dirs | ~/dev (virtiofs), ~/Pictures (virtiofs) |

## Cloud-init Responsibilities

Cloud-init installs **only** what's needed to boot to desktop + enable SSH:
- cinnamon-desktop-environment, lightdm, slick-greeter, gnome-terminal
- spice-vdagent, openssh-server
- User `steve` with NOPASSWD sudo and SSH key
- Autologin config
- virtiofs fstab entries
- Static IP via network-config

Everything else (curl, git, gh, yadm, build-essential, nodejs, etc.) is yadm bootstrap's job.

## provision.sh Responsibilities

1. Install yadm + gh on the VM
2. Copy GitHub auth (`~/.config/gh/hosts.yml`) and Claude auth (`~/.claude.json`) from host
3. Set up git credential helper for GitHub
4. `yadm clone` (or pull if exists)
5. Decrypt secrets (interactive GPG — the only manual step)
6. Re-setup credential helper (yadm checkout may overwrite .gitconfig)
7. `YADM_INSTALL=1 yadm bootstrap`
8. Run test suite (`~/.config/yadm/test-dotfiles.sh`)

## Terraform Provider Notes

The `dmacvicar/libvirt` provider:
- `libvirt_volume` — manages qcow2 disk images
- `libvirt_cloudinit_disk` — creates seed ISO from user-data + network-config
- `libvirt_domain` — creates the VM with all hardware config
- State is in `terraform.tfstate` — don't delete this file
- `terraform destroy` cleanly removes everything it created

## Testing

After `terraform apply`:
- `ping <vm-ip>` should work immediately
- `ssh steve@<vm-name> true` should work within ~2 min (cloud-init installing openssh)
- `ssh steve@<vm-name> cloud-init status` should show `done` after ~15-20 min

After `provision.sh`:
- `ssh steve@<vm-name> '~/.config/yadm/test-dotfiles.sh'` — 99 tests, 0 failures

## Don'ts

- Don't use `virsh net-update` for DHCP reservations — use static IP in cloud-init
- Don't manage dnsmasq leases — they're unreliable
- Don't use `gateway4` in netplan — deprecated, use `routes`
- Don't put VM management scripts in yadm — they belong here
- Don't use `sudo -i` on linux-bambam — use `sudo <cmd>` (PAM fingerprint issue)
- Don't pipe install scripts to `sh` — Ubuntu's sh is dash; use `bash`

## sudo on linux-bambam

This host has fingerprint-authenticated sudo via PAM. `sudo <cmd>` shows a GUI fingerprint popup. `sudo -i` bypasses it and will fail/timeout in non-TTY contexts. Always use `sudo <cmd>`.
