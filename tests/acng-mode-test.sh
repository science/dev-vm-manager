#!/bin/bash
# Unit tests for acng-mode.
# Tests are sandboxed: a fake systemctl and a tmp apt-conf path are injected
# via env vars, so the real apt-cacher-ng service on the host is never touched.
# Usage: ./tests/acng-mode-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ACNG="$SCRIPT_DIR/acng-mode"

PASS=0
FAIL=0
TMP=""

setup() {
    TMP="$(mktemp -d)"
    export ACNG_APT_CONF_PATH="$TMP/01acng"
    export ACNG_SUDO=""
    export ACNG_SYSTEMCTL_CMD="$TMP/fake-systemctl"
    export ACNG_PROXY_URL=""   # disable curl health-check in tests
    export SYSTEMCTL_STATE_FILE="$TMP/svc-state"

    cat > "$ACNG_SYSTEMCTL_CMD" <<'EOF'
#!/bin/bash
case "$1" in
    start) echo active   > "$SYSTEMCTL_STATE_FILE" ;;
    stop)  echo inactive > "$SYSTEMCTL_STATE_FILE" ;;
    is-active)
        state="inactive"
        [[ -f "$SYSTEMCTL_STATE_FILE" ]] && state="$(cat "$SYSTEMCTL_STATE_FILE")"
        [[ "$state" == "active" ]]
        ;;
    *) echo "fake-systemctl: unsupported: $*" >&2; exit 99 ;;
esac
EOF
    chmod +x "$ACNG_SYSTEMCTL_CMD"
}

teardown() {
    rm -rf "$TMP"
}

ok() {
    printf "  PASS: %s\n" "$1"
    PASS=$((PASS + 1))
}

bad() {
    printf "  FAIL: %s\n" "$1"
    FAIL=$((FAIL + 1))
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$desc"
    else
        bad "$desc (expected $(printf %q "$expected"), got $(printf %q "$actual"))"
    fi
}

assert_true() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

assert_false() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

# ---- tests ----

test_acng_mode_exists_and_is_executable() {
    setup
    if [[ -x "$ACNG" ]]; then ok "acng-mode is executable"
    else bad "acng-mode is missing or not executable: $ACNG"; fi
    teardown
}

test_status_off_when_clean() {
    setup
    assert_eq "status: off when no conf and no service" "off" "$($ACNG status 2>&1)"
    teardown
}

test_on_writes_conf_and_starts_service() {
    setup
    $ACNG on >/dev/null
    assert_true  "on: writes apt conf"   test -f "$ACNG_APT_CONF_PATH"
    assert_true  "on: service is active" "$ACNG_SYSTEMCTL_CMD" is-active
    assert_eq    "status: on after on"   "on" "$($ACNG status 2>&1)"
    teardown
}

test_on_conf_content() {
    setup
    $ACNG on >/dev/null
    if grep -q 'Acquire::http::Proxy' "$ACNG_APT_CONF_PATH" \
        && grep -q '127.0.0.1:3142' "$ACNG_APT_CONF_PATH"; then
        ok "on: conf points apt at 127.0.0.1:3142"
    else
        bad "on: conf content unexpected: $(cat "$ACNG_APT_CONF_PATH")"
    fi
    teardown
}

test_off_removes_conf_and_stops_service() {
    setup
    $ACNG on  >/dev/null
    $ACNG off >/dev/null
    assert_false "off: apt conf removed"   test -e "$ACNG_APT_CONF_PATH"
    assert_false "off: service stopped"    "$ACNG_SYSTEMCTL_CMD" is-active
    assert_eq    "status: off after off"   "off" "$($ACNG status 2>&1)"
    teardown
}

test_on_is_idempotent() {
    setup
    $ACNG on >/dev/null
    $ACNG on >/dev/null
    assert_eq "status: on after two ons" "on" "$($ACNG status 2>&1)"
    teardown
}

test_off_is_idempotent() {
    setup
    $ACNG off >/dev/null
    $ACNG off >/dev/null
    assert_eq "status: off after two offs (clean state)" "off" "$($ACNG status 2>&1)"
    teardown
}

