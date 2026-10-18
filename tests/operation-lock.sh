#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
PIDS=()
cleanup_hook() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill -CONT "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

# shellcheck source=../scripts/lib/operation-lock.sh
. "$REPO_DIR/scripts/lib/operation-lock.sh"
. "$REPO_DIR/scripts/lib/service-process.sh"
. "$REPO_DIR/scripts/lib/service.sh"

LOCK_BASE="$WORK_DIR/runtime"
LOCK_PARENT="$LOCK_BASE/clashctl-operation-$EUID"
LOCK_DIR="$LOCK_PARENT/operation.lock.d"
mkdir -m 0700 -- "$LOCK_BASE"

# Keep tests away from the host runtime directory while retaining production validation.
_operation_lock_base() {
    _operation_lock_validate_base "$LOCK_BASE" "$1" || return 1
    printf '%s\n' "$LOCK_BASE"
}

assert_acquisition_fails() {
    local description=$1 stderr="$WORK_DIR/rejected.stderr" rc=0
    operation_lock_acquire 2>"$stderr" || rc=$?
    [ "$rc" -eq 1 ] || fail "$description: returned $rc instead of 1"
    [ -s "$stderr" ] || fail "$description: missing diagnostic"
}

test_private_modes_and_reentrancy() {
    local owner token
    (
        umask 000
        operation_lock_acquire || fail 'could not acquire operation lock'
        [ "$CLASHCTL_OPERATION_LOCK_DIR" = "$LOCK_DIR" ] || fail 'unexpected operation lock directory'
        [ "$CLASHCTL_OPERATION_LOCK_PID" = "$BASHPID" ] || fail 'lock owner is not the acquiring process'
        [ -n "$CLASHCTL_OPERATION_LOCK_TOKEN" ] || fail 'missing ownership token'
        [ "$(_operation_lock_stat %a "$LOCK_PARENT")" = 700 ] || fail 'lock parent is not private'
        [ "$(_operation_lock_stat %a "$LOCK_DIR")" = 700 ] || fail 'exclusive directory is not private'
        [ "$(_operation_lock_stat %a "$LOCK_DIR/owner")" = 600 ] || fail 'owner record is not private'
        read -r owner token <"$LOCK_DIR/owner"
        [[ $owner == "$BASHPID" && $token == "$CLASHCTL_OPERATION_LOCK_TOKEN" ]] ||
            fail 'owner record does not identify the holder'
        operation_lock_acquire || fail 'same-process reentrant acquisition failed'
        [ "$token" = "$CLASHCTL_OPERATION_LOCK_TOKEN" ] || fail 'reentrant acquisition replaced the token'
        operation_lock_release || fail 'could not release operation lock'
        [ ! -e "$LOCK_DIR" ] || fail 'released operation lock directory remains'
        operation_lock_release || fail 'release is not idempotent'
    )
}

test_exit_and_term_release() {
    local ready="$WORK_DIR/term.ready" holder rc=0
    (
        trap operation_lock_release EXIT
        operation_lock_acquire || exit 1
    ) || fail 'normal-exit holder failed'
    [ ! -e "$LOCK_DIR" ] || fail 'EXIT trap did not release lock'

    (
        trap operation_lock_release EXIT
        trap 'exit 143' TERM
        operation_lock_acquire || exit 1
        : >"$ready"
        while :; do sleep 0.01; done
    ) &
    holder=$!
    PIDS+=("$holder")
    wait_for_file "$ready" "$holder" 'TERM holder'
    kill -TERM "$holder"
    wait "$holder" || rc=$?
    [ "$rc" -eq 143 ] || fail "TERM holder returned $rc instead of 143"
    [ ! -e "$LOCK_DIR" ] || fail 'TERM trap did not release lock'
    operation_lock_acquire || fail 'lock cannot be acquired after TERM'
    operation_lock_release
}

