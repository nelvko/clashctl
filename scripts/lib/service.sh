#!/usr/bin/env bash

if ! declare -F _service_process_record_pid >/dev/null 2>&1; then
    _service_process_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    # shellcheck source=scripts/lib/service-process.sh
    . "${_service_process_lib_dir}/service-process.sh"
    unset _service_process_lib_dir
fi

if ! declare -F operation_lock_release >/dev/null 2>&1; then
    _service_operation_lock_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    # shellcheck source=scripts/lib/operation-lock.sh
    . "${_service_operation_lock_lib_dir}/operation-lock.sh"
    unset _service_operation_lock_lib_dir
fi

service_manager=
service_log_path=
service_pid_path=

_service_run_without_operation_lock() {
    if [ -z "${CLASHCTL_OPERATION_LOCK_DIR:-}" ]; then
        "$@"
        return
    fi
    (
        trap - INT TERM HUP
        operation_lock_release || exit 1
        "$@"
    )
}

_service_owned_pids() {
    _service_process_record_pid "$service_pid_path" 2>/dev/null
}

_service_privileged_pid() {
    local record
    _service_privileged_marker_exists || return 1
    record=$(_service_privileged_record_path /run/clashctl "$(id -u)" "$CLASHCTL_KERNEL") || return 1
    _service_process_record_pid "$record" 2>/dev/null
}

# 读取属性时解析 key=value，兼容不支持 --value 的旧版 systemctl。
# 保留查询失败状态，避免将连接失败或缺失属性误判为空值。
_service_systemctl_property() {
    local property=$1 output
    shift
    output=$(systemctl "$@" -p "$property") || return 1
    case "$output" in
    "$property="*) printf '%s\n' "${output#*=}" ;;
    *) return 1 ;;
    esac
}

# 只返回与本次安装的二进制、启动参数一致的 PID，供 TUN 归属检查使用。
service_main_pid() {
    detect_service_manager
    local pid='' expected_argv record
    case "$service_manager" in
    systemd) pid=$(_service_systemctl_property MainPID show "$CLASHCTL_KERNEL" 2>/dev/null) || return 1 ;;
    systemd-user)
        if _service_privileged_marker_exists; then
            pid=$(_service_privileged_pid) || return 1
        else
            pid=$(_service_systemctl_property MainPID --user show "$CLASHCTL_KERNEL" 2>/dev/null) || return 1
        fi
        ;;
    runit) pid=$(sv status "$CLASHCTL_KERNEL" 2>/dev/null | sed -n 's/.*(pid \([0-9]*\)).*/\1/p') ;;
    sysvinit | openrc) read -r pid <"$service_pid_path" 2>/dev/null || return 1 ;;
    *)
        pid=$(_service_owned_pids) || {
            record=$(_service_privileged_record_path /run/clashctl "$(id -u)" "$CLASHCTL_KERNEL") || return 1
            _service_privileged_record_is_secure "$record" || return 1
            pid=$(_service_process_record_pid "$record" 2>/dev/null) || return 1
        }
        ;;
    esac
    case $pid in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    expected_argv=$(_service_process_values_argv_hex \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME") || return 1
    _service_process_snapshot "$pid" "$BIN_KERNEL" "$expected_argv" || return 1
    printf '%s\n' "$pid"
}

_service_uptime_process_ticks() {
    local stat rest
    local -a fields=()
    { IFS= read -r stat <"/proc/$1/stat"; } 2>/dev/null || return 1
    rest=${stat##*) }
    [ "$rest" != "$stat" ] || return 1
    read -r -a fields <<<"$rest"
    [ "${#fields[@]}" -ge 20 ] || return 1
    case ${fields[0]} in
    Z | X | x) return 1 ;;
    [a-zA-Z]) ;;
    *) return 1 ;;
    esac
    case ${fields[19]} in '' | *[!0-9]*) return 1 ;; esac
    printf '%s\n' "${fields[19]}"
}

_service_uptime_clock() {
    local uptime _idle ticks
    { read -r uptime _idle </proc/uptime; } 2>/dev/null || return 1
    ticks=$(getconf CLK_TCK 2>/dev/null) || return 1
    printf '%s %s\n' "$uptime" "$ticks"
}

