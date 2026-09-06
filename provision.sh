#!/bin/bash
# Provision a VM with yadm dotfiles.
# Usage: ./provision.sh <vm-name>
#
# Prerequisites: VM must be running with SSH access (create-dev-vm).
# Interactive: GPG passphrase prompt for secrets decryption.
set -euo pipefail

VM_NAME="${1:?Usage: provision.sh <vm-name>}"
TARGET="steve@$VM_NAME"
REPO="https://github.com/science/dotfiles.git"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Provisioning $VM_NAME ==="

# --- acng (apt-cacher-ng) on-demand wrapping ---
# Same pattern as create-dev-vm. When create-dev-vm is the caller, acng will
# already be on and we leave it alone. When provision.sh is invoked directly,
# we flip it on for the duration and off again at exit.
ACNG_MODE_BIN="$SCRIPT_DIR/acng-mode"
ACNG_OWNED=0
if [[ -x "$ACNG_MODE_BIN" ]]; then
    if [[ "$("$ACNG_MODE_BIN" status 2>/dev/null || true)" != "on" ]]; then
        echo "Starting apt-cacher-ng for provisioning..."
        "$ACNG_MODE_BIN" on
        ACNG_OWNED=1
    fi
fi

# The VM-side proxy pointer is ALWAYS cleared (acng is build-time only; a VM
# left pointing at a stopped acng loses apt silently). The host service is only
# stopped if we started it — see the same note in create-dev-vm.
cleanup_acng() {
    "$SCRIPT_DIR/vm-apt-proxy" clear "$VM_NAME" 2>/dev/null || true
    [[ $ACNG_OWNED -eq 1 ]] || return 0
    "$ACNG_MODE_BIN" off >/dev/null 2>&1 || true
}
trap cleanup_acng EXIT

# --- Add shared directories (stop/start required for multiple virtiofs devices) ---
echo "Adding shared directories..."
incus stop "$VM_NAME" --timeout 60
incus config device add "$VM_NAME" devmount disk \
    source="$HOST_DEV_DIR" path=/home/steve/dev
incus config device add "$VM_NAME" picsmount disk \
    source="$HOST_PICTURES_DIR" path=/home/steve/Pictures
incus config device add "$VM_NAME" claudemount disk \
    source="$HOST_CLAUDE_DIR" path=/home/steve/.claude
incus start "$VM_NAME"
echo "Waiting for VM to come back..."
for i in $(seq 1 30); do
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$TARGET" true 2>/dev/null && break
    sleep 2
done

# --- Verify SSH ---
if ! ssh -o ConnectTimeout=10 "$TARGET" true 2>/dev/null; then
    echo "ERROR: SSH to $VM_NAME is not working after restart."
    exit 1
fi
echo "SSH is up."

# --- Ensure VM apt proxy config when host acng is on ---
# Idempotent: re-provisioning a VM that lost its 01proxy (e.g. after a previous
# on-demand cycle cleaned it up) gets it back so the next apt operation is fast.
# cleanup_acng removes it again on exit, always.
if [[ -x "$ACNG_MODE_BIN" ]] \
    && [[ "$("$ACNG_MODE_BIN" status 2>/dev/null || true)" == "on" ]]; then
    "$SCRIPT_DIR/vm-apt-proxy" set "$VM_NAME" >/dev/null || true
fi

# --- Install the spice-vdagent spin guard ---
# A spice-vdagent package upgrade restarts spice-vdagentd but leaves the
# session client on the deleted binary, spinning a full host core forever.
# The guard restarts clients whenever the daemon does. Non-fatal if it fails.
"$SCRIPT_DIR/install-spice-guard" "$VM_NAME" || \
    echo "WARNING: spice-vdagent guard install failed; continuing."

# --- Install yadm + gh ---
echo "Installing yadm and gh..."
ssh "$TARGET" 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq yadm gh'

# --- Copy auth credentials from host ---
echo "Copying auth credentials..."
ssh "$TARGET" 'mkdir -p ~/.config/gh'
scp -q ~/.config/gh/hosts.yml "$TARGET:~/.config/gh/hosts.yml"
scp -q ~/.claude.json "$TARGET:~/.claude.json"

# Verify GitHub auth
if ! ssh "$TARGET" 'gh auth status' 2>/dev/null; then
    echo "GitHub auth copy failed. Running gh auth login..."
    ssh -t "$TARGET" 'gh auth login'
fi

# --- Git credential helper (before clone) ---
ssh "$TARGET" '
    git config --global credential."https://github.com".helper ""
    git config --global credential."https://github.com".helper "!/usr/bin/gh auth git-credential"
'

# --- Clone or pull yadm dotfiles ---
echo "Cloning yadm dotfiles..."
ssh "$TARGET" "
    if [ -d ~/.local/share/yadm/repo.git ]; then
        echo 'yadm repo exists, pulling...'
        yadm pull
    else
        yadm clone $REPO --no-bootstrap
        yadm checkout \"\$HOME\" 2>/dev/null || true
    fi
"

# --- Mark virtiofs-shared .claude/* as skip-worktree ---
# ~/.claude/ is virtiofs-mounted from the host (see claudemount above), so the
# 4 yadm-tracked files under it are physically the host's bytes. Without this
# flag, every `yadm pull` on the VM diffs the live shared file against the VM's
# stale yadm HEAD and generates phantom conflicts. skip-worktree tells the VM's
# yadm to ignore those paths; the host stays the sole canonical tracker.
ssh "$TARGET" '
    yadm update-index --skip-worktree \
        .claude/CLAUDE.md \
        .claude/keybindings.json \
        .claude/settings.json \
        .claude/statusline.sh
'

# --- Decrypt secrets (interactive GPG passphrase) ---
echo ""
echo "=== GPG passphrase required (Bitwarden) ==="
echo "The passphrase prompt will wait indefinitely."
ssh -t "$TARGET" '
    if [ ! -f ~/.secrets ]; then
        mkdir -p ~/.gnupg
        echo "pinentry-timeout 0" >> ~/.gnupg/gpg-agent.conf
        gpgconf --kill gpg-agent 2>/dev/null || true
        gpg --decrypt ~/.local/share/yadm/archive | tar -xC ~/
    else
        echo "Secrets already decrypted."
    fi
'

# --- Re-setup credential helper (yadm checkout may overwrite .gitconfig) ---
ssh "$TARGET" '
    git config --global credential."https://github.com".helper ""
    git config --global credential."https://github.com".helper "!/usr/bin/gh auth git-credential"
'

# --- Bootstrap ---
echo ""
echo "=== Running yadm bootstrap ==="
ssh -t "$TARGET" 'YADM_INSTALL=1 yadm bootstrap'

# --- Reboot (picks up new systemd services like LightDM after package install) ---
echo ""
echo "Rebooting $VM_NAME..."
ssh "$TARGET" 'sudo reboot' || true
sleep 5
for i in $(seq 1 30); do
    ssh -o ConnectTimeout=5 "$TARGET" true 2>/dev/null && break
    sleep 2
done

# --- Verify ---
echo ""
echo "=== Running test suite ==="
ssh "$TARGET" '~/.config/yadm/test-dotfiles.sh'

echo ""
echo "=== $VM_NAME fully provisioned ==="
echo "  SSH:   ssh steve@$VM_NAME"
echo "  Console: incus console $VM_NAME --type vga"
