#!/usr/bin/env bash

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

# systemd 与 systemd --user 的调用只差一个 --user。
_service_systemd() {
    local command=$1
    shift
    if [ "$service_manager" = systemd-user ]; then
        "$command" --user "$@"
    else
        "$command" "$@"
    fi
}

# 原生管理器的启停；runit 对应 sv up/down。
_service_ctl() {
    case "$service_manager" in
    systemd | systemd-user) _service_systemd systemctl "$1" "$CLASHCTL_KERNEL" ;;
    sysvinit) service "$CLASHCTL_KERNEL" "$1" ;;
    openrc) rc-service "$CLASHCTL_KERNEL" "$1" ;;
    runit)
        case $1 in start) sv up "$CLASHCTL_KERNEL" ;; stop) sv down "$CLASHCTL_KERNEL" ;; esac
        ;;
    *) return 1 ;;
    esac
}

# 内核完整 argv 的十六进制形式，nohup 记录与特权 helper 都按它校验进程。
_service_kernel_argv_hex() {
    _service_process_values_argv_hex "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME"
}

# 只返回与本次安装的二进制、启动参数一致的 PID，供 TUN 归属检查使用。
# 特权 helper 的进程记录归 root 且权限为 600，普通用户读不到，不能拿用户 unit 的旧 PID 顶替。
service_main_pid() {
    detect_service_manager
    local pid='' expected_argv
    case "$service_manager" in
    systemd | systemd-user)
        if [ "$service_manager" = systemd-user ] && _service_privileged_marker_exists; then
            return 1
        fi
        pid=$(_service_systemd systemctl show "$CLASHCTL_KERNEL" -p MainPID --value 2>/dev/null)
        ;;
    runit) pid=$(sv status "$CLASHCTL_KERNEL" 2>/dev/null | sed -n 's/.*(pid \([0-9]*\)).*/\1/p') ;;
    sysvinit | openrc) read -r pid <"$service_pid_path" 2>/dev/null || return 1 ;;
    *) pid=$(_service_process_record_pid "$service_pid_path" 2>/dev/null) || return 1 ;;
    esac
    case $pid in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    expected_argv=$(_service_kernel_argv_hex) || return 1
    _service_process_snapshot "$pid" "$BIN_KERNEL" "$expected_argv" || return 1
    printf '%s\n' "$pid"
}

_service_uptime_process_ticks() {
    _service_process_stat "$1" || return 1
    case $_SERVICE_PROCESS_STATE in
    Z | X | x) return 1 ;;
    [a-zA-Z]) ;;
    *) return 1 ;;
    esac
    printf '%s\n' "$_SERVICE_PROCESS_STARTTIME"
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
    version=$(systemctl --user show -p Version --value 2>/dev/null) || return 1
    [[ $version =~ ^([0-9]+)([[:space:].+~-]|$) ]] || return 1
    [ "$((10#${BASH_REMATCH[1]}))" -ge 243 ]
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
    *)
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

_service_nohup_start_locked() {
    local pid expected_argv
    expected_argv=$(_service_kernel_argv_hex) || return 1
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
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" ||
        _service_process_start_failed "$service_pid_path" "$pid"
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
            return
        fi
        ;;
    runit)
        # runit 需要先加入监督目录才能启动；此时主配置与 runtime 必须已有效。
        _valid_config "$CLASH_CONFIG_RUNTIME" || return 1
        service_enable || return 1
        ;;
    systemd | sysvinit | openrc) ;;
    *)
        if ! _is_root; then
            _service_privileged_marker_exists && return 0
            # 从用户服务切回 nohup 或停止后重启时，沿用已保存的 TUN 配置。
            if _is_tun_enabled; then
                service_sudo_start
                return
            fi
        fi
        /usr/bin/install -d "$(dirname -- "$service_pid_path")" || return 1
        _service_process_with_lock "$service_pid_path" _service_nohup_start_locked
        return
        ;;
    esac
    _service_run_without_operation_lock _service_ctl start
}

