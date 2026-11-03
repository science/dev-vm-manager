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

# Incus access. The VMs live in the restricted per-user project user-<uid>,
# served by the incus-user daemon to members of the `incus` group. That
# project can only attach paths under the user's home, never privileged
# containers or raw.qemu, so it is not a road to host root the way the
# incus-admin group is (see ~/.config/yadm/PLAN-passwordless-root.md).
# The restricted socket refuses the "default" project, so the project is
# always selected explicitly; the client does not pick it on its own.
INCUS_USER_PROJECT="user-$(id -u)"
export INCUS_PROJECT="${INCUS_PROJECT:-$INCUS_USER_PROJECT}"

# vm_project NAME: print the project NAME lives in. Transitional: while a VM
# is still in the default project (and the caller is still an Incus admin),
# find it there; otherwise the user project. Callers export INCUS_PROJECT
# from this before touching a VM.
vm_project() {
    local p
    for p in "$INCUS_USER_PROJECT" default; do
        if INCUS_PROJECT="$p" "${INCUS:-incus}" info "$1" &>/dev/null; then
            echo "$p"
            return 0
        fi
    done
    echo "$INCUS_USER_PROJECT"
}

# Inside a restricted project Incus runs virtiofsd (the server for the shared
# directories) as nobody, so the guest would see them nobody-owned and
# unwritable. This map, which the project permits for exactly our uid/gid,
# makes the guest see them as steve and keeps guest-root writes from ever
# becoming root-owned on the host.
VM_RAW_IDMAP="uid $(id -u) $(id -u)
gid $(id -g) $(id -g)"

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
