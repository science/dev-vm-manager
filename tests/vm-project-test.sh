#!/bin/bash
# Sandboxed unit tests for config.sh's Incus project selection.
#
# NOT destructive: 'incus' is a shell function stub, so no daemon is touched.
# Covers vm_project (user project first, default as the transitional fallback,
# user project when the VM is nowhere), the exported INCUS_PROJECT default, the
# INCUS test hook, and the shape of VM_RAW_IDMAP.
#
# Usage: ./tests/vm-project-test.sh
set -u

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# run_case <projects-where-info-succeeds> -> echoes vm_project's answer.
# (vm_project silences the incus call, so the stub can only answer by exit code.)
run_case() {
    local where="$1"
    env -u INCUS_PROJECT bash -c '
        source "'"$REPO"'/config.sh"
        incus() {
            [[ "$1" == info ]] || return 1
            case " '"$where"' " in *" ${INCUS_PROJECT} "*) return 0;; esac
            return 1
        }
        vm_project some-vm
    '
}

uid=$(id -u)
echo "== vm_project: where does a VM live? =="
out="$(run_case "user-$uid")"
[[ "$out" == "user-$uid" ]] && ok "VM in the user project -> user project" || no "user-project case -> [$out]"
out="$(run_case "default")"
[[ "$out" == "default" ]] && ok "VM only in default (not yet moved) -> default" || no "default case -> [$out]"
out="$(run_case "")"
[[ "$out" == "user-$uid" ]] && ok "VM nowhere -> user project (where it would be created)" || no "nowhere case -> [$out]"

echo "== INCUS_PROJECT default and the INCUS hook =="
out="$(env -u INCUS_PROJECT bash -c 'source "'"$REPO"'/config.sh"; echo "$INCUS_PROJECT"')"
[[ "$out" == "user-$uid" ]] && ok "INCUS_PROJECT defaults to user-<uid>" || no "INCUS_PROJECT default -> [$out]"
out="$(INCUS_PROJECT=other bash -c 'source "'"$REPO"'/config.sh"; echo "$INCUS_PROJECT"')"
[[ "$out" == "other" ]] && ok "a preset INCUS_PROJECT is kept" || no "preset INCUS_PROJECT -> [$out]"
out="$(env -u INCUS_PROJECT bash -c 'source "'"$REPO"'/config.sh"; INCUS=fake-incus; fake-incus() { [[ "$INCUS_PROJECT" == default ]]; }; incus() { return 1; }; vm_project x')"
[[ "$out" == "default" ]] && ok "vm_project uses \$INCUS when a script sets the test hook" || no "INCUS hook -> [$out]"

echo "== VM_RAW_IDMAP =="
out="$(bash -c 'source "'"$REPO"'/config.sh"; printf "%s" "$VM_RAW_IDMAP"')"
[[ "$out" == "uid $uid $uid"$'\n'"gid $(id -g) $(id -g)" ]] && ok "VM_RAW_IDMAP maps exactly our uid and gid, one line each" || no "VM_RAW_IDMAP -> [$out]"

echo "== scripts select the project before touching a VM =="
for s in boot-vm shutdown-vm destroy-dev-vm provision.sh install-spice-guard vm-apt-proxy; do
    grep -q 'INCUS_PROJECT="$(vm_project' "$REPO/$s" && ok "$s resolves the VM's project" || no "$s does not call vm_project"
done
grep -q 'INCUS_PROJECT="$INCUS_USER_PROJECT"' "$REPO/create-dev-vm" && ok "create-dev-vm creates in the user project" || no "create-dev-vm project"
grep -q 'raw.idmap="$VM_RAW_IDMAP"' "$REPO/create-dev-vm" && ok "create-dev-vm sets raw.idmap" || no "create-dev-vm raw.idmap"
if grep -qE 'sg incus-admin|grep -q[wx]? incus-admin|usermod -aG incus-admin' "$REPO"/{vm-manager,boot-vm,shutdown-vm,create-dev-vm,destroy-dev-vm,setup.sh,provision.sh}; then
    no "no script requires the incus-admin group"
else
    ok "no script requires the incus-admin group"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
