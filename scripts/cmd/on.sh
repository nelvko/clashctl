#!/usr/bin/env bash

clashon() {
    local _CLASHCTL_START_FROM_ON=1
    [ "$#" -le 1 ] || { _ui_fail '用法: clashctl on [--help]'; return 1; }
    case "${1:-}" in
    -h | --help)
        on_help
        return
        ;;
    '') clashstart || return ;;
    *) _ui_fail '用法: clashctl on [--help]'; return 1 ;;
    esac
    set_system_proxy || return 1
    _ui_ok_out "当前终端代理已启用"
}

on_help() {
    cat <<EOF

clashctl on - 启用当前终端代理，内核未运行时自动启动

Usage:
  clashctl on [OPTIONS]

Options:
  -h, --help  显示帮助信息

EOF
}

set_system_proxy() {
    local http_address socks_address no_proxy_addr="localhost,127.0.0.1,::1"
    _proxy_addresses || {
        _ui_error '无法读取运行配置中的代理连接信息'
        return 1
    }
    if [ -z "$http_address" ] || [ -z "$socks_address" ]; then
        _ui_error '运行配置缺少可用的 HTTP 或 SOCKS 代理端口'
        return 1
    fi

    export http_proxy=$http_address
    export HTTP_PROXY=$http_proxy

    export https_proxy=$http_proxy
    export HTTPS_PROXY=$https_proxy

    export all_proxy=$socks_address
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy
    return 0
}

_dump_proxy_env_fish() {
    local v val
    for v in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
        val=${!v}
        [ -z "$val" ] && continue
        printf 'set -gx %s %s\n' "$v" "$(_fish_quote "$val")"
    done
}
