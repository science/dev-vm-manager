#!/bin/bash
# Unit tests for the spice-vdagent spin guard.
# Sandboxed: fake loginctl / pgrep / runuser are injected via SPICE_GUARD_*
# env hooks, so no real session, service or VM is touched. CPU measurement is
# tested against real processes (a busy loop vs a sleeper).
# Usage: ./tests/spice-vdagent-guard-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GUARD="$SCRIPT_DIR/guest/spice-vdagent-guard"
GUEST="$SCRIPT_DIR/guest"

PASS=0; FAIL=0; TMP=""; SPINNER=""; SLEEPER=""

setup() {
    TMP="$(mktemp -d)"
    export SPICE_GUARD_SAMPLE_SECS=1
    export SPICE_GUARD_LOGINCTL="$TMP/fake-loginctl"
    export SPICE_GUARD_PGREP="$TMP/fake-pgrep"
    export SPICE_GUARD_RUNUSER="$TMP/fake-runuser"
    export FAKE_SESSIONS="$TMP/sessions"       # "<sid> <user> <uid> <type> <active>"
    export FAKE_PIDS="$TMP/pids"               # one pid per line
    export RUNUSER_LOG="$TMP/runuser.log"
    : > "$FAKE_SESSIONS"; : > "$FAKE_PIDS"; : > "$RUNUSER_LOG"

    cat > "$SPICE_GUARD_LOGINCTL" <<'EOF'
#!/bin/bash
case "$1" in
  list-sessions) awk '{print $1, $3, $2}' "$FAKE_SESSIONS" ;;
  show-session)
    sid="$2"; prop=""
    for a in "$@"; do [[ "$a" == -p ]] && p=1 && continue; [[ "${p-}" == 1 ]] && prop="$a" && p=0; done
    while read -r s user uid typ active; do
      [[ "$s" == "$sid" ]] || continue
      case "$prop" in
        User) echo "$uid" ;; Name) echo "$user" ;;
        Type) echo "$typ" ;; Active) echo "$active" ;;
      esac
    done < "$FAKE_SESSIONS" ;;
  *) exit 1 ;;
esac
EOF
    cat > "$SPICE_GUARD_PGREP" <<'EOF'
#!/bin/bash
[[ -s "$FAKE_PIDS" ]] || exit 1
cat "$FAKE_PIDS"
EOF
    cat > "$SPICE_GUARD_RUNUSER" <<'EOF'
#!/bin/bash
echo "$*" >> "$RUNUSER_LOG"
EOF
    chmod +x "$SPICE_GUARD_LOGINCTL" "$SPICE_GUARD_PGREP" "$SPICE_GUARD_RUNUSER"
}

teardown() {
    [[ -n "$SPINNER" ]] && kill "$SPINNER" 2>/dev/null; SPINNER=""
    [[ -n "$SLEEPER" ]] && kill "$SLEEPER" 2>/dev/null; SLEEPER=""
    rm -rf "$TMP"
}

