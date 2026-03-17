#!/bin/bash
# Install dev-vm-manager scripts into ~/.local/bin via symlinks.
# Idempotent: skips if symlink already correct.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"

mkdir -p "$INSTALL_DIR"

scripts=(boot-vm shutdown-vm create-dev-vm destroy-dev-vm provision.sh)

for script in "${scripts[@]}"; do
    src="$SCRIPT_DIR/$script"
    dst="$INSTALL_DIR/$script"
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
        continue
    fi
    ln -sf "$src" "$dst"
    echo "Linked $dst -> $src"
done