# PID 必须先由 service_main_pid 校验；这里只读查询持续时间，并在输出前重查进程身份。
service_uptime() {
    local pid=${1:-} start current clock uptime ticks extra whole fraction scale elapsed
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] 2>/dev/null || return 1
    start=$(_service_uptime_process_ticks "$pid") || return 1
    clock=$(_service_uptime_clock) || return 1
    case "$clock" in *$'\n'*) return 1 ;; esac
    read -r uptime ticks extra <<<"$clock"
    [ -z "$extra" ] || return 1
    case "$uptime" in
    *.*) whole=${uptime%%.*}; fraction=${uptime#*.} ;;
    *) whole=$uptime; fraction=0 ;;
    esac
    case "$start:$ticks:$whole:$fraction" in
    *[!0-9:]* | :* | *::*) return 1 ;;
    esac
    [ -n "$fraction" ] && [ -n "$whole" ] && [ -n "$ticks" ] || return 1
    # 限制位数，保证后续整数及小数交叉乘法不会溢出 Bash 的有符号整数。
    [ "${#start}" -le 18 ] && [ "${#whole}" -le 15 ] &&
        [ "${#ticks}" -le 9 ] && [ "${#fraction}" -le 9 ] || return 1
    ticks=$((10#$ticks))
    [ "$ticks" -gt 0 ] || return 1
    whole=$((10#$whole))
    scale=$((10 ** ${#fraction}))
    fraction=$((10#$fraction))
    current=$((10#$start))
    elapsed=$((whole - current / ticks))
    # 分开比较秒与余数，避免浮点舍入把恰好 1 秒显示为 0 秒。
    if [ "$((fraction * ticks))" -lt "$(((current % ticks) * scale))" ]; then
        elapsed=$((elapsed - 1))
    fi
    [ "$elapsed" -ge 0 ] || return 1
    current=$(_service_uptime_process_ticks "$pid") || return 1
    [ "$current" = "$start" ] || return 1
    printf '%s\n' "$elapsed"
}

_service_privileged_marker_exists() {
    local record
    _is_root && return 1
    _service_privileged_runtime_is_secure /run/clashctl || return 1
    record=$(_service_privileged_record_path /run/clashctl "$(id -u)" "$CLASHCTL_KERNEL") || return 1
    _service_privileged_record_is_secure "$record"
}

# 只读连接探测；degraded 仍可用。用户模板的 ExecCondition 要求 systemd >= 243。
service_user_available() {
    local version
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user show-environment >/dev/null 2>&1 || return 1
    version=$(_service_systemctl_property Version --user show 2>/dev/null) || return 1
    [[ $version =~ ^([0-9]+)([[:space:].+~-]|$) ]] || return 1
    version=${BASH_REMATCH[1]}
    [ "${#version}" -le 5 ] && [ "$((10#$version))" -ge 243 ]
}

detect_service_manager() {
    [ -n "$service_manager" ] && return 0
    [ -n "${INIT_TYPE:-}" ] || INIT_TYPE=$(readlink /proc/1/exe 2>/dev/null || echo "nohup")
    if [ "$INIT_TYPE" != systemd-user ]; then
        grep -qsE "docker|kubepods|containerd|podman|lxc" /proc/1/cgroup 2>/dev/null && INIT_TYPE='nohup'
        _is_root || INIT_TYPE='nohup'
    fi
    INIT_TYPE=$(basename "$INIT_TYPE")

    case "$INIT_TYPE" in
    systemd-user)
        service_manager="systemd-user"
        ;;
    *systemd)
        service_manager="systemd"
        ;;
    *openrc*)
        service_manager="openrc"
        ;;
    *busybox*)
        service_manager="nohup"
        command -v openrc-init >&/dev/null && service_manager="openrc"
        ;;
    *runit)
        service_manager="runit"
        ;;
    *init)
        service_manager="sysvinit"
        ;;
    nohup | *)
        service_manager="nohup"
        ;;
    esac

    service_log_path="/var/log/${CLASHCTL_KERNEL}.log"
    service_pid_path="/run/${CLASHCTL_KERNEL}.pid"
    case "$service_manager" in
    nohup | systemd-user)
        service_log_path="${CLASH_DATA_DIR}/${CLASHCTL_KERNEL}.log"
        service_pid_path="${CLASH_DATA_DIR}/${CLASHCTL_KERNEL}.pid"
        ;;
    esac
    return 0
}

_service_nohup_start_locked() {    local pid expected_argv
    expected_argv=$(_service_process_values_argv_hex \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME") || return 1
    if _service_process_record_pid "$service_pid_path" >/dev/null 2>&1; then
        [ "$_SERVICE_RECORD_ARGV" = "$expected_argv" ]
        return
    fi
    command rm -f -- "$service_pid_path" || return 1
    (
        trap - INT TERM HUP
        operation_lock_release || exit 1
        exec nohup "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME"
    ) </dev/null >"$service_log_path" 2>&1 9>&- &
    pid=$!
    _service_process_record_create \
        "$service_pid_path" "$pid" "$BIN_KERNEL" \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" || {
        if [ "${_SERVICE_SNAPSHOT_PID:-}" = "$pid" ]; then
            _service_process_stop_snapshot \
                "$pid" "$_SERVICE_SNAPSHOT_STARTTIME" \
                "$_SERVICE_SNAPSHOT_ARGV" "$_SERVICE_SNAPSHOT_EXE_ID"
        elif [ "${_SERVICE_PROCESS_BIRTH_PID:-}" = "$pid" ]; then
            _service_process_stop_birth "$pid" "$_SERVICE_PROCESS_BIRTH_STARTTIME"
        fi
        command rm -f -- "$service_pid_path"
        return 1
    }
}

_service_nohup_stop_locked() {
    [ -e "$service_pid_path" ] || [ -L "$service_pid_path" ] || return 0
    if ! _service_process_record_load "$service_pid_path"; then
        command rm -f -- "$service_pid_path"
        return 0
    fi
    _service_process_stop_recorded "$service_pid_path" || return 1
    [ "${_SERVICE_PROCESS_RECORD_CAN_REMOVE:-0}" -eq 0 ] ||
        command rm -f -- "$service_pid_path"
}

service_start() {
    _require_base_config || return 1
    detect_service_manager
    case "$service_manager" in
    systemd-user)
        if _is_root; then
            _ui_error '用户级服务需要由所属普通用户运行，请退出 sudo 后重试'
            return 1
        fi
        # TUN 由独立的 root helper 托管，用户单元始终保持停止。
        _service_privileged_marker_exists && return 0
        if _is_tun_enabled; then
            service_sudo_start
        else
            _service_run_without_operation_lock systemctl --user start "$CLASHCTL_KERNEL"
        fi
        ;;
    systemd)
        _service_run_without_operation_lock systemctl start "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        _service_run_without_operation_lock service "$CLASHCTL_KERNEL" start
        ;;
    openrc)
        _service_run_without_operation_lock rc-service "$CLASHCTL_KERNEL" start
        ;;
    runit)
        # runit 需要先加入监督目录才能启动；此时主配置与 runtime 必须已有效。
        _valid_config "$CLASH_CONFIG_RUNTIME" || return 1
        service_enable || return 1
        _service_run_without_operation_lock sv up "$CLASHCTL_KERNEL"
        ;;
    nohup | *)
        if [ "$service_manager" = nohup ] && ! _is_root; then
            _service_privileged_marker_exists && return 0
            # 从用户服务切回 nohup 或停止后重启时，沿用已保存的 TUN 配置。
            if declare -F _is_tun_enabled >/dev/null 2>&1 && _is_tun_enabled; then
                service_sudo_start
                return
            fi
        fi
        local lock rc=0
        /usr/bin/install -d "$(dirname -- "$service_pid_path")" || return 1
        _service_process_lock_acquire "$service_pid_path" || return 1
        lock=$_SERVICE_PROCESS_LOCK_PATH
        _service_nohup_start_locked || rc=$?
        _service_process_lock_release "$lock" || rc=1
        return "$rc"
        ;;
    esac
}

