#!/bin/bash
# Unit tests for vm-apt-proxy and the write/clear symmetry in the build scripts.
# Sandboxed: a fake `incus` backed by a tmp dir stands in for a real VM, so no
# VM is ever touched.
# Usage: ./tests/vm-apt-proxy-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
VMP="$SCRIPT_DIR/vm-apt-proxy"

PASS=0
FAIL=0
TMP=""

# The fake incus models a VM as a directory. `exec <vm> -- ...` runs the command
# on the host with the VM's conf path redirected into that directory, which is
# enough to exercise set/clear/status. Reachability is faked by a marker file.
setup() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin" "$TMP/vms/dev-x"
    export VM_APT_PROXY_CONF_PATH="$TMP/vms/dev-x/01proxy"
    export VM_APT_PROXY_BRIDGE_IP="10.99.99.1"
    export VM_APT_PROXY_INCUS_CMD="$TMP/bin/fake-incus"
    export FAKE_VM_ROOT="$TMP/vms"
    export FAKE_PROXY_UP="$TMP/proxy-up"

    cat > "$VM_APT_PROXY_INCUS_CMD" <<'EOF'
#!/bin/bash
case "$1" in
    info) [[ -d "$FAKE_VM_ROOT/$2" ]] ;;
    exec)
        vm="$2"; shift 3          # drop: exec <vm> --
        [[ -d "$FAKE_VM_ROOT/$vm" ]] || exit 1
        # /dev/tcp probes stand in for proxy reachability
        if [[ "$*" == *"/dev/tcp/"* ]]; then
            [[ -f "$FAKE_PROXY_UP" ]]; exit $?
        fi
        "$@"
        ;;
    *) echo "fake-incus: unsupported: $*" >&2; exit 99 ;;
esac
EOF
    chmod +x "$VM_APT_PROXY_INCUS_CMD"
}

teardown() { rm -rf "$TMP"; }

ok()  { printf "  PASS: %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  FAIL: %s\n" "$1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$desc"
    else bad "$desc (expected $(printf %q "$expected"), got $(printf %q "$actual"))"; fi
}
assert_true()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
assert_false() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

# ---- vm-apt-proxy ----

test_executable() {
    setup
    assert_true "vm-apt-proxy is executable" test -x "$VMP"
    teardown
}

test_status_clear_when_unset() {
    setup
    assert_eq "status: clear when no conf" "clear" "$($VMP status dev-x 2>&1)"
    teardown
}

test_set_writes_conf() {
    setup
    $VMP set dev-x >/dev/null
    assert_true "set: writes conf" test -f "$VM_APT_PROXY_CONF_PATH"
    if grep -q 'Acquire::http::Proxy' "$VM_APT_PROXY_CONF_PATH" \
        && grep -q '10.99.99.1:3142' "$VM_APT_PROXY_CONF_PATH"; then
        ok "set: conf points at bridge IP and proxy port"
    else
        bad "set: conf content unexpected: $(cat "$VM_APT_PROXY_CONF_PATH")"
    fi
    teardown
}

test_set_echoes_url() {
    setup
    assert_eq "set: echoes the url" "http://10.99.99.1:3142" "$($VMP set dev-x)"
    teardown
}

test_clear_removes_conf() {
    setup
    $VMP set dev-x >/dev/null
    $VMP clear dev-x
    assert_false "clear: conf removed" test -e "$VM_APT_PROXY_CONF_PATH"
    assert_eq    "status: clear after clear" "clear" "$($VMP status dev-x 2>&1)"
    teardown
}

test_clear_is_idempotent() {
    setup
    $VMP clear dev-x; $VMP clear dev-x
    assert_eq "clear: idempotent on already-clear VM" "clear" "$($VMP status dev-x 2>&1)"
    teardown
}

test_clear_on_missing_vm_succeeds() {
    setup
    assert_true "clear: succeeds on nonexistent VM" $VMP clear no-such-vm
    teardown
}

test_status_reports_reachable() {
    setup
    touch "$FAKE_PROXY_UP"
    $VMP set dev-x >/dev/null
    assert_eq   "status: reports reachable" \
        "set http://10.99.99.1:3142 (reachable)" "$($VMP status dev-x 2>&1)"
    assert_true "status: exit 0 when reachable" $VMP status dev-x
    teardown
}

