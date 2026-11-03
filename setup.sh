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

# 3. Ensure user is in the incus group (NOT incus-admin: that group is root
#    on the host, see ~/.config/yadm/PLAN-passwordless-root.md). The
#    incus-user daemon gives each member a restricted project, user-<uid>,
#    that can only attach paths under the member's home.
if id -nG | tr ' ' '\n' | grep -qx incus; then
    echo "User $(whoami): in incus group"
else
    echo "Adding $(whoami) to incus group..."
    sudo gpasswd -a "$(whoami)" incus
    echo "NOTE: Log out and in for the group to take effect (scripts use 'sg incus' meanwhile)."
fi

# 4. Initialize incus if not already done (admin operation: sudo)
if sudo incus info &>/dev/null 2>&1; then
    echo "Incus: initialized"
else
    echo "Initializing Incus (minimal config)..."
    sudo incus admin init --minimal
fi

# 4b. Create the per-user project (first contact through the user socket does
#     it) and keep its VMs on the shared bridge instead of a per-user one, so
#     addresses and /etc/hosts entries stay as they were. Project edits need
#     an admin, hence sudo.
source "$(dirname "$0")/config.sh"
sg incus -c "incus project list" >/dev/null
if sudo incus project get "$INCUS_USER_PROJECT" restricted.networks.access | grep -qw "$BRIDGE_IFACE"; then
    echo "Project $INCUS_USER_PROJECT: may use $BRIDGE_IFACE"
else
    echo "Allowing $BRIDGE_IFACE in project $INCUS_USER_PROJECT..."
    user_bridge="$(sudo incus project get "$INCUS_USER_PROJECT" restricted.networks.access)"
    sudo incus project set "$INCUS_USER_PROJECT" restricted.networks.access="${BRIDGE_IFACE},${user_bridge}"
    sudo incus profile device set default eth0 network="$BRIDGE_IFACE" --project "$INCUS_USER_PROJECT"
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

# 6. Cache base VM image (in the user project: images are per project)
if sg incus -c "incus image list --format csv -c l" | grep -q "^${INCUS_IMAGE_ALIAS}$"; then
    echo "Base image: cached as $INCUS_IMAGE_ALIAS"
else
    echo "Downloading base VM image (one-time)..."
    sg incus -c "incus image copy $INCUS_IMAGE_REMOTE local: --alias $INCUS_IMAGE_ALIAS --vm --auto-update=false"
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