service_sudo_start() {
    if _is_root; then
        service_start
        return
    fi
    _require_base_config || return 1
    detect_service_manager
    # 显式 stop 会取消 Restart=on-failure，随后再启动 helper，避免双实例。
    if [ "$service_manager" = systemd-user ]; then
        systemctl --user stop "$CLASHCTL_KERNEL" || return 1
    fi
    local owner_uid helper rc=0
    owner_uid=$(id -u) || return 1
    helper=${_SERVICE_PROCESS_HELPER_FILE:-}
    [ -r "$helper" ] || return 1
    /usr/bin/install -d "$(dirname -- "$service_log_path")" || return 1
    : >>"$service_log_path" || return 1
    # The caller opens the log as itself; the privileged helper only inherits stdout.
    # shellcheck disable=SC2024
    _service_run_without_operation_lock sudo bash "$helper" privileged-start \
        "$owner_uid" "$CLASHCTL_KERNEL" "$BIN_KERNEL" \
        "$CLASH_RESOURCES_DIR" "$CLASH_CONFIG_RUNTIME" \
        >>"$service_log_path" || rc=$?
    stty opost 2>/dev/null || true
    return "$rc"
}

service_sudo_stop() {
    _is_root && service_stop && return 0
    local owner_uid helper expected_argv rc=0
    owner_uid=$(id -u) || return 1
    helper=${_SERVICE_PROCESS_HELPER_FILE:-}
    [ -r "$helper" ] || return 1
    expected_argv=$(_service_process_values_argv_hex \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME") || return 1
    sudo bash "$helper" privileged-stop "$owner_uid" "$CLASHCTL_KERNEL" "$expected_argv" || rc=$?
    stty opost 2>/dev/null || true
    return "$rc"
}

service_stop() {
    detect_service_manager
    case "$service_manager" in
    systemd-user)
        local rc=0
        systemctl --user stop "$CLASHCTL_KERNEL" || rc=$?
        if _service_privileged_marker_exists; then
            service_sudo_stop || rc=$?
        fi
        return "$rc"
        ;;
    systemd)
        systemctl stop "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" stop
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" stop
        ;;
    runit)
        sv down "$CLASHCTL_KERNEL"
        ;;
    nohup | *)
        local lock rc=0
        /usr/bin/install -d "$(dirname -- "$service_pid_path")" || return 1
        _service_process_lock_acquire "$service_pid_path" || return 1
        lock=$_SERVICE_PROCESS_LOCK_PATH
        _service_nohup_stop_locked || rc=$?
        _service_process_lock_release "$lock" || rc=1
        return "$rc"
        ;;
    esac
}

