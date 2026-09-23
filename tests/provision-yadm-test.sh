#!/bin/bash
# Tests for how provision.sh runs yadm on a VM whose ~/.claude is already the
# host's virtiofs mount. Git on the VM must never write those shared files:
#   - fresh VM: skip-worktree must be set BEFORE `yadm checkout "$HOME"`,
#     or the checkout overwrites the host's live ~/.claude files.
#   - re-provision: no bare `yadm pull` (it refuses, or writes through, when a
#     shared file changed upstream); use the host's vm-sync-check.sh --now.
# The behavioral cases run the real yadm against a throwaway HOME; no VM or real
# yadm repo is touched.
# Usage: ./tests/provision-yadm-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PROVISION="$SCRIPT_DIR/provision.sh"
FIRST_CLONE="$SCRIPT_DIR/guest/yadm-first-clone.sh"

PASS=0
FAIL=0
TMP=""

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

source "$SCRIPT_DIR/config.sh"

# A bare "origin" holding the 4 shared files and a .bashrc, and a VM-like HOME
# that already has the host's ~/.claude bytes and a skel .bashrc.
setup() {
    TMP="$(mktemp -d)"
    local seed="$TMP/seed"
    mkdir -p "$seed/.claude" "$TMP/home/.claude"
    for f in "${CLAUDE_SHARED_FILES[@]}"; do echo committed > "$seed/$f"; done
    echo "repo bashrc" > "$seed/.bashrc"
    git init -q -b master "$seed"
    git -C "$seed" add -A
    git -C "$seed" -c user.name=t -c user.email=t@t commit -qm init
    git clone -q --bare "$seed" "$TMP/origin.git"
    for f in "${CLAUDE_SHARED_FILES[@]}"; do echo "HOSTLIVE $f" > "$TMP/home/$f"; done
    touch -d '2001-01-01' "$TMP/home/.claude/"*
    echo "skel bashrc" > "$TMP/home/.bashrc"
}
teardown() { [[ -n "$TMP" ]] && rm -rf "$TMP"; TMP=""; }
sbx() { (cd "$TMP/home" && env -u XDG_CONFIG_HOME -u XDG_DATA_HOME HOME="$TMP/home" "$@"); }
host_bytes_intact() {
    local f
    for f in "${CLAUDE_SHARED_FILES[@]}"; do
        [[ "$(cat "$TMP/home/$f")" == "HOSTLIVE $f" ]] || return 1
        [[ "$(stat -c %Y "$TMP/home/$f")" == "$(date -d 2001-01-01 +%s)" ]] || return 1
    done
}

test_first_clone_keeps_host_bytes() {
    setup
    sbx bash "$FIRST_CLONE" "file://$TMP/origin.git" "${CLAUDE_SHARED_FILES[@]}" >"$TMP/out" 2>&1
    local rc=$?
    if [[ $rc -eq 0 ]]; then ok "first clone exits 0"; else bad "first clone exits 0 (rc=$rc: $(tail -2 "$TMP/out"))"; fi
    if host_bytes_intact; then ok "first clone leaves the host's ~/.claude bytes untouched"
    else bad "first clone overwrote the host's ~/.claude files"; fi
    if [[ "$(cat "$TMP/home/.bashrc")" == "repo bashrc" ]]; then ok "first clone still replaces skel files (.bashrc)"
    else bad "first clone left skel .bashrc in place"; fi
    local n
    n=$(sbx yadm ls-files -v -- "${CLAUDE_SHARED_FILES[@]}" | grep -c '^S')
    if [[ "$n" -eq ${#CLAUDE_SHARED_FILES[@]} ]]; then ok "all shared files are skip-worktree after first clone"
    else bad "only $n shared files are skip-worktree after first clone"; fi
    teardown
}

# Control: the old order (clone, checkout, THEN skip-worktree) really does
# overwrite the host's files. If this ever passes, the test above proves nothing.
test_old_order_overwrites_control() {
    setup
    sbx yadm clone -q "file://$TMP/origin.git" --no-bootstrap >/dev/null 2>&1
    sbx yadm checkout "$TMP/home" >/dev/null 2>&1
    if host_bytes_intact; then bad "control: old order should overwrite host bytes, but didn't"
    else ok "control: old order overwrites host bytes (the bug the ordering prevents)"; fi
    teardown
}

test_provision_no_bare_pull() {
    if grep -Eq '^[^#]*yadm pull' "$PROVISION"; then bad "provision.sh still runs a bare 'yadm pull'"
    else ok "provision.sh has no bare 'yadm pull'"; fi
}

test_provision_reprovision_uses_vmsync_now() {
    if grep -Eq "bash -s -- --now'? *< *\"\\\$HOST_VMSYNC_SCRIPT\"" "$PROVISION"; then
        ok "re-provision pipes the host's vm-sync-check.sh --now"
    else
        bad "re-provision doesn't pipe the host's vm-sync-check.sh --now"
    fi
}

test_provision_fresh_uses_first_clone() {
    if grep -q 'guest/yadm-first-clone.sh' "$PROVISION"; then ok "fresh provision uses guest/yadm-first-clone.sh"
    else bad "fresh provision doesn't use guest/yadm-first-clone.sh"; fi
    if grep -Eq '^[^#]*yadm checkout' "$PROVISION"; then bad "provision.sh still runs its own 'yadm checkout'"
    else ok "provision.sh leaves the checkout to the ordered helper"; fi
}

# Two lists must agree: this repo's CLAUDE_SHARED_FILES and the dotfiles'
# vm-sync-check.sh CLAUDE_FILES. Skipped when the host has no dotfiles copy.
test_shared_list_parity() {
    local vmsync="${HOST_VMSYNC_SCRIPT:-}"
    if [[ ! -f "$vmsync" ]]; then echo "  SKIP: no $vmsync on this host"; return; fi
    local theirs mine
    theirs=$(sed -n '/^CLAUDE_FILES=(/,/^)/p' "$vmsync" | grep -o '\.claude/[^ )]*' | sort)
    mine=$(printf '%s\n' "${CLAUDE_SHARED_FILES[@]}" | sort)
    if [[ "$theirs" == "$mine" ]]; then ok "CLAUDE_SHARED_FILES matches vm-sync-check.sh CLAUDE_FILES"
    else bad "CLAUDE_SHARED_FILES differs from vm-sync-check.sh CLAUDE_FILES"; fi
}

echo "=== provision yadm tests ==="
test_first_clone_keeps_host_bytes
test_old_order_overwrites_control
test_provision_no_bare_pull
test_provision_reprovision_uses_vmsync_now
test_provision_fresh_uses_first_clone
test_shared_list_parity

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
