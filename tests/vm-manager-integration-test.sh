#!/bin/bash
# DESTRUCTIVE integration test for vm-manager's stop / start / force-stop logic.
#
# This is NOT a sandboxed unit test (unlike acng-mode-test.sh). It drives the
# REAL incus and will repeatedly STOP, FORCE-STOP (power-cut), and RESTART a
# real VM (default: dev-2) — destroying anything running inside it. Other VMs
# are never touched.
#
# It is deliberately walled off from routine test runs:
#   * an interactive [y/N] confirmation that defaults to NO, and
#   * an auto-SKIP when run without a TTY (so a test harness can't trigger it).
# Run it only for full-coverage validation.
#
# Usage:
#   ./tests/vm-manager-integration-test.sh [vm-name]
#   VM_TEST_ASSUME_YES=1 ./tests/vm-manager-integration-test.sh   # skip the prompt
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

VM="${1:-dev-2}"

# --- target + access validation --------------------------------------------
found=false
for name in "${VM_NAMES[@]}"; do [[ "$name" == "$VM" ]] && found=true && break; done
if ! $found; then
    echo "ERROR: '$VM' is not a known VM (${VM_NAMES[*]})." >&2
    exit 2
fi
if ! incus info &>/dev/null; then
    echo "ERROR: cannot reach incus. Are you in the incus-admin group?" >&2
    exit 2
fi

# --- DESTRUCTIVE confirmation gate ------------------------------------------
cat <<WARN

  ============================================================
   *** DESTRUCTIVE TEST ***
  ============================================================
   This will repeatedly STOP, FORCE-STOP (power-cut), and
   RESTART the VM:   ${VM}

   Any running processes, terminals, or unsaved work inside
   ${VM} WILL BE LOST. Other dev VMs are not touched.
  ============================================================

WARN

if [[ "${VM_TEST_ASSUME_YES:-}" == "1" ]]; then
    echo "  VM_TEST_ASSUME_YES=1 set -- proceeding without prompt."
elif [[ -t 0 ]]; then
    printf "  Proceed and DESTROY state in %s? [y/N] " "$VM"
    read -r ans
    case "$ans" in
        y|Y) ;;
        *) echo "  Aborted."; exit 0 ;;
    esac
else
    echo "  Non-interactive (no TTY) and VM_TEST_ASSUME_YES not set -- SKIPPED." >&2
    exit 0
fi

# --- load the real vm-manager functions (main loop is guarded) --------------
# shellcheck source=/dev/null
source "$SCRIPT_DIR/vm-manager"
set +e               # relax: we assert on exit codes / state ourselves
draw()   { :; }      # stub: no screen clears
confirm(){ return 0; } # stub: auto-confirm the "Force shutdown?" prompt

PASS=0; FAIL=0
state()      { incus list "$VM" --format csv -c s 2>/dev/null; }
wait_agent() { local i; for i in $(seq 1 30); do incus exec "$VM" -- true 2>/dev/null && return 0; sleep 2; done; return 1; }

# check <description> <expected-state> <expected-substring-in-msg>
check() {
    local desc="$1" want="$2" want_msg="$3" got
    got="$(state)"
    if [[ "$got" == "$want" && "$msg" == *"$want_msg"* ]]; then
        echo "  PASS: $desc (state=$got, msg=\"$msg\")"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc -- wanted state=$want, msg~\"$want_msg\"; got state=$got, msg=\"$msg\""; FAIL=$((FAIL+1))
    fi
}

echo
echo "== precondition: ensure $VM is RUNNING =="
[[ "$(state)" == "RUNNING" ]] || incus start "$VM" >/dev/null 2>&1
wait_agent || { echo "  ERROR: $VM never became reachable"; exit 1; }
echo "  $VM is RUNNING"

echo "== stop_vm (graceful; auto-escalates to force on a 60s hang) =="
stop_vm "$VM";        check "stop reports real state" STOPPED "stopped"

echo "== start_vm (accurate post-start reporting) =="
start_vm "$VM";       check "start reports real state" RUNNING "started"
wait_agent || true

echo "== force_stop_vm (escalating force-stop path) =="
force_stop_vm "$VM";  check "force-stop stops the VM" STOPPED "force-stopped"

echo "== restore: leave $VM running =="
start_vm "$VM"; wait_agent || true
check "restored to RUNNING" RUNNING "started"

echo
echo "  ---------------------------------------------"
echo "  RESULTS: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