service_status() {
    detect_service_manager
    case "$service_manager" in
    systemd-user)
        if _service_privileged_marker_exists; then
            printf '%s\n' "$CLASHCTL_KERNEL 正以特权模式运行（TUN helper；用户服务已停止）"
        else
            systemctl --user status "$CLASHCTL_KERNEL" "$@"
        fi
        ;;
    systemd)
        systemctl status "$CLASHCTL_KERNEL" "$@"
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" status "$@"
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" status "$@"
        ;;
    runit)
        sv status "$CLASHCTL_KERNEL" "$@"
        ;;
    nohup | *)
        local pid
        pid=$(_service_owned_pids) || pid=
        if [ -n "$pid" ]; then
            printf '%s\n' "$CLASHCTL_KERNEL 正在运行 (PID $pid)"
        elif _service_privileged_marker_exists; then
            printf '%s\n' "$CLASHCTL_KERNEL 正以特权模式运行"
        else
            return 1
        fi
        ;;
    esac
}

service_is_active() {
    detect_service_manager
    case "$service_manager" in
    systemd-user)
        _service_privileged_marker_exists ||
            systemctl --user is-active "$CLASHCTL_KERNEL" >/dev/null 2>&1
        ;;
    systemd)
        systemctl is-active "$CLASHCTL_KERNEL" >/dev/null 2>&1
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" status >/dev/null 2>&1
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" status >/dev/null 2>&1
        ;;
    runit)
        sv status "$CLASHCTL_KERNEL" 2>/dev/null | grep -qs '^run'
        ;;
    nohup | *)
        _service_owned_pids >/dev/null 2>&1 || _service_privileged_marker_exists
        ;;
    esac
}

