# dev-vm-manager — AI Assistant Guide

## What This Project Does

Creates and provisions KVM dev VMs using Incus, then deploys yadm dotfiles via SSH. The host runs Ubuntu 24.04 with Cinnamon desktop.

## Key Constraints

1. **create-dev-vm creates infrastructure, provision.sh configures software.** Don't mix these — create-dev-vm makes a bootable VM with a user and SSH, provision.sh does everything else.
2. **The only interactive step is GPG passphrase entry.** Everything else must be automated. Set `pinentry-timeout 0` in the VM's gpg-agent.conf before decrypting.
3. **VMs use DHCP.** Incus manages DHCP via incusbr0. The script discovers the assigned IP at runtime via `incus list` and updates /etc/hosts.
4. **No cloud-init.** VM configuration (user, SSH, hostname, packages) is done via `incus exec` after boot. This avoids cloud-init's YAML quirks and ordering issues.
5. **yadm is the source of truth for environment config.** Cloud-init / create-dev-vm install only the bare minimum (user, SSH, openssh-server). Desktop, dev tools, and all other software are yadm bootstrap's job.
6. **Portable — no hardcoded machine-specific values.** Must work across multiple developer workstations.

## VM Specs

| Setting | Value |
|---------|-------|
| OS | Ubuntu 24.04 Noble |
| RAM | 8 GiB |
| vCPUs | 4 |
| Disk | 40 GB |
| Network | Incus managed DHCP (incusbr0) |
| Graphics | SPICE (via `incus console --type vga`) |
| Shared dirs | ~/dev (virtiofs), ~/Pictures (virtiofs) |

## create-dev-vm Responsibilities

1. Validate VM name against known list in config.sh
2. Prompt to destroy if VM already exists
3. Cache base image locally (one-time download)
4. `incus init` + `incus start`
5. Wait for DHCP IP, update /etc/hosts
6. Wait for incus agent
7. Configure via `incus exec`: user, SSH key, hostname, timezone, apt proxy, openssh-server
8. Run smoke test
9. Hand off to provision.sh

## provision.sh Responsibilities

1. Stop VM, add virtiofs shared directories (~/dev, ~/Pictures), restart
2. Wait for SSH
3. Install yadm + gh
4. Copy GitHub auth and Claude auth from host
5. Set up git credential helper
6. `yadm clone` (or pull if exists)
7. Decrypt secrets (interactive GPG — the only manual step)
8. Re-setup credential helper (yadm checkout may overwrite .gitconfig)
9. `YADM_INSTALL=1 yadm bootstrap`
10. Run test suite (`~/.config/yadm/test-dotfiles.sh`)

## apt-cacher-ng

The host runs apt-cacher-ng as a local package cache. VMs are configured to use it via the incus bridge IP. This means:
- First VM build downloads packages from the internet (~15-20 min for cinnamon)
- Every subsequent rebuild pulls from local cache (seconds)
- The cache can be pre-warmed by running a throwaway VM with `apt-get install --download-only`

## Testing

After `create-dev-vm`:
- Smoke test runs automatically (VM exists, running, has IP, SSH works)

After `provision.sh`:
- `ssh steve@<vm-name> '~/.config/yadm/test-dotfiles.sh'`

## Lessons Learned (Hard-Won)

These are non-obvious findings from debugging. Don't repeat these mistakes.

- **Virtiofs mount ordering matters.** Incus creates parent directories as root when adding disk devices. If virtiofs mounts target `/home/steve/dev`, then `/home/steve/` gets created as `root:root` before `useradd` runs, causing permission failures. Solution: add virtiofs devices in provision.sh (after user exists), not in create-dev-vm.
- **Two virtiofs devices can't be hot-added.** PCI slot conflict. Must stop VM, add both devices while stopped, then start. This is why provision.sh does the stop/start cycle.
- **`incus stop --force` is a power yank.** Unflushed writes are lost. Any files written before a force-stop may not persist. Use `--timeout 60` for clean ACPI shutdown.
- **`hostnamectl` / `timedatectl` need dbus.** The incus agent comes up before systemd is fully running. Use direct file operations (`/etc/hostname`, `/etc/localtime` symlink) instead.
- **`images:ubuntu/24.04` has no cloud-init.** The `/cloud` variant (`images:ubuntu/24.04/cloud`) does, but we don't use cloud-init anyway. Either image works with `incus exec`.
- **Incus containers fail on this host** (cgroup mount error). Use VMs only. For cache warming, use a throwaway VM not a container.
- **Portability**: never hardcode IPs, timezones, bridge names, or UIDs. Discover at runtime: bridge IP via `ip addr show incusbr0`, timezone from `/etc/timezone`, VM IP from `incus list`.
- **apt-cacher-ng** dramatically reduces debug cycle time. Pre-warm the cache with a throwaway VM before iterating on the real build. Plan is to integrate into yadm bootstrap so all machines get it.

## Don'ts

- Don't put VM management scripts in yadm — they belong here
- Don't use cloud-init — use `incus exec` for VM configuration
- Don't hardcode IPs — use DHCP with runtime discovery
- Don't install desktop/dev packages in create-dev-vm — that's yadm bootstrap's job
- Don't use `incus stop --force` during provisioning — use `--timeout 60` for clean shutdown
- Don't add virtiofs devices before user creation — they create mount points as root
- Don't use `sudo -i` on the host — use `sudo <cmd>` (PAM fingerprint issue)
- Don't pipe install scripts to `sh` — Ubuntu's sh is dash; use `bash`
