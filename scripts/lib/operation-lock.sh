#!/usr/bin/env bash

# mkdir is the acquisition primitive. Callers release on EXIT, after any rollback,
# and translate HUP/INT/TERM into exits. SIGKILL/power loss deliberately leave a
# lock for manual inspection: deleting a supposedly stale lock races new owners.

_operation_lock_emit_error() {
    if declare -F _ui_error >/dev/null 2>&1; then
        _ui_error "$1"
    else
        printf '✗ ERROR %s\n' "$1" >&2
    fi
}

_operation_lock_emit_detail() {
    local label=$1
    shift
    if declare -F _ui_detail >/dev/null 2>&1; then
        _ui_detail "$label" "$*"
    else
        printf '        %s: %s\n' "$label" "$*" >&2
    fi
}

_operation_lock_stat() {
    stat -c "$1" -- "$2" 2>/dev/null
}

_operation_lock_validate_base() {
    local base=$1 expected_owner=$2 metadata mode
    [ -n "$base" ] && [ "$base" != / ] && [[ $base == /* ]] || return 1
    ! [[ $base =~ [[:cntrl:]] ]] || return 1
    [ -d "$base" ] && [ ! -L "$base" ] && [ -x "$base" ] && [ -w "$base" ] || return 1
    metadata=$(_operation_lock_stat '%u:%a' "$base") || return 1
    case $metadata in
    *[!0-9:]* | :* | *:) return 1 ;;
    esac
    mode=${metadata#*:}
    [ "${metadata%%:*}" -eq "$expected_owner" ] && [ $((8#$mode & 0022)) -eq 0 ]
}

_operation_lock_validate_tmp() {
    local base=${1:-/tmp} metadata mode
    [ -d "$base" ] && [ ! -L "$base" ] && [ -x "$base" ] && [ -w "$base" ] || return 1
    metadata=$(_operation_lock_stat '%u:%a' "$base") || return 1
    case $metadata in
    *[!0-9:]* | :* | *:) return 1 ;;
    esac
    mode=${metadata#*:}
    [ "${metadata%%:*}" -eq 0 ] && [ $((8#$mode & 0002)) -ne 0 ] &&
        [ $((8#$mode & 01000)) -ne 0 ]
}

_operation_lock_base() {
    local uid=$1 base
    if [ "$uid" -eq 0 ] && _operation_lock_validate_base /run 0; then
        printf '/run\n'
        return 0
    fi
    base=$(cd -P -- /tmp && pwd -P) || return 1
    _operation_lock_validate_tmp "$base" || return 1
    printf '%s\n' "$base"
}

_directory_lock_validate() {
    local directory=$1 metadata
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    metadata=$(_operation_lock_stat '%u:%a' "$directory") || return 1
    [ "$metadata" = "${EUID}:700" ]
}

_directory_lock_read_owner() {
    local directory=$1 metadata extra
    _DIRECTORY_LOCK_RECORDED_PID='' _DIRECTORY_LOCK_RECORDED_TOKEN=''
    _directory_lock_validate "$directory" || return 1
    [ -f "$directory/owner" ] && [ ! -L "$directory/owner" ] || return 1
    metadata=$(_operation_lock_stat '%u:%a:%h' "$directory/owner") || return 1
    [ "$metadata" = "${EUID}:600:1" ] || return 1
    { IFS=' ' read -r _DIRECTORY_LOCK_RECORDED_PID _DIRECTORY_LOCK_RECORDED_TOKEN extra <"$directory/owner"; } 2>/dev/null || return 1
    case $_DIRECTORY_LOCK_RECORDED_PID in '' | *[!0-9]*) return 1 ;; esac
    [ "$_DIRECTORY_LOCK_RECORDED_PID" -gt 1 ] 2>/dev/null || return 1
    [ -n "$_DIRECTORY_LOCK_RECORDED_TOKEN" ] && [ -z "$extra" ]
}

# Returns 1 for contention and 2 for an unsafe path or an I/O error. Install EXIT
# cleanup before calling; ownership is published before deferred signals resume.
_directory_lock_acquire() {
    local saved_hup saved_int saved_term pending_signal='' rc=0
    saved_hup=$(trap -p HUP)
    saved_int=$(trap -p INT)
    saved_term=$(trap -p TERM)
    # A signal between mkdir and publishing ownership must not strand the lock.
    # Defer it only until initialization finishes, then let the caller's original
    # handler run with the complete ownership record available to EXIT cleanup.
    trap '[ -n "$pending_signal" ] || pending_signal=HUP' HUP
    trap '[ -n "$pending_signal" ] || pending_signal=INT' INT
    trap '[ -n "$pending_signal" ] || pending_signal=TERM' TERM
    _directory_lock_acquire_inner "$@" || rc=$?
    # trap -p produces shell-quoted commands; an empty snapshot means default.
    eval "${saved_hup:-trap - HUP}"
    eval "${saved_int:-trap - INT}"
    eval "${saved_term:-trap - TERM}"
    [ -z "$pending_signal" ] || kill -s "$pending_signal" "$BASHPID"
    return "$rc"
}

_directory_lock_acquire_inner() {
    local directory=$1 timeout=${2:-0} deadline=$((SECONDS + ${2:-0})) pid=$BASHPID token
    _DIRECTORY_LOCK_DIR='' _DIRECTORY_LOCK_PID='' _DIRECTORY_LOCK_TOKEN=''
    token="${pid}:${RANDOM}:${RANDOM}"
    while ! (trap '' HUP INT TERM; umask 077; mkdir -m 0700 -- "$directory") 2>/dev/null; do
        _directory_lock_validate "$directory" || return 2
        [ -z "$pending_signal" ] || return 1 # Local to the acquisition wrapper.
        [ "$timeout" -gt 0 ] && [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 1 || return 2
    done
    if ! _directory_lock_validate "$directory" ||
        ! (trap '' HUP INT TERM; umask 077; set -o noclobber; printf '%s %s\n' "$pid" "$token" >"$directory/owner") 2>/dev/null; then
        rmdir -- "$directory" 2>/dev/null || true
        return 2
    fi
    _DIRECTORY_LOCK_DIR=$directory
    _DIRECTORY_LOCK_PID=$pid
    _DIRECTORY_LOCK_TOKEN=$token
}

_directory_lock_release() {
    local directory=${1:-} pid=${2:-} token=${3:-}
    [ -n "$directory" ] && [ -n "$token" ] || return 0
    # Subshells/background services inherit variables, never lock ownership.
    [ "$pid" = "$BASHPID" ] || return 0
    _directory_lock_read_owner "$directory" || return 1
    [ "$_DIRECTORY_LOCK_RECORDED_PID" = "$pid" ] &&
        [ "$_DIRECTORY_LOCK_RECORDED_TOKEN" = "$token" ] || return 1
    command rm -- "$directory/owner" && rmdir -- "$directory"
}

_directory_lock_report() {
    local directory=$1 cleanup
    _operation_lock_emit_detail '锁目录' "$directory"
    if _directory_lock_read_owner "$directory"; then
        _operation_lock_emit_detail '持锁 PID' "$_DIRECTORY_LOCK_RECORDED_PID"
        if kill -0 "$_DIRECTORY_LOCK_RECORDED_PID" 2>/dev/null; then
            _operation_lock_emit_detail '处理' '等待当前操作结束；PID 存在不代表一定是原持锁进程，请勿直接删除锁'
            return
        fi
        _operation_lock_emit_detail '状态' '持锁进程已退出，可能是强制终止或断电留下的残留锁'
    else
        _operation_lock_emit_detail '状态' '锁记录不完整，可能仍在初始化或异常退出后留下了残留锁'
    fi
    printf -v cleanup 'rm -f -- %q && rmdir -- %q' "$directory/owner" "$directory"
    _operation_lock_emit_detail '处理' "确认没有相关操作运行后，手动清理：$cleanup"
}

operation_lock_acquire() {
    local uid=$EUID base parent directory rc=0
    base=$(_operation_lock_base "$uid") || {
        _operation_lock_emit_error '无法使用安全的运行时目录建立操作锁，未修改系统'
        _operation_lock_emit_detail '要求' '运行时目录必须安全，且不能被其他用户任意替换'
        return 1
    }
    # The parent stays outside CLASHCTL_HOME and is never removed by uninstall.
    parent="${base}/clashctl-operation-${uid}"
    if ! (umask 077; mkdir -m 0700 -- "$parent") 2>/dev/null; then
        _directory_lock_validate "$parent" || {
            _operation_lock_emit_error '操作锁目录的归属、类型或权限不安全，未修改系统'
            _operation_lock_emit_detail '目录' "$parent"
            return 1
        }
    fi
    directory="$parent/operation.lock.d"
    # Synchronous installer/update subshells may reuse the ancestor's lock.
    if [ "${CLASHCTL_OPERATION_LOCK_DIR:-}" = "$directory" ] &&
        _directory_lock_read_owner "$directory" &&
        [ "$_DIRECTORY_LOCK_RECORDED_PID" = "${CLASHCTL_OPERATION_LOCK_PID:-}" ] &&
        [ "$_DIRECTORY_LOCK_RECORDED_TOKEN" = "${CLASHCTL_OPERATION_LOCK_TOKEN:-}" ] &&
        kill -0 "$_DIRECTORY_LOCK_RECORDED_PID" 2>/dev/null; then
        return 0
    fi
    # Publish the path before initialization so EXIT cleanup can use the generic
    # ownership fields if a deferred signal arrives before the normal handoff.
    CLASHCTL_OPERATION_LOCK_DIR=$directory
    unset CLASHCTL_OPERATION_LOCK_PID CLASHCTL_OPERATION_LOCK_TOKEN
    _directory_lock_acquire "$directory" 0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ]; then
            _operation_lock_emit_error '另一项 clashctl 安装、更新或卸载正在进行，或存在残留锁，本次未修改系统'
        else
            _operation_lock_emit_error '操作锁目录的归属、类型或权限不安全，或无法写入，未修改系统'
        fi
        _directory_lock_report "$directory"
        unset CLASHCTL_OPERATION_LOCK_DIR
        return 1
    fi
    CLASHCTL_OPERATION_LOCK_PID=$_DIRECTORY_LOCK_PID
    CLASHCTL_OPERATION_LOCK_TOKEN=$_DIRECTORY_LOCK_TOKEN
    export -n CLASHCTL_OPERATION_LOCK_DIR CLASHCTL_OPERATION_LOCK_PID CLASHCTL_OPERATION_LOCK_TOKEN
}

operation_lock_release() {
    local directory=${CLASHCTL_OPERATION_LOCK_DIR:-}
    local pid=${CLASHCTL_OPERATION_LOCK_PID:-} token=${CLASHCTL_OPERATION_LOCK_TOKEN:-}
    if [ -n "$directory" ] && [ "$directory" = "${_DIRECTORY_LOCK_DIR:-}" ] &&
        { [ -z "$pid" ] || [ -z "$token" ]; }; then
        pid=${_DIRECTORY_LOCK_PID:-}
        token=${_DIRECTORY_LOCK_TOKEN:-}
    fi
    _directory_lock_release "$directory" "$pid" "$token" || return 1
    unset CLASHCTL_OPERATION_LOCK_DIR CLASHCTL_OPERATION_LOCK_PID CLASHCTL_OPERATION_LOCK_TOKEN
}
