#!/usr/bin/env bash

clashtun() {
    case "${1:-}" in
    -h | --help)
        tun_help
        return 0
        ;;
    esac
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashtun "$@"
        return
    fi
    [ "$#" -le 1 ] || { _ui_error '用法: clashctl tun [on|off]'; return 1; }
    case "${1:-}" in
    on)
        tunon
        ;;
    off)
        tunoff
        ;;
    '')
        tunstatus
        ;;
    *) _ui_error '用法: clashctl tun [on|off]'; return 1 ;;
    esac
}

tunoff() {
    detect_service_manager
    if ! tunstatus >/dev/null; then
        # 用户单元会跳过 TUN 配置；helper 已退出时也必须允许清除配置。
        [ "${service_manager:-}" = systemd-user ] && _is_tun_enabled || return 0
    fi
    if [ "${service_manager:-}" = systemd-user ]; then
        # 用户后端会同时停止 unit 与仍存在的 helper；没有 helper 时无需 sudo。
        service_stop >/dev/null || return 1
    else
        service_sudo_stop >/dev/null || return 1
    fi
    service_is_active >&/dev/null || {
        "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN" || return 1
        _merge_config || return 1
        service_start || return 1
        tunstatus >&/dev/null || _okcat "Tun 模式已关闭"
        return 0
    }
    tunstatus >/dev/null && _failcat "Tun 模式关闭失败"
}

tunon() {
    tunstatus 2>/dev/null && return 0
    _tun_check_device_available || return 1
    service_stop >&/dev/null || return 1
    "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN" || return 1
    _merge_config || return 1
    service_sudo_start || _errorcat 'Tun 模式开启失败' || return
    sleep 1
    if ! tunstatus >&/dev/null && [ "$CLASHCTL_KERNEL" = mihomo ]; then
        "$BIN_YQ" -i '.tun.auto-redirect = false' "$CLASH_CONFIG_MIXIN" || return 1
        _merge_config || return 1
        service_sudo_stop || return 1
        service_sudo_start || return 1
        sleep 1
        tunstatus >&/dev/null || _errorcat 'Tun 模式开启失败, 请检查代理内核日志' || return
    fi
    _okcat "Tun 模式已开启"
}

tun_help() {
    cat <<EOF

- 查看 Tun 状态
  clashctl tun

- 开启 Tun 模式
  clashctl tun on

- 关闭 Tun 模式
  clashctl tun off

EOF
}
