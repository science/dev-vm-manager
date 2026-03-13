# Plan: dev-vm-manager

## Goals

1. **Reproducible VM creation** — `terraform apply` creates a fully working dev VM from nothing. No manual steps except GPG passphrase.
2. **Clean teardown** — `terraform destroy` removes everything. No stale DHCP leases, orphan volumes, ghost host keys.
3. **Idempotent provisioning** — running `provision.sh` on an already-provisioned VM is safe and fast.
4. **Tested** — smoke tests verify the VM is healthy before and after provisioning.

## Architecture Decisions

### Why Terraform over shell scripts
Shell scripts (bash, python) that call `virsh`/`virt-install` imperatively don't handle partial failures, stale state, or ordering dependencies well. We burned hours debugging DHCP lease races, network restart timing, and cleanup ordering. Terraform manages state declaratively and handles all of this.

### Why static IP via cloud-init (not DHCP reservations)
libvirt's dnsmasq DHCP has unreliable behavior around lease persistence, reservation timing, and network restarts. Static IP configured in cloud-init's `network-config` is deterministic — the VM knows its IP before it ever touches the network. Terraform's libvirt provider supports this natively via `cloudinit_disk`.

### Why separate provision.sh from Terraform
Terraform is good at infrastructure (VM, disk, network). It's bad at interactive prompts (GPG passphrase) and multi-step SSH provisioning. The split is:
- **Terraform**: VM exists, boots, has an IP, has SSH
- **provision.sh**: yadm clone, decrypt, bootstrap, test

### Why virtiofs for ~/dev and ~/Pictures
- `~/dev` is shared so AI agents inside VMs can edit code that's also accessible from the host
- `~/Pictures` is shared for screenshot workflows
- Only these two dirs — no host filesystem access beyond them (blast radius protection)

## Tasks

### Phase 1: Project Setup
- [x] Create ~/dev/dev-vm-manager with git
- [x] Write README.md, plan.md, CLAUDE.md
- [ ] Write setup.sh (install terraform + provider)
- [ ] Verify terraform + provider work on linux-bambam

### Phase 2: Terraform Config
- [ ] Write variables.tf (vm_name, vm_ip, ram, cpus, disk_size)
- [ ] Write main.tf (libvirt_volume, libvirt_cloudinit_disk, libvirt_domain)
- [ ] Write cloud-init/user-data.tpl
- [ ] Write cloud-init/network-config.tpl
- [ ] Test: `terraform plan` succeeds
- [ ] Test: `terraform apply` creates a VM that boots and gets the right IP
- [ ] Test: `terraform destroy` removes everything cleanly

### Phase 3: Provisioning Script
- [ ] Write provision.sh (yadm deploy: install yadm/gh, copy creds, clone, decrypt, bootstrap, test)
- [ ] Handle GPG pinentry timeout (set pinentry-timeout 0 before decrypt)
- [ ] Test: provision.sh on a fresh VM passes all yadm tests

### Phase 4: Cleanup
- [ ] Remove create-dev-vm.py from yadm
- [ ] Remove create-dev-vm.sh from yadm
- [ ] Update deploy-vm.sh to call provision.sh or remove it
- [ ] Update yadm bootstrap linux-bambam post-install to reference this project
- [ ] Update ~/CLAUDE.md and ~/README.md references

### Phase 5: Multi-VM
- [ ] Support creating both dev-1 and dev-2 (terraform workspaces or tfvars)
- [ ] Test: create dev-1, create dev-2, destroy dev-1, dev-2 still works
- [ ] Backup: qcow2 snapshot/copy script

## Known Issues from Previous Attempts
- libvirt dnsmasq DHCP leases persist across net-destroy/net-start and block IP assignment
- `virsh net-update --live --config` doesn't always take effect reliably
- UEFI VMs don't support internal snapshots (need external or qcow2 copy)
- GPG pinentry has a default timeout — must set `pinentry-timeout 0` before decrypt
- Ubuntu Noble cloud images need `openssh-server` explicitly in cloud-init packages
- `gateway4` is deprecated in netplan v2 — use `routes: [{to: default, via: ...}]`
- The cloud image NIC is `enp1s0` (virtio on PCI bus 1)