# 以 sudo 调用 service-process.sh 中的特权 helper：_service_helper 动作 参数…
_service_helper() {
    local action=$1 owner_uid helper rc=0
    shift
    owner_uid=$(id -u) || return 1
    helper=${_SERVICE_PROCESS_HELPER_FILE:-}
    [ -r "$helper" ] || return 1
    sudo bash "$helper" "$action" "$owner_uid" "$CLASHCTL_KERNEL" "$@" || rc=$?
    stty opost 2>/dev/null || true
    return "$rc"
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
        _service_ctl stop || return 1
    fi
    /usr/bin/install -d "$(dirname -- "$service_log_path")" || return 1
    : >>"$service_log_path" || return 1
    # The caller opens the log as itself; the privileged helper only inherits stdout.
    _service_run_without_operation_lock _service_helper privileged-start \
        "$BIN_KERNEL" "$CLASH_RESOURCES_DIR" "$CLASH_CONFIG_RUNTIME" >>"$service_log_path"
}

service_sudo_stop() {
    if _is_root; then
        service_stop
        return
    fi
    local expected_argv
    expected_argv=$(_service_kernel_argv_hex) || return 1
    _service_helper privileged-stop "$expected_argv"
}

service_stop() {
    detect_service_manager
    case "$service_manager" in
    systemd-user)
        local rc=0
        _service_ctl stop || rc=$?
        if _service_privileged_marker_exists; then
            service_sudo_stop || rc=$?
        fi
        return "$rc"
        ;;
    systemd | sysvinit | openrc | runit)
        _service_ctl stop
        ;;
    *)
        /usr/bin/install -d "$(dirname -- "$service_pid_path")" || return 1
        _service_process_with_lock "$service_pid_path" _service_nohup_stop_locked
        ;;
    esac
}

# 原生管理器的判断与 service_state 一致；nohup 不比对启动参数，记录中的进程存活即视为运行。
service_is_active() {
    detect_service_manager
    case "$service_manager" in
    systemd | systemd-user | sysvinit | openrc | runit)
        [ "$(service_state 2>/dev/null)" = running ]
        ;;
    *)
        _service_process_record_pid "$service_pid_path" >/dev/null 2>&1 ||
            _service_privileged_marker_exists
        ;;
    esac
}

# 只读查询输出归一化状态；检测失败不输出状态，避免把查询错误误报为停止。
service_state() {
    detect_service_manager || return 1
    local output rc=0 state
    case "$service_manager" in
    systemd | systemd-user)
        if [ "$service_manager" = systemd-user ] && _service_privileged_marker_exists; then
            printf 'running\n'
            return 0
        fi
        output=$(_service_systemd systemctl is-active "$CLASHCTL_KERNEL" 2>/dev/null) || rc=$?
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
    local record=$1 current expected_argv
    if _service_state_path_absent "$record"; then
        printf 'stopped\n'
        return 0
    fi
    _service_process_record_load "$record" || return 1
    expected_argv=$(_service_kernel_argv_hex) || return 1
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
    _service_process_stat "$_SERVICE_RECORD_PID" || return 1
    if [ "$_SERVICE_PROCESS_STARTTIME" = "$_SERVICE_RECORD_STARTTIME" ]; then
        case $_SERVICE_PROCESS_STATE in
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

# SysV 的自启工具二选一：chkconfig 或 update-rc.d；都没有时返回 127。
_service_sysv_rc() {
    if command -v chkconfig >/dev/null 2>&1; then
        case $1 in
        enable) chkconfig --add "$CLASHCTL_KERNEL" && chkconfig "$CLASHCTL_KERNEL" on ;;
        disable) chkconfig "$CLASHCTL_KERNEL" off ;;
        remove) chkconfig --del "$CLASHCTL_KERNEL" ;;
        esac
    elif command -v update-rc.d >/dev/null 2>&1; then
        case $1 in
        enable) update-rc.d "$CLASHCTL_KERNEL" defaults && update-rc.d "$CLASHCTL_KERNEL" enable ;;
        disable) update-rc.d "$CLASHCTL_KERNEL" disable ;;
        remove) update-rc.d -f "$CLASHCTL_KERNEL" remove ;;
        esac
    else
        return 127
    fi >/dev/null
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
    systemd | systemd-user)
        _service_systemd systemctl enable --quiet "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        _service_sysv_rc enable
        ;;
    openrc)
        rc-update add "$CLASHCTL_KERNEL" default >/dev/null
        ;;
    runit)
        # 自启即监督目录中指向服务目录的符号链接；不覆盖其他来源的同名项。
        local link target
        target=$(_service_target) || return 1
        target=$(dirname -- "$target")
        link=$(_service_runit_enable_link)
        if [ -L "$link" ]; then
            [ "$(readlink -- "$link")" = "$target" ]
            return
        fi
        [ ! -e "$link" ] || return 1
        /usr/bin/install -d "$(dirname -- "$link")" && ln -s -- "$target" "$link"
        ;;
    esac
}