# 只读查询输出归一化状态；检测失败不输出状态，避免把查询错误误报为停止。
# 不复用 service_is_active，避免把管理器故障、权限错误误报为停止。
service_state() {
    detect_service_manager || return 1
    local output rc=0 state
    case "$service_manager" in
    systemd | systemd-user)
        if [ "$service_manager" = systemd-user ]; then
            if _service_privileged_marker_exists; then
                printf 'running\n'
                return 0
            fi
            output=$(systemctl --user is-active "$CLASHCTL_KERNEL" 2>/dev/null) || rc=$?
        else
            output=$(systemctl is-active "$CLASHCTL_KERNEL" 2>/dev/null) || rc=$?
        fi
        case "$rc:$output" in
        0:active | 0:reloading | 0:refreshing) state=running ;;
        3:inactive) state=stopped ;;
        3:failed) state=failed ;;
        3:activating) state=starting ;;
        3:deactivating) state=stopping ;;
        *) return 1 ;;
        esac
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" status >/dev/null 2>&1 || rc=$?
        # LSB status：1 为进程已死但 PID 文件残留，2 为锁文件残留，3 为未运行。
        case "$rc" in
        0) state=running ;;
        1 | 2 | 3) state=stopped ;;
        *) return 1 ;;
        esac
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" status >/dev/null 2>&1 || rc=$?
        # openrc-run 的原生状态码还包括过渡、闲置与进程崩溃。
        case "$rc" in
        0) state=running ;;
        3) state=stopped ;;
        4) state=stopping ;;
        8) state=starting ;;
        16) state=stopped ;;
        32) state=failed ;;
        *) return 1 ;;
        esac
        ;;
    runit)
        output=$(sv status "$CLASHCTL_KERNEL" 2>/dev/null) || return 1
        case "$output" in
        run:*) state=running ;;
        down:*) state=stopped ;;
        *) return 1 ;;
        esac
        ;;
    nohup)
        _service_nohup_state
        return
        ;;
    *) return 1 ;;
    esac
    printf '%s\n' "$state"
}

_service_state_path_absent() {
    local path=$1 parent
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    parent=$(dirname -- "$path") || return 1
    while [ ! -d "$parent" ]; do
        [ "$parent" != / ] && [ "$parent" != . ] || return 1
        parent=$(dirname -- "$parent") || return 1
    done
    # 不把无法遍历父目录造成的不可见误认为记录不存在。
    [ -x "$parent" ]
}

