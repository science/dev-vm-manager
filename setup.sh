#!/bin/bash
# Install dependencies for dev-vm-manager
set -euo pipefail

echo "=== dev-vm-manager setup ==="

# 1. Incus
if command -v incus &>/dev/null; then
    echo "Incus: $(incus version)"
else
    echo "Installing Incus..."
    sudo apt update
    sudo apt install -y incus
fi

# 2. Fix virtiofsd exec on virtiofs mounts
# Incus 6.0 hardcodes --cache=never for virtiofsd, which prevents mmap and
# breaks binary execution on virtiofs mounts (EFAULT). This wrapper swaps
# --cache=never for --cache=auto. Uses dpkg-divert so package updates install
# the real binary to virtiofsd.real, leaving the wrapper intact.
# Can be removed when Ubuntu ships Incus 7.0+ (which has io.cache per-device).
if dpkg-divert --list 2>/dev/null | grep -q '/usr/libexec/virtiofsd'; then
    echo "virtiofsd wrapper: already installed"
else
    echo "Installing virtiofsd exec wrapper..."
    sudo dpkg-divert --add --rename --divert /usr/libexec/virtiofsd.real /usr/libexec/virtiofsd
    sudo tee /usr/libexec/virtiofsd > /dev/null <<'WRAPPER'
#!/bin/bash
# Wrapper: Incus 6.0 hardcodes --cache=never which prevents mmap/exec on
# virtiofs mounts. Swap to --cache=auto for host-guest coherency with mmap.
args=()
for arg in "$@"; do
    if [[ "$arg" == "--cache=never" ]]; then
        args+=("--cache=auto")
    else
        args+=("$arg")
    fi
done
exec /usr/libexec/virtiofsd.real "${args[@]}"
WRAPPER
    sudo chmod +x /usr/libexec/virtiofsd
    echo "virtiofsd wrapper: installed"
fi

# 3. Ensure user is in incus-admin group
if id -nG | grep -qw incus-admin; then
    echo "User $(whoami): in incus-admin group"
else
    echo "Adding $(whoami) to incus-admin group..."
    sudo usermod -aG incus-admin "$(whoami)"
    echo "NOTE: Run 'newgrp incus-admin' or log out/in for group to take effect."
fi

# 4. Initialize incus if not already done
if sg incus-admin -c "incus info" &>/dev/null 2>&1; then
    echo "Incus: initialized"
else
    echo "Initializing Incus (minimal config)..."
    sg incus-admin -c "incus admin init --minimal"
fi

# 5. apt-cacher-ng (optional but recommended for fast VM rebuilds)
if dpkg -s apt-cacher-ng &>/dev/null 2>&1; then
    echo "apt-cacher-ng: installed"
    if systemctl is-active --quiet apt-cacher-ng; then
        echo "apt-cacher-ng: running"
    else
        echo "Starting apt-cacher-ng..."
        sudo systemctl enable --now apt-cacher-ng
    fi
else
    echo ""
    echo "apt-cacher-ng is not installed. It is recommended for fast VM rebuilds."
    echo "Install it with: sudo apt install apt-cacher-ng"
fi

# 6. Cache base VM image
source "$(dirname "$0")/config.sh"
if sg incus-admin -c "incus image list --format csv -c l" | grep -q "^${INCUS_IMAGE_ALIAS}$"; then
    echo "Base image: cached as $INCUS_IMAGE_ALIAS"
else
    echo "Downloading base VM image (one-time)..."
    sg incus-admin -c "incus image copy $INCUS_IMAGE_REMOTE local: --alias $INCUS_IMAGE_ALIAS --vm --auto-update=false"
fi

# 7. Verify SSH key exists
if [[ -f "$SSH_PUBKEY_PATH" ]]; then
    echo "SSH key: $SSH_PUBKEY_PATH"
else
    echo "WARNING: No SSH key found at $SSH_PUBKEY_PATH"
    echo "Generate one with: ssh-keygen -t ed25519"
fi

echo ""
echo "=== Setup complete ==="
echo "Next: ./create-dev-vm dev-1"
