#!/bin/bash
# Install dev-vm-manager scripts into ~/.local/bin via symlinks.
# Idempotent: skips if symlink already correct.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"

mkdir -p "$INSTALL_DIR"

scripts=(boot-vm shutdown-vm create-dev-vm destroy-dev-vm provision.sh vm-manager)

for script in "${scripts[@]}"; do
    src="$SCRIPT_DIR/$script"
    dst="$INSTALL_DIR/$script"
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
        continue
    fi
    ln -sf "$src" "$dst"
    echo "Linked $dst -> $src"
done

# Install icon
ICONS_DIR="$HOME/.local/share/icons"
mkdir -p "$ICONS_DIR"
src="$SCRIPT_DIR/vm-manager.svg"
dst="$ICONS_DIR/vm-manager.svg"
if ! [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    ln -sf "$src" "$dst"
    echo "Linked $dst -> $src"
fi

# Generate desktop entry with resolved paths
APPS_DIR="$HOME/.local/share/applications"
mkdir -p "$APPS_DIR"
dst="$APPS_DIR/vm-manager.desktop"
rm -f "$dst"
sed -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" -e "s|%ICONS_DIR%|$ICONS_DIR|g" \
    "$SCRIPT_DIR/vm-manager.desktop" > "$dst"
echo "Installed $dst"
