#!/bin/bash
# Quick smoke test for a VM after terraform apply (before provisioning).
# Verifies: VM exists, has the right IP, SSH works, cloud-init is done.
# Usage: ./tests/smoke-test.sh <vm-name> <expected-ip>
set -euo pipefail

VM_NAME="${1:?Usage: smoke-test.sh <vm-name> <expected-ip>}"
EXPECTED_IP="${2:?Usage: smoke-test.sh <vm-name> <expected-ip>}"
TARGET="steve@$VM_NAME"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

echo "=== Smoke test: $VM_NAME ($EXPECTED_IP) ==="

# Host-side checks
check "VM is defined in libvirt" sudo virsh dominfo "$VM_NAME"
check "VM is running" sudo virsh domstate "$VM_NAME" | grep -q running
check "/etc/hosts has $VM_NAME" grep -q "$VM_NAME" /etc/hosts
check "Host can ping $EXPECTED_IP" ping -c 1 -W 5 "$EXPECTED_IP"

# SSH checks
check "SSH connects" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$TARGET" true
check "Hostname is $VM_NAME" ssh "$TARGET" "hostname" | grep -q "$VM_NAME"
check "Static IP is $EXPECTED_IP" ssh "$TARGET" "ip addr show enp1s0" | grep -q "$EXPECTED_IP"
check "Cloud-init finished" ssh "$TARGET" "cloud-init status" | grep -q "done"
check "virtiofs dev mount in fstab" ssh "$TARGET" "grep -q devmount /etc/fstab"
check "virtiofs pictures mount in fstab" ssh "$TARGET" "grep -q picsmount /etc/fstab"
check "Cinnamon is installed" ssh "$TARGET" "dpkg -s cinnamon-desktop-environment"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
