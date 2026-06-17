#!/bin/bash
# Sandboxed unit tests for vm-manager's key->VM dispatch and draw() scoping.
#
# NOT destructive and NOT gated: 'incus' and 'get_status' are stubbed, and the
# action scripts (shutdown-vm, boot-vm) are faked to log their args, so NO real
# VM is ever touched and no incus access is required. Safe to run in any routine
# test pass.
#
# This exercises the REAL draw() via main_loop -- which is what catches the
# dynamic-scope bug where draw()'s 'for vm' loop clobbers the caller's target VM.
# (Tests that stub draw() with ':' miss that class of bug entirely.)
#
# Usage: ./tests/vm-manager-dispatch-test.sh
set -u

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
VMM="$REPO/vm-manager"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# run_keys <keys> <dev-1-state> <dev-2-state>  -> echoes the action-script log.
# Drives the real main_loop with piped keystrokes; fakes shutdown-vm/boot-vm.
run_keys() {
    local keys="$1" s1="$2" s2="$3" tmp
    tmp="$(mktemp -d)"
    printf '#!/bin/bash\necho "shutdown-vm $*" >> "%s/log"\nexit 0\n' "$tmp" > "$tmp/shutdown-vm"
    printf '#!/bin/bash\necho "boot-vm $*" >> "%s/log"\nexit 0\n'     "$tmp" > "$tmp/boot-vm"
    chmod +x "$tmp/shutdown-vm" "$tmp/boot-vm"
    : > "$tmp/log"
    printf '%s' "$keys" | bash -c '
        incus() { :; }                 # neutralize the source-time incus-admin check
        source "'"$VMM"'"
        SCRIPT_DIR="'"$tmp"'"
        VM_NAMES=(dev-1 dev-2)
        get_status() { case "$1" in dev-1) echo "'"$s1"'";; dev-2) echo "'"$s2"'";; *) echo UNKNOWN;; esac; }
        confirm() { return 0; }         # auto-confirm "Stop <vm>?"
        attach_console() { echo "attach $1" >> "'"$tmp"'/log"; }
        main_loop
    ' >/dev/null 2>&1
    cat "$tmp/log"
    rm -rf "$tmp"
}

echo "== dispatch: each key targets the correct VM (drives REAL draw) =="
out="$(run_keys '1' RUNNING STOPPED)"
[[ "$out" == "shutdown-vm dev-1" ]] && ok "key 1 stops dev-1"            || no "key 1 -> [$out]"
out="$(run_keys '3' RUNNING RUNNING)"
[[ "$out" == "shutdown-vm dev-2" ]] && ok "key 3 stops dev-2"            || no "key 3 -> [$out]"
out="$(run_keys '1' STOPPED STOPPED)"
[[ "$out" == "boot-vm dev-1" ]]     && ok "key 1 starts dev-1 (stopped)" || no "key 1 start -> [$out]"
out="$(run_keys '3' RUNNING STOPPED)"
[[ "$out" == "boot-vm dev-2" ]]     && ok "key 3 starts dev-2 (stopped)" || no "key 3 start -> [$out]"
out="$(run_keys '2' RUNNING STOPPED)"
[[ "$out" == "attach dev-1" ]]      && ok "key 2 attaches dev-1"         || no "key 2 -> [$out]"

echo "== regression: draw() must not clobber the caller's \$vm (dynamic scope) =="
res="$(bash -c '
    incus() { :; }
    source "'"$VMM"'"
    VM_NAMES=(dev-1 dev-2)
    get_status() { echo RUNNING; }
    vm=SENTINEL
    draw >/dev/null 2>&1
    printf "%s" "$vm"
')"
[[ "$res" == "SENTINEL" ]] && ok "draw() preserves caller \$vm" || no "draw() clobbered \$vm to [$res]"

echo
echo "  RESULTS: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