_service_record_state() {
    local record=$1 current expected_argv stat rest
    if _service_state_path_absent "$record"; then
        printf 'stopped\n'
        return 0
    fi
    _service_process_record_load "$record" || return 1
    expected_argv=$(_service_process_values_argv_hex \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME") || return 1
    [ "$_SERVICE_RECORD_ARGV" = "$expected_argv" ] || return 1
    if _service_process_record_matches_loaded; then
        printf 'running\n'
        return 0
    fi
    # 身份不匹配可以确认记录已过期；读取 /proc 失败则不能据此认定进程已停止。
    [ -r /proc/self/stat ] || return 1
    if _service_state_path_absent "/proc/$_SERVICE_RECORD_PID"; then
        printf 'stopped\n'
        return 0
    fi
    current=$(_service_process_starttime "$_SERVICE_RECORD_PID") || return 1
    if [ "$current" = "$_SERVICE_RECORD_STARTTIME" ]; then
        { IFS= read -r stat <"/proc/$_SERVICE_RECORD_PID/stat"; } 2>/dev/null || return 1
        rest=${stat##*) }
        [ "$rest" != "$stat" ] || return 1
        case ${rest%% *} in
        Z | X) printf 'stopped\n'; return 0 ;;
        esac
        current=$(_service_process_argv_hex "$_SERVICE_RECORD_PID") || return 1
        if [ "$current" = "$_SERVICE_RECORD_ARGV" ]; then
            current=$(_service_process_exe_id "$_SERVICE_RECORD_PID") || return 1
            [ "$current" != "$_SERVICE_RECORD_EXE_ID" ] || return 1
        fi
    fi
    printf 'stopped\n'
}

_service_nohup_state() {
    local state='' local_rc=0 record
    state=$(_service_record_state "$service_pid_path") || local_rc=$?
    [ "$state" != running ] || { printf 'running\n'; return 0; }
    if ! _is_root; then
        record=$(_service_privileged_record_path /run/clashctl "$(id -u)" "$CLASHCTL_KERNEL") || return 1
        if ! _service_state_path_absent /run/clashctl; then
            _service_privileged_runtime_is_secure /run/clashctl || return 1
            if ! _service_state_path_absent "$record"; then
                _service_privileged_record_is_secure "$record" || return 1
                # 非 root 无法读取 0600 的特权记录，沿用安全标记作为运行依据；不调用 sudo。
                printf 'running\n'
                return 0
            fi
        fi
    fi
    [ "$local_rc" -eq 0 ] || return 1
    printf 'stopped\n'
}

_service_runit_enable_link() {
    printf '%s\n' "/etc/runit/runsvdir/default/${CLASHCTL_KERNEL}"
}

_service_runit_link_state() {
    local link=$1
    if [ -L "$link" ]; then
        printf 'symlink\t%s\n' "$(readlink -- "$link")"
    elif [ -e "$link" ]; then
        printf 'other\t\n'
    else
        printf 'absent\t\n'
    fi
}

_service_atomic_symlink() {
    local target=$1 link=$2 tmp
    tmp="${link}.clashctl-new.$$.$RANDOM"
    ln -s -- "$target" "$tmp" || return 1
    if ! /bin/mv -fT -- "$tmp" "$link"; then
        command rm -f -- "$tmp"
        return 1
    fi
}

service_enable() {
    detect_service_manager
    local rc=0
    _service_enable || rc=$?
    [ "$rc" -ne 0 ] || return 0
    if [ "$service_manager" = systemd-user ]; then
        _ui_error '登录自启设置失败'
    else
        _ui_error '开机自启设置失败'
    fi
    return "$rc"
}

_service_enable() {
    case "$service_manager" in
    systemd-user)
        systemctl --user enable --quiet "$CLASHCTL_KERNEL"
        ;;
    systemd)
        systemctl enable --quiet "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --add "$CLASHCTL_KERNEL" >/dev/null &&
                chkconfig "$CLASHCTL_KERNEL" on >/dev/null
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$CLASHCTL_KERNEL" defaults >/dev/null &&
                update-rc.d "$CLASHCTL_KERNEL" enable >/dev/null
        else
            return 127
        fi
        ;;
    openrc)
        rc-update add "$CLASHCTL_KERNEL" default >/dev/null
        ;;
    runit)
        local service_target enable_link desired_target current_kind current_target
        service_target=$(_service_target) || return 1
        enable_link=$(_service_runit_enable_link)
        desired_target=$(dirname -- "$service_target")
        IFS=$'\t' read -r current_kind current_target < <(_service_runit_link_state "$enable_link")
        [ "$current_kind" = absent ] ||
            { [ "$current_kind" = symlink ] && [ "$current_target" = "$desired_target" ]; } || return 1
        /usr/bin/install -d "$(dirname -- "$enable_link")" &&
            _service_atomic_symlink "$desired_target" "$enable_link"
        ;;
    nohup | *)
        return 0
        ;;
    esac
}

service_disable() {
    detect_service_manager
    case "$service_manager" in
    systemd-user)
        systemctl --user disable --quiet "$CLASHCTL_KERNEL"
        ;;
    systemd)
        systemctl disable --quiet "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig "$CLASHCTL_KERNEL" off >/dev/null
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$CLASHCTL_KERNEL" disable >/dev/null
        else
            return 127
        fi
        ;;
    openrc)
        rc-update del "$CLASHCTL_KERNEL" default >/dev/null
        ;;
    runit)
        local enable_link current_kind current_target desired_target=
        enable_link=$(_service_runit_enable_link)
        IFS=$'\t' read -r current_kind current_target < <(_service_runit_link_state "$enable_link")
        [ "$current_kind" != absent ] || return 0
        [ "$current_kind" = symlink ] || return 1
        desired_target=$(_service_target 2>/dev/null) || desired_target=
        [ -z "$desired_target" ] || desired_target=$(dirname -- "$desired_target")
        if [ "$current_target" != "$desired_target" ]; then
            return 1
        fi
        command rm -f -- "$enable_link"
        ;;
    nohup | *)
        return 0
        ;;
    esac
}

