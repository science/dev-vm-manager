#!/bin/bash
# Quick smoke test for a VM after creation (before provisioning).
# Verifies: VM exists, is running, has an IP, SSH works.
# Usage: ./tests/smoke-test.sh <vm-name>
set -euo pipefail

VM_NAME="${1:?Usage: smoke-test.sh <vm-name>}"
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

# Get IP from incus
VM_IP="$(incus list "$VM_NAME" --format csv -c 4 | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)" || true

echo "=== Smoke test: $VM_NAME (${VM_IP:-no IP}) ==="

# Incus checks
check "VM exists in incus" incus info "$VM_NAME"
check "VM is running" bash -c "incus list '$VM_NAME' --format csv -c s | grep -q RUNNING"
check "VM has an IP address" test -n "$VM_IP"
check "/etc/hosts has $VM_NAME" grep -q "$VM_NAME" /etc/hosts
[[ -n "$VM_IP" ]] && check "Host can ping $VM_IP" ping -c 1 -W 5 "$VM_IP"

# SSH checks
check "SSH connects" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$TARGET" true
check "Hostname is $VM_NAME" bash -c "ssh $TARGET hostname | grep -q $VM_NAME"
check "openssh-server installed" ssh "$TARGET" "dpkg -s openssh-server"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