service_disable() {
    detect_service_manager
    case "$service_manager" in
    systemd | systemd-user)
        _service_systemd systemctl disable --quiet "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        _service_sysv_rc disable
        ;;
    openrc)
        rc-update del "$CLASHCTL_KERNEL" default >/dev/null
        ;;
    runit)
        local link target
        link=$(_service_runit_enable_link)
        [ -L "$link" ] || { [ ! -e "$link" ]; return; }
        target=$(_service_target) || return 1
        [ "$(readlink -- "$link")" = "$(dirname -- "$target")" ] || return 1
        command rm -f -- "$link"
        ;;
    esac
}

_service_unregister() {
    [ "$service_manager" != sysvinit ] || _service_sysv_rc remove
}

# systemd 与未托管 TUN 的用户服务写 journal，其余写日志文件。
_service_uses_journal() {
    case "$service_manager" in
    systemd) return 0 ;;
    systemd-user) ! _service_privileged_marker_exists && ! _is_tun_enabled ;;
    *) return 1 ;;
    esac
}

service_log() {
    detect_service_manager
    if _service_uses_journal; then
        _service_systemd journalctl -u "$CLASHCTL_KERNEL" "$@"
    elif [ $# -gt 0 ]; then
        tail "$@" "$service_log_path"
    else
        less "$service_log_path"
    fi
}

service_follow_log() {
    detect_service_manager
    if _service_uses_journal; then
        _service_systemd journalctl -u "$CLASHCTL_KERNEL" -q -f -n 0
    else
        tail -f -n 0 "$service_log_path"
    fi
}

service_log_location() {
    detect_service_manager
    if ! _service_uses_journal; then
        printf '%s\n' "$service_log_path"
    elif [ "$service_manager" = systemd-user ]; then
        printf 'journalctl --user -u %s\n' "$CLASHCTL_KERNEL"
    else
        printf 'journalctl -u %s\n' "$CLASHCTL_KERNEL"
    fi
}

_service_target() {
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

# 将当前管理器的服务模板渲染（替换占位符）到 <dst>；没有对应模板时返回 1
_render_service_unit() {
    local dst=$1 service_src="${CLASHCTL_SRC}/scripts/init/${service_manager}.sh"
    local kernel_desc="$CLASHCTL_KERNEL Daemon, A[nother] Clash Kernel."
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    [ -f "$service_src" ] || return 1

    /usr/bin/install -D -m 0644 "$service_src" "$dst" || return 1
    sed -i \
        -e "s#placeholder_cmd_path#$BIN_KERNEL#g" \
        -e "s#placeholder_cmd_args#$cmd_arg#g" \
        -e "s#placeholder_cmd_full#$BIN_KERNEL $cmd_arg#g" \
        -e "s#placeholder_yq_path#${BIN_YQ:-${CLASHCTL_HOME:-}/bin/yq}#g" \
        -e "s#placeholder_config_path#$CLASH_CONFIG_RUNTIME#g" \
        -e "s#placeholder_log_path#$service_log_path#g" \
        -e "s#placeholder_pid_path#$service_pid_path#g" \
        -e "s#placeholder_kernel_name#$CLASHCTL_KERNEL#g" \
        -e "s#placeholder_kernel_desc#$kernel_desc#g" \
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
    target=$(_service_target) || return 0
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ ! -L "$target" ] && _service_definition_is_owned "$target" && return 0
        _ui_error "同名服务已存在，请先处理后重试：$target"
        return 1
    fi
    case "$service_manager" in
    systemd | systemd-user)
        fragment=$(_service_systemd systemctl show "$CLASHCTL_KERNEL.service" -p FragmentPath --value) || return 1
        [ -z "$fragment" ] || { _ui_error "同名服务已存在：$fragment"; return 1; }
        ;;
    esac
}

_service_daemon_reload() {
    case "$service_manager" in
    systemd | systemd-user) _service_systemd systemctl daemon-reload ;;
    esac
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
    _service_daemon_reload || return 1
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
    _service_daemon_reload
}
