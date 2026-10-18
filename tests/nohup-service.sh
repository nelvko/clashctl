#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
PIDS=()
cleanup_hook() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

assert_alive() {
    kill -0 "$1" 2>/dev/null || fail "$2"
}

assert_dead() {
    if kill -0 "$1" 2>/dev/null; then
        fail "$2"
    fi
}

CLASHCTL_HOME="$WORK_DIR/owned"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/service-process.sh
. "$REPO_DIR/scripts/lib/service-process.sh"
# shellcheck source=../scripts/lib/operation-lock.sh
. "$REPO_DIR/scripts/lib/operation-lock.sh"
# shellcheck source=../scripts/lib/service.sh
. "$REPO_DIR/scripts/lib/service.sh"

mkdir -p -- "$WORK_DIR/owned/bin" "$WORK_DIR/other/bin" "$WORK_DIR/owned/data"
cp -- "$(command -v sleep)" "$WORK_DIR/owned/bin/mihomo"
cp -- "$(command -v sleep)" "$WORK_DIR/other/bin/mihomo"
chmod 0700 "$WORK_DIR/owned/bin/mihomo" "$WORK_DIR/other/bin/mihomo"

CLASHCTL_KERNEL=mihomo
CLASH_DATA_DIR="$WORK_DIR/owned/data"
CLASH_RESOURCES_DIR="$WORK_DIR/owned/resources"
CLASH_CONFIG_RUNTIME="$WORK_DIR/owned/data/runtime.yaml"
BIN_KERNEL="$WORK_DIR/owned/bin/mihomo"
INIT_TYPE='nohup'
service_manager=
service_pid_path=
export CLASHCTL_KERNEL CLASH_DATA_DIR CLASH_RESOURCES_DIR CLASH_CONFIG_RUNTIME BIN_KERNEL INIT_TYPE
export service_manager
_is_root() { return 0; }
detect_service_manager

test_exact_record_and_atomic_binary_replacement() {
    local owned_pid same_binary_pid other_binary_pid expected_argv
    "$BIN_KERNEL" 30 &
    owned_pid=$!
    PIDS+=("$owned_pid")
    "$BIN_KERNEL" 30 &
    same_binary_pid=$!
    PIDS+=("$same_binary_pid")
    "$WORK_DIR/other/bin/mihomo" 30 &
    other_binary_pid=$!
    PIDS+=("$other_binary_pid")

    _service_process_record_create \
        "$service_pid_path" "$owned_pid" "$BIN_KERNEL" "$BIN_KERNEL" 30 ||
        fail 'could not create the exact nohup process record'
    _service_process_record_load "$service_pid_path" || fail 'valid process record was rejected'
    [ "$(stat -c %a -- "$service_pid_path")" = 600 ] || fail 'nohup process record mode is not 0600'
    expected_argv=$(_service_process_values_argv_hex "$BIN_KERNEL" 30)
    [ "$_SERVICE_RECORD_PID" = "$owned_pid" ] || fail 'record did not retain the exact PID'
    [ "$_SERVICE_RECORD_ARGV" = "$expected_argv" ] || fail 'record did not retain the complete argv'
    case $_SERVICE_RECORD_STARTTIME in '' | *[!0-9]*) fail 'recorded starttime is invalid' ;; esac

    cp -- "$(command -v sleep)" "$BIN_KERNEL.new"
    chmod 0700 "$BIN_KERNEL.new"
    /bin/mv -f -- "$BIN_KERNEL.new" "$BIN_KERNEL"
    case $(readlink -- "/proc/${owned_pid}/exe") in
    *' (deleted)') ;;
    *) fail 'test setup did not produce an atomically replaced executable' ;;
    esac

    service_stop
    wait "$owned_pid" 2>/dev/null || true
    assert_dead "$owned_pid" 'nohup stop left the recorded process running after binary replacement'
    assert_alive "$same_binary_pid" 'nohup stop killed a second instance of the same binary'
    assert_alive "$other_binary_pid" 'nohup stop killed an unrelated same-name process'
    [ ! -e "$service_pid_path" ] || fail 'nohup stop retained its process record'

    printf '%s\n' "$same_binary_pid" >"$service_pid_path"
    service_stop
    assert_alive "$same_binary_pid" 'a malformed legacy PID file killed an unrecorded process'
    [ ! -e "$service_pid_path" ] || fail 'an invalid process record was not cleaned'
}

test_pid_identity_is_rechecked_before_term() {
    local signals_file="$WORK_DIR/term-signals"
    : >"$signals_file"
    # shellcheck disable=SC2030,SC2031,SC2317
    (
        _service_process_record_load() {
            _SERVICE_RECORD_PID=4242
            _SERVICE_RECORD_STARTTIME=1
            _SERVICE_RECORD_ARGV=00
            _SERVICE_RECORD_EXE_ID=1:1
        }
        local_matches=0
        _service_process_identity_matches() {
            local_matches=$((local_matches + 1))
            [ "$local_matches" -eq 1 ]
        }
        kill() { printf '%s\n' "$*" >>"$signals_file"; }
        _service_process_stop_recorded "$WORK_DIR/synthetic.record"
    )
    [ ! -s "$signals_file" ] || fail 'a reused PID received TERM after the pre-signal identity check failed'
}