# The regression that starved dev-2: proxy still configured, service gone.
test_status_flags_unreachable_proxy() {
    setup
    $VMP set dev-x >/dev/null     # no FAKE_PROXY_UP -> service is down
    if $VMP status dev-x 2>&1 | grep -q 'UNREACHABLE'; then
        ok "status: flags a set-but-dead proxy"
    else
        bad "status: should flag set-but-dead proxy, got: $($VMP status dev-x 2>&1)"
    fi
    assert_false "status: exit non-zero when unreachable" $VMP status dev-x
    teardown
}

test_bad_args_exit_nonzero() {
    setup
    assert_false "no args exits non-zero"      $VMP
    assert_false "missing vm name exits non-zero" $VMP status
    assert_false "invalid command exits non-zero" $VMP bogus dev-x
    teardown
}

# ---- write/clear symmetry (the actual dev-2 bug) ----
#
# Both build scripts write the VM proxy whenever acng is reachable, but used to
# remove it only when they also OWNED the acng service. Running a build while
# acng was already on (the documented pre-warm workflow) therefore left the VM
# pointing at a proxy that later went away. The clear must not be gated on
# ownership.

run_build_pattern() {
    # Args: <acng-already-on: 0|1> <exit-code>
    local already_on="$1" code="$2"
    bash -c "
        set -uo pipefail
        VMP='$VMP'
        OWNED=0
        [[ $already_on -eq 1 ]] || OWNED=1     # we only own it if it was off
        cleanup() {
            \$VMP clear dev-x 2>/dev/null || true
            [[ \$OWNED -eq 1 ]] || return 0
        }
        trap cleanup EXIT
        \$VMP set dev-x >/dev/null
        exit $code
    "
}

test_symmetry_when_script_owns_acng() {
    setup
    run_build_pattern 0 0
    assert_eq "symmetry: cleared when script owned acng" "clear" "$($VMP status dev-x 2>&1)"
    teardown
}

test_symmetry_when_acng_externally_on() {
    setup
    run_build_pattern 1 0
    assert_eq "symmetry: cleared even when acng was externally on (dev-2 bug)" \
        "clear" "$($VMP status dev-x 2>&1)"
    teardown
}

test_symmetry_on_failed_build() {
    setup
    run_build_pattern 1 1
    assert_eq "symmetry: cleared when build fails mid-way" \
        "clear" "$($VMP status dev-x 2>&1)"
    teardown
}

# ---- guard against the gating regression returning ----

test_scripts_clear_unconditionally() {
    setup
    local f
    for f in create-dev-vm provision.sh; do
        # In cleanup_acng, the vm-apt-proxy clear must appear BEFORE the
        # ACNG_OWNED early-return, or the dev-2 bug is back.
        local body
        body="$(sed -n '/^cleanup_acng() {/,/^}/p' "$SCRIPT_DIR/$f")"
        local clear_line owned_line
        clear_line="$(grep -n 'vm-apt-proxy" clear' <<<"$body" | head -1 | cut -d: -f1)"
        owned_line="$(grep -n 'ACNG_OWNED -eq 1' <<<"$body" | head -1 | cut -d: -f1)"
        if [[ -n "$clear_line" && -n "$owned_line" && "$clear_line" -lt "$owned_line" ]]; then
            ok "$f: clears VM proxy before the ACNG_OWNED gate"
        else
            bad "$f: VM proxy clear is missing or gated behind ACNG_OWNED"
        fi
    done
    teardown
}

# ---- run all ----

echo "=== vm-apt-proxy tests ==="
test_executable
test_status_clear_when_unset
test_set_writes_conf
test_set_echoes_url
test_clear_removes_conf
test_clear_is_idempotent
test_clear_on_missing_vm_succeeds
test_status_reports_reachable
test_status_flags_unreachable_proxy
test_bad_args_exit_nonzero
test_symmetry_when_script_owns_acng
test_symmetry_when_acng_externally_on
test_symmetry_on_failed_build
test_scripts_clear_unconditionally

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
