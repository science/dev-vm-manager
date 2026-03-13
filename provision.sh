#!/bin/bash
# Provision a VM with yadm dotfiles after Terraform has created it.
# Usage: ./provision.sh <vm-name>
#
# Prerequisites: VM must be running with SSH access (terraform apply).
# Interactive: GPG passphrase prompt for secrets decryption.
set -euo pipefail

VM_NAME="${1:?Usage: provision.sh <vm-name>}"
TARGET="steve@$VM_NAME"
REPO="https://github.com/science/dotfiles.git"

echo "=== Provisioning $VM_NAME ==="

# --- Wait for SSH ---
echo "Waiting for SSH..."
for i in $(seq 1 90); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$TARGET" true 2>/dev/null; then
        break
    fi
    if (( i % 6 == 0 )); then
        echo "  Still waiting... ($((i * 10))s)"
    fi
    sleep 10
done

if ! ssh -o ConnectTimeout=5 "$TARGET" true 2>/dev/null; then
    echo "ERROR: SSH to $VM_NAME never came up after 15 minutes."
    echo "Try: virt-viewer $VM_NAME"
    echo "Try: ping $(grep "$VM_NAME" /etc/hosts | awk '{print $1}')"
    exit 1
fi
echo "SSH is up."

# --- Wait for cloud-init ---
echo "Waiting for cloud-init to finish..."
ssh "$TARGET" 'cloud-init status --wait'
echo "Cloud-init complete."

# --- Install yadm + gh ---
echo "Installing yadm and gh..."
ssh "$TARGET" 'command -v yadm >/dev/null || (sudo apt update && sudo apt install -y yadm)'
ssh "$TARGET" 'command -v gh >/dev/null || (sudo apt update && sudo apt install -y gh)'

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

# --- Verify ---
echo ""
echo "=== Running test suite ==="
ssh "$TARGET" '~/.config/yadm/test-dotfiles.sh'

echo ""
echo "=== $VM_NAME fully provisioned ==="
echo "  SSH:   ssh steve@$VM_NAME"
echo "  SPICE: virt-viewer $VM_NAME"
