#!/bin/bash
# First yadm clone on a VM whose ~/.claude is already the host's virtiofs mount.
# Run on the VM by provision.sh:
#   ssh vm 'bash -s -- <repo-url> <shared-path>...' < guest/yadm-first-clone.sh
#
# Order matters. `yadm clone` leaves files that already exist alone, and the
# `yadm checkout "$HOME"` after it overwrites them with the committed versions --
# that is how skel defaults like .bashrc get replaced. The shared ~/.claude
# files also already exist, but they are the host's live bytes: overwriting
# them destroys the host's uncommitted edits. Marking them skip-worktree before
# the checkout makes it skip them. (tests/provision-yadm-test.sh)
set -euo pipefail

repo="${1:?usage: yadm-first-clone.sh <repo-url> <shared-path>...}"
shift
cd "$HOME"

yadm clone "$repo" --no-bootstrap
for f in "$@"; do
    [[ -n "$(yadm ls-files -- "$f")" ]] && yadm update-index --skip-worktree -- "$f"
done
yadm checkout "$HOME"