test_signals_during_acquisition_release() {
    local signal expected rc marker interrupted_body="$WORK_DIR/interrupted-body-ran"
    for signal in HUP INT TERM; do
        case $signal in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
        marker="$WORK_DIR/acquire-$signal.sent"
        rc=0
        (
            trap operation_lock_release EXIT
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            local acquiring_pid=$BASHPID
            # shellcheck disable=SC2317  # Called indirectly during lock validation.
            _operation_lock_stat() {
                if [ "$2" = "$LOCK_DIR" ] && [ ! -e "$marker" ]; then
                    : >"$marker"
                    kill -s "$signal" "$acquiring_pid"
                fi
                _fixture_operation_lock_stat "$@"
            }
            operation_lock_acquire || exit 1
            : >"$interrupted_body"
        ) || rc=$?
        [ "$rc" -eq "$expected" ] || fail "$signal during acquisition returned $rc instead of $expected"
        [ -e "$marker" ] || fail "$signal acquisition fixture was not exercised"
        [ ! -e "$interrupted_body" ] || fail "$signal during acquisition still ran the operation"
        [ ! -e "$LOCK_DIR" ] || fail "$signal during acquisition retained the lock"
    done

    (
        local before handled=false acquiring_pid=$BASHPID marker="$WORK_DIR/custom-term.sent"
        trap ':' HUP
        trap '' INT
        trap 'handled=true' TERM
        before=$(trap -p HUP INT TERM)
        # shellcheck disable=SC2317  # Called indirectly during lock validation.
        _operation_lock_stat() {
            if [ "$2" = "$LOCK_DIR" ] && [ ! -e "$marker" ]; then
                : >"$marker"
                kill -TERM "$acquiring_pid"
            fi
            _fixture_operation_lock_stat "$@"
        }
        operation_lock_acquire || fail 'custom TERM handler prevented acquisition'
        [ "$handled" = true ] || fail 'deferred TERM did not reach the original handler'
        [ "$before" = "$(trap -p HUP INT TERM)" ] || fail 'acquisition changed caller signal traps'
        operation_lock_release
    )
}

# Retain the real formatter for deterministic signals sent while stat is running.
eval "$(declare -f _operation_lock_stat | sed '1s/_operation_lock_stat/_fixture_operation_lock_stat/')"

test_contention_and_sigkill_residue() {
    local ready="$WORK_DIR/holder.ready" stderr="$WORK_DIR/contention.stderr" holder rc=0
    (
        trap operation_lock_release EXIT
        operation_lock_acquire || exit 1
        : >"$ready"
        kill -STOP "$BASHPID"
    ) &
    holder=$!
    PIDS+=("$holder")
    wait_for_file "$ready" "$holder" 'operation lock holder'

    operation_lock_acquire 2>"$stderr" || rc=$?
    [ "$rc" -eq 1 ] || fail "contending acquisition returned $rc instead of 1"
    assert_contains "$stderr" '另一项 clashctl 安装、更新或卸载正在进行' 'contention diagnostic'

    kill -KILL "$holder"
    wait "$holder" 2>/dev/null || true
    [ -d "$LOCK_DIR" ] || fail 'SIGKILL unexpectedly removed the lock directory'
    rc=0
    operation_lock_acquire 2>"$stderr" || rc=$?
    [ "$rc" -eq 1 ] || fail 'SIGKILL residue was automatically reclaimed'
    assert_contains "$stderr" '残留' 'residual lock diagnostic'
    assert_contains "$stderr" "$LOCK_DIR" 'residual lock cleanup path'
    assert_contains "$stderr" '手动清理' 'residual lock recovery instructions'
    command rm -- "$LOCK_DIR/owner"
    rmdir -- "$LOCK_DIR"
    operation_lock_acquire || fail 'manual residual cleanup did not permit acquisition'
    operation_lock_release
}

test_empty_and_malformed_residue() {
    mkdir -m 0700 -- "$LOCK_DIR"
    assert_acquisition_fails 'empty lock directory'
    [ -d "$LOCK_DIR" ] || fail 'empty lock directory was removed automatically'
    (umask 077; printf 'invalid owner\n' >"$LOCK_DIR/owner")
    assert_acquisition_fails 'malformed owner record'
    [ -f "$LOCK_DIR/owner" ] || fail 'malformed owner record was removed automatically'
    command rm -- "$LOCK_DIR/owner"
    rmdir -- "$LOCK_DIR"
}

