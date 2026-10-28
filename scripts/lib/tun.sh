#!/usr/bin/env bash

# 状态查询不调用会调整端口的 _detect_ext_addr，也不触发 sudo。
_tun_api_state() {
    local controller port host secret
    controller=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME") || return 1
    port=${controller##*:}
    case $port in '' | *[!0-9]*) return 1 ;; esac
    host=${controller%:*}
    case $host in
    '' | '*' | 0.0.0.0) host=127.0.0.1 ;;
    '[::]' | ::) host='[::1]' ;;
    *:*) [[ $host == \[* ]] || host="[$host]" ;;
    esac
    secret=$(_get_secret) || return 1
    curl --silent --fail --noproxy '*' --connect-timeout 1 --max-time 1 \
        -H "Authorization: Bearer $secret" "http://$host:$port/configs" |
        "$BIN_YQ" -p json -e '
          .tun | select(.enable == true or .enable == false)
          | [.enable, (.device // "")] | @tsv' 2>/dev/null
}

# fdinfo 中的 iff 是内核实际持有的 TUN 网卡；无法读取时返回 2。
_tun_pid_owns_device() {
    local pid=$1 device=$2 fd line contents readable=false starttime
    starttime=$(_service_process_starttime "$pid") || return 2
    for fd in "/proc/$pid/fdinfo/"*; do
        contents=$(cat -- "$fd" 2>/dev/null) || continue
        readable=true
        while IFS= read -r line; do
            if [ "$line" = "iff:"$'\t'"$device" ]; then
                [ "$(_service_process_starttime "$pid")" = "$starttime" ]
                return
            fi
        done <<<"$contents"
    done
    [ "$readable" = true ] || return 2
    return 1
}

# 返回 0=已启用、1=关闭、2=无法检测，并保存实际设备名。
# status 传入已查询的 PID；无参数时沿用 tunstatus 的本地配置与载波兜底规则。
_tun_probe() {
    local pid=${1:-} api_state enabled='' device='' link ownership=2 link_rc=0
    _TUN_DEVICE=''
    if api_state=$(_tun_api_state); then
        IFS=$'\t' read -r enabled device <<<"$api_state"
        [ "$enabled" != false ] || return 1
    elif [ "$#" -eq 0 ]; then
        _is_tun_enabled || return 1
    fi
    [ -n "$device" ] || device=$("$BIN_YQ" '.tun.device // "Meta"' "$CLASH_CONFIG_RUNTIME") || device=''
    [ -n "$device" ] || device=Meta
    _TUN_DEVICE=$device
    # 网卡名和查询结果只作为终端文字显示，不接收控制字符。
    if [ "$#" -gt 0 ] && [[ $device == *[[:cntrl:]]* ]]; then
        return 2
    fi
    command -v ip >/dev/null 2>&1 || return 2
    link=$(ip -o link show dev "$device" 2>/dev/null) || link_rc=$?
    if [ "$link_rc" -ne 0 ] || [[ ! $link =~ \<([^\>]*,)?UP(,[^\>]*)?\> ]]; then
        [ "$enabled" = true ] && [ "$link_rc" -le 1 ] && return 1
        return 2
    fi
    if [ "$#" -eq 0 ]; then
        pid=$(service_main_pid 2>/dev/null) || pid=''
        [ -n "$pid" ] || ! _is_root || return 1
    fi
    if [[ $pid =~ ^[0-9]+$ ]]; then
        ownership=0
        _tun_pid_owns_device "$pid" "$device" || ownership=$?
    fi
    [ "$ownership" -ne 0 ] || return 0
    # 普通用户可能不能读特权进程的 fdinfo；此时同时验证 API 与网卡载波。
    if [ "$ownership" -eq 2 ] && [ "$enabled" = true ] &&
        [[ $link == *LOWER_UP* && $link != *NO-CARRIER* ]] &&
        { [ "$#" -eq 0 ] || ! _is_root; }; then
        return 0
    fi
    [ "$ownership" -eq 1 ] && [ "$enabled" = true ] && return 1
    return 2
}

_tun_is_active() {
    service_is_active >/dev/null 2>&1 || return 1
    _tun_probe || return 1
}

_tun_check_device_available() {
    local device pid ownership=2 enabled active_device
    device=$("$BIN_YQ" '.tun.device // ""' "$CLASH_CONFIG_MIXIN") || return 1
    [ -n "$device" ] || device=$("$BIN_YQ" '.tun.device // "Meta"' "$CLASH_CONFIG_BASE")
    [ -n "$device" ] || device=Meta
    ip link show dev "$device" >/dev/null 2>&1 || return 0
    if pid=$(service_main_pid 2>/dev/null); then
        ownership=0
        _tun_pid_owns_device "$pid" "$device" || ownership=$?
        [ "$ownership" -ne 0 ] || return 0
    fi
    if ! _is_root && [ "$ownership" -eq 2 ] &&
        IFS=$'\t' read -r enabled active_device < <(_tun_api_state) &&
        [ "$enabled" = true ] && [ "$active_device" = "$device" ]; then
        return 0
    fi
    _ui_error "Tun 网卡 $device 已存在，无法确认属于本次安装"
    _ui_detail '处理' '修改 Mixin 中的 tun.device 后重试'
    return 1
}
