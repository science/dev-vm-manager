#!/bin/bash
# Install dependencies for dev-vm-manager
set -euo pipefail

echo "=== dev-vm-manager setup ==="

# 1. System packages (libvirt, qemu, cloud-image-utils)
PKGS=(
    qemu-kvm
    libvirt-daemon-system
    libvirt-clients
    virtinst
    cloud-image-utils
    genisoimage
)
MISSING=()
for pkg in "${PKGS[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING+=("$pkg")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Installing system packages: ${MISSING[*]}"
    sudo apt update
    sudo apt install -y "${MISSING[@]}"
else
    echo "System packages: OK"
fi

# 2. Terraform
if command -v terraform &>/dev/null; then
    echo "Terraform: $(terraform version -json | python3 -c 'import sys,json; print(json.load(sys.stdin)["terraform_version"])')"
else
    echo "Installing Terraform..."
    sudo apt update
    sudo apt install -y gnupg software-properties-common
    # HashiCorp GPG key
    wget -qO- https://apt.releases.hashicorp.com/gpg | \
        gpg --dearmor | \
        sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
    # HashiCorp apt repo
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
        https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt update
    sudo apt install -y terraform
    echo "Terraform: $(terraform version -json | python3 -c 'import sys,json; print(json.load(sys.stdin)["terraform_version"])')"
fi

# 3. Terraform libvirt provider (installed via terraform init)
echo ""
echo "Terraform provider will be installed on first 'terraform init'."

# 4. Verify libvirt is running
if systemctl is-active --quiet libvirtd; then
    echo "libvirtd: running"
else
    echo "Starting libvirtd..."
    sudo systemctl enable --now libvirtd
fi

# 5. Verify user is in libvirt group
if id -nG | grep -qw libvirt; then
    echo "User $(whoami): in libvirt group"
else
    echo "Adding $(whoami) to libvirt group (re-login required)..."
    sudo usermod -aG libvirt "$(whoami)"
    echo "WARNING: You need to log out and back in for group membership to take effect."
fi

# 6. Download Ubuntu cloud image (cached)
IMAGE_DIR="$HOME/.cache/cloud-images"
IMAGE_FILE="$IMAGE_DIR/noble-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
mkdir -p "$IMAGE_DIR"
if [[ -f "$IMAGE_FILE" ]]; then
    echo "Cloud image: cached at $IMAGE_FILE"
else
    echo "Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress -O "$IMAGE_FILE" "$IMAGE_URL"
fi

echo ""
echo "=== Setup complete ==="
echo "Next: cd $(pwd) && terraform init"
