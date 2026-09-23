#!/bin/bash
# Shared configuration for dev-vm-manager.
# Sourced by create-dev-vm, destroy-dev-vm, and other scripts.

# Known VM names
VM_NAMES=(dev-1 dev-2)

# VM resources
RAM="8GiB"
CPUS="4"
DISK="150GiB"

# Incus image
INCUS_IMAGE_REMOTE="images:ubuntu/24.04/cloud"
INCUS_IMAGE_ALIAS="dev-vm-ubuntu-2404"

# Apt cache proxy (apt-cacher-ng on host, reached via incus bridge).
# Build-time only: see vm-apt-proxy — a VM must never be left pointing at it.
APT_PROXY_PORT="3142"

# Incus bridge the VMs sit on; the host side of it is the apt proxy address.
BRIDGE_IFACE="${BRIDGE_IFACE:-incusbr0}"

# Host paths
SSH_PUBKEY_PATH="$HOME/.ssh/id_ed25519.pub"
HOST_DEV_DIR="$HOME/dev"
HOST_PICTURES_DIR="$HOME/Pictures"
HOST_CLAUDE_DIR="$HOME/.claude"

# The yadm-tracked files under the virtiofs-shared ~/.claude. On a VM they are
# the host's live bytes, so VM-side git must never write them. Must match
# CLAUDE_FILES in the dotfiles' vm-sync-check.sh (tests/provision-yadm-test.sh
# checks that).
CLAUDE_SHARED_FILES=(
    .claude/CLAUDE.md
    .claude/keybindings.json
    .claude/settings.json
    .claude/statusline.sh
)

# The host's copy of the dotfiles VM fast-forward script. provision.sh pipes it
# into the VM on re-provision, so a VM with an older copy still gets the
# current, shared-file-safe logic.
HOST_VMSYNC_SCRIPT="$HOME/.config/yadm/vm-sync-check.sh"
