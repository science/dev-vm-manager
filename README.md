# dev-vm-manager

Automated creation and provisioning of KVM/libvirt dev VMs using Terraform and cloud-init.

## Problem

Dev VMs need to be created from scratch, provisioned with a full Cinnamon desktop, and configured with yadm dotfiles — reproducibly, idempotently, and without manual steps beyond a single GPG passphrase prompt.

Previous attempts using bash/python scripts that shelled out to `virsh`, `virt-install`, and managed dnsmasq DHCP state directly were unreliable. libvirt's DHCP/dnsmasq layer has edge cases around stale leases, reservation timing, and network restarts that are painful to manage imperatively.

## Approach

- **Terraform** with the [`dmacvicar/libvirt`](https://github.com/dmacvicar/terraform-provider-libvirt) provider manages VM infrastructure declaratively: domains, volumes, cloud-init ISOs, network config. `terraform apply` creates, `terraform destroy` tears down cleanly.
- **Cloud-init** handles first-boot OS config: hostname, user, SSH key, static IP, desktop packages, autologin.
- **A post-provision script** handles yadm deployment: installing yadm/gh, copying auth credentials, cloning dotfiles, decrypting secrets (interactive GPG), running bootstrap, and verifying with the test suite.

## VMs

| Name | IP | Purpose |
|------|-----|---------|
| dev-1 | 192.168.122.101 | General dev VM |
| dev-2 | 192.168.122.102 | General dev VM |

Both are Ubuntu 24.04 (Noble) with Cinnamon desktop, 8 GiB RAM, 4 vCPUs, 40 GB disk, virtiofs mounts for `~/dev` and `~/Pictures`.

## Usage

```bash
# First time: install dependencies
./setup.sh

# Create a VM
terraform apply -var="vm_name=dev-1"

# Provision with yadm dotfiles (interactive: needs GPG passphrase)
./provision.sh dev-1

# Destroy a VM
terraform destroy -var="vm_name=dev-1"

# Destroy everything
terraform destroy
```

## Structure

```
.
├── README.md           # This file
├── CLAUDE.md           # AI assistant guidance
├── plan.md             # Goals, objectives, tasks
├── setup.sh            # Install terraform + libvirt provider
├── main.tf             # Terraform config for VM infrastructure
├── variables.tf        # Terraform variables
├── cloud-init/         # Cloud-init templates
│   ├── user-data.tpl
│   └── network-config.tpl
├── provision.sh        # Post-terraform yadm deployment
└── tests/              # Validation scripts
    └── smoke-test.sh   # Quick VM health check
```

## Dependencies

- Host: Ubuntu 24.04 with KVM/libvirt (`libvirtd`, `virsh`, `qemu-kvm`)
- Terraform >= 1.0 with `dmacvicar/libvirt` provider
- `cloud-image-utils` (for `cloud-localds`)
- SSH key at `~/.ssh/id_ed25519.pub`
- yadm dotfiles repo: `https://github.com/science/dotfiles.git`

## Relationship to yadm dotfiles

This project is **not** tracked by yadm. It lives in `~/dev/dev-vm-manager/` as its own git repo. The yadm dotfiles repo references it in bootstrap (for post-install steps on `linux-bambam`) but this project has no dependency on yadm to function.

The provisioning script (`provision.sh`) calls into the yadm dotfiles to deploy and test them on the new VM.