test_unsafe_paths_are_rejected() {
    local actual_base=$LOCK_BASE target="$WORK_DIR/symlink-target"
    chmod 0777 -- "$LOCK_BASE"
    assert_acquisition_fails 'writable runtime directory'
    assert_contains "$WORK_DIR/rejected.stderr" '安全的运行时目录' 'unsafe runtime directory diagnostic'
    chmod 0700 -- "$LOCK_BASE"
    if [ "$EUID" -eq 0 ]; then
        chown 65534 -- "$LOCK_BASE"
        assert_acquisition_fails 'runtime directory belonging to another user'
        chown 0 -- "$LOCK_BASE"
    fi

    mkdir -m 0700 -- "$target"
    ln -s -- "$target" "$WORK_DIR/runtime-link"
    LOCK_BASE="$WORK_DIR/runtime-link"
    assert_acquisition_fails 'symlink runtime directory'
    LOCK_BASE=$actual_base

    chmod 0770 -- "$LOCK_PARENT"
    assert_acquisition_fails 'writable lock parent'
    chmod 0700 -- "$LOCK_PARENT"
    if [ "$EUID" -eq 0 ]; then
        chown 65534 -- "$LOCK_PARENT"
        assert_acquisition_fails 'lock parent belonging to another user'
        chown 0 -- "$LOCK_PARENT"
    fi
    rmdir -- "$LOCK_PARENT"
    ln -s -- "$target" "$LOCK_PARENT"
    assert_acquisition_fails 'symlink lock parent'
    command rm -- "$LOCK_PARENT"
    mkdir -m 0700 -- "$LOCK_PARENT"

    ln -s -- "$target" "$LOCK_DIR"
    assert_acquisition_fails 'symlink exclusive directory'
    command rm -- "$LOCK_DIR"
    mkdir -m 0770 -- "$LOCK_DIR"
    assert_acquisition_fails 'writable exclusive directory'
    chmod 0700 -- "$LOCK_DIR"

    (umask 077; printf '%s fake-token\n' "$BASHPID" >"$target/owner")
    ln -s -- "$target/owner" "$LOCK_DIR/owner"
    assert_acquisition_fails 'symlink owner record'
    command rm -- "$LOCK_DIR/owner"
    cp -- "$target/owner" "$LOCK_DIR/owner"
    chmod 0666 -- "$LOCK_DIR/owner"
    assert_acquisition_fails 'writable owner record'
    chmod 0600 -- "$LOCK_DIR/owner"
    ln -- "$LOCK_DIR/owner" "$target/hardlinked-owner"
    assert_acquisition_fails 'hardlinked owner record'
    command rm -- "$target/hardlinked-owner"
    if [ "$EUID" -eq 0 ]; then
        chown 65534 -- "$LOCK_DIR/owner"
        assert_acquisition_fails 'owner record belonging to another user'
        chown 0 -- "$LOCK_DIR/owner"
        chown 65534 -- "$LOCK_DIR"
        assert_acquisition_fails 'exclusive directory belonging to another user'
        chown 0 -- "$LOCK_DIR"
    fi
    command rm -- "$LOCK_DIR/owner"
    rmdir -- "$LOCK_DIR"
}

test_inherited_release_and_reacquisition() {
    local token holder_pid ready="$WORK_DIR/child.ready" resume="$WORK_DIR/child.resume" child
    operation_lock_acquire || fail 'could not acquire parent lock'
    token=$CLASHCTL_OPERATION_LOCK_TOKEN
    holder_pid=$CLASHCTL_OPERATION_LOCK_PID
    (
        operation_lock_acquire || fail 'child could not reuse inherited lock'
        [ "$CLASHCTL_OPERATION_LOCK_PID" = "$holder_pid" ] || fail 'child replaced parent ownership'
        [ "$CLASHCTL_OPERATION_LOCK_TOKEN" = "$token" ] || fail 'child replaced parent token'
        operation_lock_release || fail 'child could not detach inherited lock'
        [ -z "${CLASHCTL_OPERATION_LOCK_DIR:-}" ] || fail 'child retained lock metadata after detach'
        [ -d "$LOCK_DIR" ] || fail 'child release removed parent lock'
        assert_acquisition_fails 'detached child while parent still holds lock'
    ) || fail 'inherited child release failed'
    [ -d "$LOCK_DIR" ] || fail 'parent lock disappeared after child exit'
    (
        operation_lock_release || fail 'background child could not detach inherited lock'
    ) &
    child=$!
    wait "$child" || fail 'background child release failed'
    [ -d "$LOCK_DIR" ] || fail 'background release removed parent lock'

    (
        trap operation_lock_release EXIT
        : >"$ready"
        while [ ! -e "$resume" ]; do sleep 0.01; done
        operation_lock_acquire || fail 'child could not acquire after parent release'
        [ "$CLASHCTL_OPERATION_LOCK_PID" = "$BASHPID" ] || fail 'child retained stale parent ownership'
        [ "$CLASHCTL_OPERATION_LOCK_TOKEN" != "$token" ] || fail 'child reused stale parent token'
    ) &
    child=$!
    PIDS+=("$child")
    wait_for_file "$ready" "$child" 'inherited child waiting for release'
    operation_lock_release || fail 'could not release parent lock'
    : >"$resume"
    wait "$child" || fail 'child reacquisition failed'
    [ ! -e "$LOCK_DIR" ] || fail 'child reacquisition leaked lock'
}

test_release_requires_original_token() {
    local pid token rc=0
    operation_lock_acquire || fail 'could not acquire lock for token test'
    pid=$CLASHCTL_OPERATION_LOCK_PID
    token=$CLASHCTL_OPERATION_LOCK_TOKEN
    printf '%s replacement-token\n' "$pid" >"$LOCK_DIR/owner"
    operation_lock_release || rc=$?
    [ "$rc" -eq 1 ] || fail 'release accepted a replaced ownership token'
    [ -f "$LOCK_DIR/owner" ] || fail 'release removed another owner record'
    printf '%s %s\n' "$pid" "$token" >"$LOCK_DIR/owner"
    operation_lock_release || fail 'could not release restored owner record'
}