ok()  { printf "  PASS: %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  FAIL: %s\n" "$1"; FAIL=$((FAIL + 1)); }
assert_eq() { local d="$1" e="$2" a="$3"
    if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d (expected $(printf %q "$e"), got $(printf %q "$a"))"; fi; }
assert_true()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
assert_false() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

start_spinner() { bash -c 'while :; do :; done' & SPINNER=$!; }
start_sleeper() { sleep 300 & SLEEPER=$!; }

# ---- packaging ----

test_files_present_and_executable() {
    setup
    assert_true "guard script is executable" test -x "$GUARD"
    local f
    for f in spice-vdagent-guard.service spice-vdagent-guard-watchdog.service \
             spice-vdagent-guard-watchdog.timer spice-vdagentd.service.d/guard.conf; do
        assert_true "guest/$f exists" test -f "$GUEST/$f"
    done
    assert_true "install-spice-guard is executable" test -x "$SCRIPT_DIR/install-spice-guard"
    teardown
}

# The drop-in is the whole trigger mechanism: without Wants= on the daemon,
# nothing refreshes clients when a package upgrade restarts spice-vdagentd.
test_dropin_wires_daemon_to_guard() {
    setup
    if grep -q '^Wants=spice-vdagent-guard.service' "$GUEST/spice-vdagentd.service.d/guard.conf" \
       && grep -q '^\[Unit\]' "$GUEST/spice-vdagentd.service.d/guard.conf"; then
        ok "drop-in: daemon Wants= the guard unit"
    else
        bad "drop-in: missing [Unit] Wants=spice-vdagent-guard.service"
    fi
    if grep -q '^After=spice-vdagentd.service' "$GUEST/spice-vdagent-guard.service"; then
        ok "guard unit: ordered After the daemon"
    else
        bad "guard unit: missing After=spice-vdagentd.service"
    fi
    teardown
}

test_timer_is_installable_and_periodic() {
    setup
    assert_true "timer: has [Install] WantedBy" \
        grep -q '^WantedBy=timers.target' "$GUEST/spice-vdagent-guard-watchdog.timer"
    assert_true "timer: repeats on an interval" \
        grep -q '^OnUnitActiveSec=' "$GUEST/spice-vdagent-guard-watchdog.timer"
    teardown
}

test_units_point_at_installed_path() {
    setup
    local f
    for f in spice-vdagent-guard.service spice-vdagent-guard-watchdog.service; do
        assert_true "$f: ExecStart uses /usr/local/sbin/spice-vdagent-guard" \
            grep -q 'ExecStart=/usr/local/sbin/spice-vdagent-guard' "$GUEST/$f"
    done
    teardown
}

# ---- session selection ----

test_ignores_non_graphical_sessions() {
    setup
    echo "c1 steve 1000 tty yes" > "$FAKE_SESSIONS"
    start_sleeper; echo "$SLEEPER" > "$FAKE_PIDS"
    assert_eq "tty session is ignored" \
        "no spice-vdagent client running in an active graphical session" \
        "$($GUARD status 2>&1)"
    teardown
}

test_ignores_inactive_graphical_sessions() {
    setup
    echo "c1 steve 1000 x11 no" > "$FAKE_SESSIONS"
    start_sleeper; echo "$SLEEPER" > "$FAKE_PIDS"
    assert_eq "inactive x11 session is ignored" \
        "no spice-vdagent client running in an active graphical session" \
        "$($GUARD status 2>&1)"
    teardown
}

test_handles_no_sessions() {
    setup
    assert_true "restart: succeeds with no sessions" $GUARD restart
    assert_true "restart: says so" bash -c "$GUARD restart 2>&1 | grep -q 'nothing to restart'"
    teardown
}

# ---- spin detection ----

test_detects_a_spinning_client() {
    setup
    echo "c1 steve 1000 x11 yes" > "$FAKE_SESSIONS"
    start_spinner; echo "$SPINNER" > "$FAKE_PIDS"
    local out; out="$($GUARD status 2>&1)"
    if grep -q 'SPINNING' <<<"$out"; then ok "status: flags a busy-looping client"
    else bad "status: should flag spinner, got: $out"; fi
    assert_false "status: exits non-zero when spinning" $GUARD status
    teardown
}

test_idle_client_is_not_flagged() {
    setup
    echo "c1 steve 1000 x11 yes" > "$FAKE_SESSIONS"
    start_sleeper; echo "$SLEEPER" > "$FAKE_PIDS"
    local out; out="$($GUARD status 2>&1)"
    if grep -q ' ok$' <<<"$out"; then ok "status: idle client reported ok"
    else bad "status: idle client should be ok, got: $out"; fi
    assert_true "status: exits zero when idle" $GUARD status
    teardown
}

test_check_restarts_only_when_spinning() {
    setup
    echo "c1 steve 1000 x11 yes" > "$FAKE_SESSIONS"
    start_sleeper; echo "$SLEEPER" > "$FAKE_PIDS"
    $GUARD check >/dev/null 2>&1
    assert_eq "check: idle client is left alone" "" "$(cat "$RUNUSER_LOG")"

    start_spinner; echo "$SPINNER" > "$FAKE_PIDS"
    $GUARD check >/dev/null 2>&1
    if grep -q 'systemctl --user start spice-vdagent.service' "$RUNUSER_LOG"; then
        ok "check: spinning client is restarted via the user unit"
    else
        bad "check: expected a user-unit restart, log: $(cat "$RUNUSER_LOG")"
    fi
    teardown
}

# ---- restart behaviour ----

# Must go through the packaged user unit. A bare exec lands outside logind, so
# spice-vdagentd can't resolve the owner UID, rejects it, and the client
# reconnect-loops at ~90% CPU - the same symptom, a different cause.
test_restart_uses_user_unit_with_runtime_dir() {
    setup
    echo "c1 steve 1000 x11 yes" > "$FAKE_SESSIONS"
    $GUARD restart >/dev/null 2>&1
    local log; log="$(cat "$RUNUSER_LOG")"
    if grep -q 'XDG_RUNTIME_DIR=/run/user/1000' <<<"$log" \
       && grep -q 'systemctl --user start spice-vdagent.service' <<<"$log" \
       && grep -q '^-u steve' <<<"$log"; then
        ok "restart: runs the user unit as the session user with XDG_RUNTIME_DIR"
    else
        bad "restart: wrong invocation: $log"
    fi
    if grep -q '/usr/bin/spice-vdagent' <<<"$log"; then
        bad "restart: must not exec the binary directly (breaks logind UID resolution)"
    else
        ok "restart: never execs the client binary directly"
    fi
    teardown
}

# Autostart-launched clients aren't part of the user unit, so a plain
# `systemctl --user restart` would leave the stale one running alongside.
test_restart_kills_bare_client_first() {
    setup
    echo "c1 steve 1000 x11 yes" > "$FAKE_SESSIONS"
    start_sleeper; echo "$SLEEPER" > "$FAKE_PIDS"
    $GUARD restart >/dev/null 2>&1
    sleep 0.3
    if kill -0 "$SLEEPER" 2>/dev/null; then
        bad "restart: stale bare client survived"
    else
        ok "restart: kills the stale bare client before starting the unit"
    fi
    SLEEPER=""
    teardown
}

test_restart_handles_multiple_users_once_each() {
    setup
    printf 'c1 steve 1000 x11 yes\nc2 steve 1000 x11 yes\nc3 test 1001 x11 yes\n' > "$FAKE_SESSIONS"
    $GUARD restart >/dev/null 2>&1
    assert_eq "restart: one restart per uid, deduplicated" "2" "$(wc -l < "$RUNUSER_LOG")"
    teardown
}

test_bad_args_exit_nonzero() {
    setup
    assert_false "no args exits non-zero"        $GUARD
    assert_false "invalid command exits non-zero" $GUARD bogus
    teardown
}

echo "=== spice-vdagent-guard tests ==="
test_files_present_and_executable
test_dropin_wires_daemon_to_guard
test_timer_is_installable_and_periodic
test_units_point_at_installed_path
test_ignores_non_graphical_sessions
test_ignores_inactive_graphical_sessions
test_handles_no_sessions
test_detects_a_spinning_client
test_idle_client_is_not_flagged
test_check_restarts_only_when_spinning
test_restart_uses_user_unit_with_runtime_dir
test_restart_kills_bare_client_first
test_restart_handles_multiple_users_once_each
test_bad_args_exit_nonzero

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