test_pid_identity_is_rechecked_before_kill() {
    local record="$WORK_DIR/reuse.record"
    local signals_file="$WORK_DIR/kill-signals"
    : >"$signals_file"

    # shellcheck disable=SC2030,SC2031,SC2317
    (
        _service_process_record_load() {
            _SERVICE_RECORD_PID=4242
            _SERVICE_RECORD_STARTTIME=1
            _SERVICE_RECORD_ARGV=00
            _SERVICE_RECORD_EXE_ID=1:1
        }
        identity_checks=0
        _service_process_identity_matches() {
            identity_checks=$((identity_checks + 1))
            [ "$identity_checks" -lt 23 ]
        }
        kill() {
            case ${1:-} in
            -TERM) printf '%s\n' "$*" >>"$signals_file" ;;
            -KILL) printf '%s\n' "$*" >>"$signals_file" ;;
            -0) return 0 ;;
            esac
        }
        sleep() { :; }
        _service_process_stop_recorded "$record"
    )
    grep -Fqs -- '-TERM 4242' "$signals_file" || fail 'TERM was not sent to the original identity'
    if grep -Fqs -- '-KILL 4242' "$signals_file"; then
        fail 'a PID reused after TERM received KILL'
    fi
}

test_recorded_stop_failures() {
    (
        _service_process_record_load() {
            _SERVICE_RECORD_PID=4242
            _SERVICE_RECORD_STARTTIME=1
            _SERVICE_RECORD_ARGV=00
            _SERVICE_RECORD_EXE_ID=1:1
        }
        _service_process_identity_matches() { return 0; }
        sleep() { :; }
        signals=''
        kill_rc=1
        kill() { signals+=" $1"; return "$kill_rc"; }
        if _service_process_stop_recorded "$WORK_DIR/synthetic.record"; then
            fail 'a failed TERM was reported as stopped'
        fi
        [ "$signals" = ' -TERM' ] || fail 'failed TERM escalated to KILL'
        [ "$_SERVICE_PROCESS_RECORD_CAN_REMOVE" -eq 0 ] || fail 'failed TERM allowed record removal'

        signals=''
        kill_rc=0
        if _service_process_stop_recorded "$WORK_DIR/synthetic.record"; then
            fail 'a surviving process was reported as stopped'
        fi
        [ "$signals" = ' -TERM -KILL' ] || fail 'surviving process did not receive TERM then KILL'
        [ "$_SERVICE_PROCESS_RECORD_CAN_REMOVE" -eq 0 ] || fail 'surviving process allowed record removal'
    )
}

test_privileged_record_is_root_owned_and_authoritative() {
    local runtime_dir="$WORK_DIR/root-runtime" privileged_bin resources="$WORK_DIR/privileged.py"
    local config="$WORK_DIR/privileged.yaml"
    local record privileged_pid unrecorded_pid expected_argv local_pidfile="$WORK_DIR/user.pid"
    privileged_bin=$(command -v python3)
    printf 'import time\ntime.sleep(30)\n' >"$resources"
    expected_argv=$(_service_process_values_argv_hex "$privileged_bin" -d "$resources" -f "$config")
    _service_privileged_start_at \
        "$runtime_dir" 1000 mihomo "$privileged_bin" "$resources" "$config" \
        >/dev/null || fail 'privileged helper could not start its recorded process'
    record=$(_service_privileged_record_path "$runtime_dir" 1000 mihomo)
    [ "$(stat -c '%u:%g:%a' -- "$record")" = 0:0:600 ] ||
        fail 'privileged process record is not root-owned mode 0600'
    _service_process_record_load "$record" || fail 'privileged process record is invalid'
    # shellcheck disable=SC2031
    privileged_pid=$_SERVICE_RECORD_PID
    PIDS+=("$privileged_pid")

    "$privileged_bin" -d "$resources" -f "$config" >/dev/null &
    unrecorded_pid=$!
    PIDS+=("$unrecorded_pid")
    printf '%s\n' "$unrecorded_pid" >"$local_pidfile"

    chmod 0666 "$record"
    if _service_privileged_stop_at "$runtime_dir" 1000 mihomo "$expected_argv"; then
        fail 'privileged helper trusted an insecure root-side record'
    fi
    assert_alive "$privileged_pid" 'insecure privileged record caused its process to be signalled'
    chmod 0600 "$record"

    if _service_privileged_stop_at "$runtime_dir" 1000 mihomo \
        "$(_service_process_values_argv_hex "$WORK_DIR/another-install/mihomo" 30)"; then
        fail 'privileged helper accepted another installation command'
    fi
    assert_alive "$privileged_pid" 'uninstalling another installation stopped privileged process'
    [ -f "$record" ] || fail 'foreign privileged record was removed'

    _service_privileged_stop_at "$runtime_dir" 1000 mihomo "$expected_argv" ||
        fail 'privileged helper could not stop its securely recorded process'
    wait "$privileged_pid" 2>/dev/null || true
    assert_dead "$privileged_pid" 'privileged helper left its recorded process running'
    assert_alive "$unrecorded_pid" 'forged user PID data killed an unrecorded privileged process'
    [ ! -e "$record" ] || fail 'privileged helper retained its root-side process record'
}

test_stale_process_lock_is_recovered() {
    local record="$WORK_DIR/stale-record" lock acquired
    lock="${record}.lock"
    mkdir -m 0700 -- "$lock"
    printf '%s %s\n' 99999999 1 >"$lock/owner"
    _service_process_lock_acquire "$record" || fail 'stale process lock was not recovered'
    acquired=$_SERVICE_PROCESS_LOCK_PATH
    [ "$acquired" = "$lock" ] || fail 'recovered lock path is incorrect'
    _service_process_lock_release "$acquired" || fail 'recovered process lock was not released'
    [ ! -e "$lock" ] || fail 'released process lock directory remains'
}

test_exact_record_and_atomic_binary_replacement
test_pid_identity_is_rechecked_before_term
test_pid_identity_is_rechecked_before_kill
test_recorded_stop_failures
test_privileged_record_is_root_owned_and_authoritative
test_stale_process_lock_is_recovered

printf 'nohup-service: ok\n'