test_contention_stress() {
    local ready="$WORK_DIR/stress.ready" violation="$WORK_DIR/stress.violation"
    local sentinel="$WORK_DIR/critical-section" count="$WORK_DIR/stress.count" child index
    local workers=() total=0
    : >"$count"
    for ((index = 0; index < 4; index++)); do
        (
            trap operation_lock_release EXIT
            while [ ! -e "$ready" ]; do sleep 0.01; done
            local attempt
            for attempt in {1..15}; do
                if operation_lock_acquire 2>/dev/null; then
                    if mkdir -- "$sentinel" 2>/dev/null; then
                        sleep 0.002
                        printf '.\n' >>"$count"
                        rmdir -- "$sentinel"
                    else
                        : >"$violation"
                    fi
                    operation_lock_release || exit 1
                fi
                sleep 0.002
            done
        ) &
        child=$!
        workers+=("$child")
        PIDS+=("$child")
    done
    : >"$ready"
    for child in "${workers[@]}"; do
        wait "$child" || fail 'contention stress worker failed'
    done
    [ ! -e "$violation" ] || fail 'multiple processes entered the critical section'
    while IFS= read -r _; do total=$((total + 1)); done <"$count"
    [ "$total" -gt 0 ] || fail 'no stress worker acquired the lock'
    [ ! -e "$LOCK_DIR" ] || fail 'contention stress leaked lock'
}

test_sysv_background_child_cannot_release_parent_lock() {
    _require_base_config() { return 0; }
    local CLASHCTL_KERNEL=mihomo BIN_KERNEL="$WORK_DIR/mihomo"
    local ready="$WORK_DIR/sysv-child.ready" child_pid=''

    # shellcheck disable=SC2034  # Read dynamically by service_start.
    service_manager=sysvinit
    service() {
        (
            operation_lock_release || exit 1
            printf '%s\n' "$BASHPID" >"$ready"
            kill -STOP "$BASHPID"
        ) &
    }
    operation_lock_acquire || fail 'could not acquire lock for SysV test'
    service_start || fail 'fake SysV service did not start'
    wait_until 300 test -s "$ready" || fail 'could not identify fake SysV background child'
    read -r child_pid <"$ready"
    PIDS+=("$child_pid")
    [ -d "$LOCK_DIR" ] || fail 'SysV background child released parent lock'
    operation_lock_release || fail 'could not release parent operation lock after SysV test'
}

test_update_holds_lifecycle_lock_for_dispatch() {
    local dispatch_file="$WORK_DIR/update-dispatched"
    . "$REPO_DIR/scripts/lib/shell.sh"
    . "$REPO_DIR/scripts/cmd/update.sh"
    _ui_error() { :; }
    local CLASHCTL_HOME="$WORK_DIR/update-home"
    mkdir -p "$CLASHCTL_HOME/.git"
    touch "$CLASHCTL_HOME/.env"
    cp "$REPO_DIR/install.sh" "$CLASHCTL_HOME/install.sh"
    printf '%s\ngit\n' "$CLASHCTL_HOME" >"$CLASHCTL_HOME/.clashctl-install"
    _ui_step() { :; }
    # shellcheck disable=SC2317  # Invoked indirectly by clashupdate.
    git() {
        local owner token
        [ -d "${CLASHCTL_OPERATION_LOCK_DIR:-}" ] || fail 'update dispatch started without lifecycle lock'
        read -r owner token <"$CLASHCTL_OPERATION_LOCK_DIR/owner"
        [[ $owner == "$CLASHCTL_OPERATION_LOCK_PID" && $token == "$CLASHCTL_OPERATION_LOCK_TOKEN" ]] ||
            fail 'update dispatch does not own lifecycle lock'
        touch "$dispatch_file"
        return 1
    }
    # shellcheck disable=SC2119  # 测试无参数入口
    if clashupdate; then fail 'update ignored Git failure'; fi
    unset -f git
    [ -f "$dispatch_file" ] || fail 'update dispatch did not run'
    [ -z "${CLASHCTL_OPERATION_LOCK_DIR:-}" ] || fail 'update retained lifecycle lock metadata'
    [ ! -e "$LOCK_DIR" ] || fail 'update retained lifecycle lock directory'
    operation_lock_acquire || fail 'update did not release lifecycle lock'
    operation_lock_release || fail 'could not release post-update test lock'
}

test_private_modes_and_reentrancy
test_exit_and_term_release
test_signals_during_acquisition_release
test_contention_and_sigkill_residue
test_empty_and_malformed_residue
test_unsafe_paths_are_rejected
test_inherited_release_and_reacquisition
test_release_requires_original_token
test_contention_stress
test_sysv_background_child_cannot_release_parent_lock
test_update_holds_lifecycle_lock_for_dispatch

printf 'operation-lock: ok\n'