test_off_on_off_cycles() {
    setup
    $ACNG on  >/dev/null; assert_eq "cycle: on"        "on"  "$($ACNG status 2>&1)"
    $ACNG off >/dev/null; assert_eq "cycle: off"       "off" "$($ACNG status 2>&1)"
    $ACNG on  >/dev/null; assert_eq "cycle: on again"  "on"  "$($ACNG status 2>&1)"
    $ACNG off >/dev/null; assert_eq "cycle: off again" "off" "$($ACNG status 2>&1)"
    teardown
}

test_invalid_command_exits_nonzero() {
    setup
    if $ACNG bogus >/dev/null 2>&1; then
        bad "invalid command should exit non-zero"
    else
        ok "invalid command exits non-zero"
    fi
    teardown
}

test_no_args_exits_nonzero() {
    setup
    if $ACNG >/dev/null 2>&1; then
        bad "no-args should exit non-zero"
    else
        ok "no-args exits non-zero"
    fi
    teardown
}

# Inconsistent state: conf present but service stopped.
# Status should report inconsistent (non-zero exit). `on` should repair to on.
test_repair_from_partial_state() {
    setup
    : > "$ACNG_APT_CONF_PATH"   # only conf, no service
    if $ACNG status >/dev/null 2>&1; then
        bad "status: should fail on inconsistent state (conf only)"
    else
        ok "status: fails on inconsistent state (conf only)"
    fi
    $ACNG on >/dev/null
    assert_eq "on: repairs partial state to on" "on" "$($ACNG status 2>&1)"
    teardown
}

# The wrapping pattern used by create-dev-vm and provision.sh:
#   1. record state, turn on if off, set ACNG_OWNED=1
#   2. EXIT trap turns off iff ACNG_OWNED=1
# These tests run the pattern in a subshell against the sandboxed acng-mode.

run_wrap_pattern() {
    # Args: <exit-code-to-simulate>
    bash -c "
        set -euo pipefail
        ACNG='$ACNG'
        OWNED=0
        if [[ \"\$(\$ACNG status 2>/dev/null || true)\" != 'on' ]]; then
            \$ACNG on >/dev/null
            OWNED=1
        fi
        cleanup() { [[ \$OWNED -eq 1 ]] || return 0; \$ACNG off >/dev/null 2>&1 || true; }
        trap cleanup EXIT
        exit $1
    "
}

test_wrap_clean_exit_restores_off() {
    setup
    run_wrap_pattern 0
    assert_eq "wrap: clean exit restores off" "off" "$($ACNG status 2>&1)"
    teardown
}

test_wrap_failure_exit_restores_off() {
    setup
    run_wrap_pattern 1 || true
    assert_eq "wrap: failed exit still restores off (trap fired)" "off" "$($ACNG status 2>&1)"
    teardown
}

test_wrap_does_not_disturb_externally_on() {
    setup
    $ACNG on >/dev/null   # someone else turned it on first
    run_wrap_pattern 0
    assert_eq "wrap: leaves externally-owned acng on" "on" "$($ACNG status 2>&1)"
    teardown
}

test_wrap_does_not_disturb_externally_on_after_failure() {
    setup
    $ACNG on >/dev/null
    run_wrap_pattern 1 || true
    assert_eq "wrap: leaves externally-owned acng on even after failure" "on" "$($ACNG status 2>&1)"
    teardown
}

# ---- run all ----

echo "=== acng-mode tests ==="
test_acng_mode_exists_and_is_executable
test_status_off_when_clean
test_on_writes_conf_and_starts_service
test_on_conf_content
test_off_removes_conf_and_stops_service
test_on_is_idempotent
test_off_is_idempotent
test_off_on_off_cycles
test_invalid_command_exits_nonzero
test_no_args_exits_nonzero
test_repair_from_partial_state
test_wrap_clean_exit_restores_off
test_wrap_failure_exit_restores_off
test_wrap_does_not_disturb_externally_on
test_wrap_does_not_disturb_externally_on_after_failure

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