_service_unregister() {
    detect_service_manager
    case "$service_manager" in
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --del "$CLASHCTL_KERNEL" >/dev/null
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d -f "$CLASHCTL_KERNEL" remove >/dev/null
        else
            return 127
        fi
        ;;
    *) return 0 ;;
    esac
}

service_log() {
    detect_service_manager
    case "$service_manager" in
    systemd-user)
        if _service_uses_privileged_log; then
            if [ $# -gt 0 ]; then
                tail "$@" "$service_log_path"
            else
                less "$service_log_path"
            fi
        else
            journalctl --user -u "$CLASHCTL_KERNEL" "$@"
        fi
        ;;
    systemd)
        journalctl -u "$CLASHCTL_KERNEL" "$@"
        ;;
    *)
        [ $# -gt 0 ] && {
            tail "$@" "$service_log_path"
            return
        }
        less "$service_log_path"
        ;;
    esac
}

service_follow_log() {
    detect_service_manager
    case "$service_manager" in
    systemd-user)
        if _service_uses_privileged_log; then
            tail -f -n 0 "$service_log_path"
        else
            journalctl --user -u "$CLASHCTL_KERNEL" -q -f -n 0
        fi
        ;;
    systemd)
        journalctl -u "$CLASHCTL_KERNEL" -q -f -n 0
        ;;
    *)
        tail -f -n 0 "$service_log_path"
        ;;
    esac
}

_service_uses_privileged_log() {
    _service_privileged_marker_exists ||
        { declare -F _is_tun_enabled >/dev/null 2>&1 && _is_tun_enabled; }
}

service_log_location() {
    detect_service_manager
    case "$service_manager" in
    systemd) printf 'journalctl -u %s\n' "$CLASHCTL_KERNEL" ;;
    systemd-user)
        if _service_uses_privileged_log; then
            printf '%s\n' "$service_log_path"
        else
            printf 'journalctl --user -u %s\n' "$CLASHCTL_KERNEL"
        fi
        ;;
    *) printf '%s\n' "$service_log_path" ;;
    esac
}

_service_target() {
    detect_service_manager

    case "$service_manager" in
    systemd-user)
        printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${CLASHCTL_KERNEL}.service"
        ;;
    systemd)
        printf '%s\n' "/etc/systemd/system/${CLASHCTL_KERNEL}.service"
        ;;
    sysvinit | openrc)
        printf '%s\n' "/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    runit)
        printf '%s\n' "/etc/sv/${CLASHCTL_KERNEL}/run"
        ;;
    *)
        return 1
        ;;
    esac
}

# 将服务单元模板渲染（替换占位符）到 <dst>；无服务管理器时返回 1
_render_service_unit() {
    local dst=$1
    detect_service_manager

    local template_dir="${CLASHCTL_SRC}/scripts/init"
    local kernel_desc="$CLASHCTL_KERNEL Daemon, A[nother] Clash Kernel."
    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local service_src

    case "$service_manager" in
    systemd-user)
        service_src="${template_dir}/systemd-user.sh"
        ;;
    systemd)
        service_src="${template_dir}/systemd.sh"
        ;;
    sysvinit)
        service_src="${template_dir}/sysvinit.sh"
        ;;
    openrc)
        service_src="${template_dir}/openrc.sh"
        ;;
    runit)
        service_src="${template_dir}/runit.sh"
        ;;
    *)
        return 1
        ;;
    esac

    /usr/bin/install -D -m 0644 "$service_src" "$dst" || return 1
    sed -i \
        -e "s#placeholder_cmd_path#$cmd_path#g" \
        -e "s#placeholder_cmd_args#$cmd_arg#g" \
        -e "s#placeholder_cmd_full#$cmd_full#g" \
        -e "s#placeholder_yq_path#${BIN_YQ:-${CLASHCTL_HOME:-}/bin/yq}#g" \
        -e "s#placeholder_config_path#$CLASH_CONFIG_RUNTIME#g" \
        -e "s#placeholder_log_path#$service_log_path#g" \
        -e "s#placeholder_pid_path#$service_pid_path#g" \
        -e "s#placeholder_kernel_name#$CLASHCTL_KERNEL#g" \
        -e "s#placeholder_kernel_desc#$kernel_desc#g" \
        -e "s#placeholder_home#$CLASHCTL_HOME#g" \
        "$dst"
}

