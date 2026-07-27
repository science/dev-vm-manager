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
| Disk | 150 GB |
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

1. Stop VM, add virtiofs shared directories (~/dev, ~/Pictures, ~/.claude), restart
2. Wait for SSH
3. Install yadm + gh
4. Copy GitHub auth and Claude auth from host
5. Set up git credential helper
6. `yadm clone` (or pull if exists)
7. Mark the 4 yadm-tracked `.claude/*` files as `skip-worktree` (see below)
8. Decrypt secrets (interactive GPG — the only manual step)
9. Re-setup credential helper (yadm checkout may overwrite .gitconfig)
10. `YADM_INSTALL=1 yadm bootstrap`
11. Run test suite (`~/.config/yadm/test-dotfiles.sh`)

## apt-cacher-ng

apt-cacher-ng runs on **host machines only** as a local package cache server. VMs are **clients** — they do NOT run apt-cacher-ng themselves.

- **Host**: package installed but service **disabled by default**. `create-dev-vm` and `provision.sh` flip it on for the duration of a VM build via `acng-mode on/off` and revert on exit (EXIT trap). Listens on port 3142 only while on.
- **acng-mode**: `~/.local/bin/acng-mode {on|off|status}` is the toggle. `on` starts the service and writes `/etc/apt/apt.conf.d/01acng`; `off` removes the apt conf and stops the service. Idempotent. Tested at `tests/acng-mode-test.sh`.
- **Wrapping pattern**: each script records whether acng was already on; if it was off, the script turns it on, sets `ACNG_OWNED=1`, and the EXIT trap reverts. If acng was already on (someone else owns it, e.g. nested provision.sh inside create-dev-vm), the script leaves it alone. This makes nested invocations and external `acng-mode on` sessions safe.
- **VMs**: when host acng is on, `create-dev-vm` and `provision.sh` write `/etc/apt/apt.conf.d/01proxy` in the VM pointing at the bridge IP. The EXIT trap also removes that file from the VM if the script owned the acng cycle, so a VM whose host acng is off doesn't try to proxy through a dead service.
- **Cache warming**: first VM build downloads from internet (~15-20 min for cinnamon). Every subsequent VM rebuild or re-provision pulls from the host's cache (seconds). Pre-warm with a throwaway VM: `acng-mode on && apt-get install --download-only ... ; acng-mode off`.
- **Multi-machine**: each host machine runs its own apt-cacher-ng instance for its own VMs. Caches are local per host.
- **Why on-demand**: when always-on, acng's worker pool got stuck most days during `apt-daily.timer` and returned 503 to every subsequent apt operation until restarted. Bounded on-windows driven by VM rebuilds avoid that failure mode entirely. See `apt-cacher-ng-ondemand.md` for the full motivation.

## Testing

Unit tests (sandboxed, no real services touched):
- `tests/acng-mode-test.sh` — exercises `acng-mode` state machine and the EXIT-trap wrapping pattern. Uses a fake `systemctl` and a tmp `01acng` path injected via `ACNG_*` env hooks.

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
- **Virtiofs exec requires a virtiofsd cache fix.** Incus 6.0 hardcodes `--cache=never` for virtiofsd, which disables mmap and breaks binary execution (EFAULT/"Bad address"). Mount-level flags (`raw.mount.options=exec`, `security.noexec`) don't help — the problem is at the virtiofsd process level. Fixed via a `dpkg-divert` wrapper in `setup.sh` that swaps `--cache=never` for `--cache=auto`. Can be removed when Ubuntu ships Incus 7.0+ (which has `io.cache` per-device).
- **Root disks are sparse, so oversizing is cheap.** The `default` pool uses the `dir` driver, and Incus creates each VM's `root.img` sparse — a 150GiB nominal disk consumes only the blocks actually written (measure with `sudo du -sh` vs `du -sh --apparent-size` on `/var/lib/incus/storage-pools/default/virtual-machines/<vm>`). The tradeoff is overcommit: the pool lives on the host root filesystem, so all VMs filling up at once would wedge the host. Keep total nominal size well under free host space.
- **Resizing an existing VM's disk**: stop the VM (`./shutdown-vm <vm>`), then `incus config device set <vm> root size=<N>GiB`, then start it. The cloud image's cloud-init runs `growpart` + `resize2fs` during boot, so the partition and filesystem grow on their own — but it finishes *after* the agent and SSH come up, so an immediate `df` can still show the old size. Wait and re-check before concluding it didn't work. If it genuinely didn't grow: `growpart /dev/sda 2 && resize2fs /dev/sda2` in the guest.
- **Portability**: never hardcode IPs, timezones, bridge names, or UIDs. Discover at runtime: bridge IP via `ip addr show incusbr0`, timezone from `/etc/timezone`, VM IP from `incus list`.
- **apt-cacher-ng** dramatically reduces debug cycle time. Pre-warm the cache with a throwaway VM before iterating on the real build. Runs on host only — VMs are clients configured by `create-dev-vm`. Do NOT install apt-cacher-ng on VMs.
- **virtiofs + yadm double-tracking causes phantom conflicts.** `~/.claude/` is virtiofs-shared from the host into every VM, so the 4 yadm-tracked files inside it (`CLAUDE.md`, `keybindings.json`, `settings.json`, `statusline.sh`) physically *are* the host's bytes. Each VM's yadm has an independent HEAD commit, so a routine `yadm pull` on a VM diffs the live shared file against its stale HEAD and flags fake conflicts (which then write conflict markers into the host's file via virtiofs — making the mess worse). Fix: `yadm update-index --skip-worktree` on those 4 paths on every VM. The host stays the sole canonical tracker; VMs ignore those paths and rely on virtiofs for content. provision.sh sets this automatically after `yadm clone/pull`. Same trap will apply to any future file added to yadm under a virtiofs-shared path — extend the skip-worktree list if so.

## Don'ts

- **Don't stop or restart running VMs without explicit user permission.** If you didn't start it, assume the user is actively working in it. Always ask first.
- Don't put VM management scripts in yadm — they belong here
- Don't use cloud-init — use `incus exec` for VM configuration
- Don't hardcode IPs — use DHCP with runtime discovery
- Don't install desktop/dev packages in create-dev-vm — that's yadm bootstrap's job
- Don't use `incus stop --force` during provisioning — use `--timeout 60` for clean shutdown
- Don't add virtiofs devices before user creation — they create mount points as root
- Don't use `sudo -i` on the host — use `sudo <cmd>` (PAM fingerprint issue)
- Don't pipe install scripts to `sh` — Ubuntu's sh is dash; use `bash`