_service_definition_is_owned() {
    local target=$1 command_line
    command_line="$BIN_KERNEL -d $CLASH_RESOURCES_DIR -f $CLASH_CONFIG_RUNTIME"
    case $service_manager in
    systemd | systemd-user)
        grep -Fqx -- "ExecStart=$command_line" "$target" 2>/dev/null
        ;;
    sysvinit)
        grep -Fqx -- "cmd=\"$command_line\"" "$target" 2>/dev/null
        ;;
    openrc)
        grep -Fqx -- "command=\"$BIN_KERNEL\"" "$target" 2>/dev/null &&
            grep -Fqx -- "command_args=\"-d $CLASH_RESOURCES_DIR -f $CLASH_CONFIG_RUNTIME\"" \
                "$target" 2>/dev/null
        ;;
    runit)
        grep -Fqx -- "exec $command_line >$service_log_path 2>&1" "$target" 2>/dev/null
        ;;
    *) return 1 ;;
    esac
}


# 不接管外部同名服务；用户先自行处理冲突。
_service_check_conflict() {
    local target fragment
    detect_service_manager
    target=$(_service_target) || return 0
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ ! -L "$target" ] && _service_definition_is_owned "$target" && return 0
        _ui_error "同名服务已存在，请先处理后重试：$target"
        return 1
    fi
    if [ "$service_manager" = systemd ] || [ "$service_manager" = systemd-user ]; then
        if [ "$service_manager" = systemd-user ]; then
            fragment=$(_service_systemctl_property FragmentPath --user show "$CLASHCTL_KERNEL.service") || return 1
        else
            fragment=$(_service_systemctl_property FragmentPath show "$CLASHCTL_KERNEL.service") || return 1
        fi
        [ -z "$fragment" ] || { _ui_error "同名服务已存在：$fragment"; return 1; }
    fi
}

install_service() (
    local target candidate mode=0755
    detect_service_manager
    _service_check_conflict || return 1
    target=$(_service_target) || return 0
    candidate=$(mktemp) || return 1
    trap 'rm -f -- "$candidate"' EXIT
    _render_service_unit "$candidate" || return 1
    case "$service_manager" in systemd | systemd-user) mode=0644 ;; esac
    install -D -m "$mode" "$candidate" "$target" || return 1
    [ "$service_manager" != systemd ] || systemctl daemon-reload || return 1
    [ "$service_manager" != systemd-user ] || systemctl --user daemon-reload || return 1
    # 这里只注册服务；有效配置启动成功后才设置自启。
    return 0
)

# stop 与卸载共用，停止用户进程后再处理本用户的特权进程。
service_stop_checked() {
    if service_is_active; then
        service_stop || true
        if service_is_active && _service_privileged_marker_exists; then
            service_sudo_stop || { _ui_error '特权内核未能停止，请先执行 clashctl stop 后重试'; return 1; }
        fi
        service_is_active && { _ui_error '服务未能停止'; return 1; }
    fi
    return 0
}

uninstall_service() {
    local target
    detect_service_manager
    _service_check_conflict || return 1
    service_stop_checked || return 1
    target=$(_service_target) || return 0
    service_disable || return 1
    _service_unregister || return 1
    rm -f -- "$target" || return 1
    [ "$service_manager" != systemd ] || systemctl daemon-reload || return 1
    [ "$service_manager" != systemd-user ] || systemctl --user daemon-reload || return 1
    return 0
}
