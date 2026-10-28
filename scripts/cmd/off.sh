#!/usr/bin/env bash

clashoff() {
    [ "$#" -le 1 ] || { _ui_fail '用法: clashctl off [--stop | --help]'; return 1; }
    case "${1:-}" in
    -h | --help)
        off_help
        return
        ;;
    '' | --stop) ;;
    *) _ui_fail '用法: clashctl off [--stop | --help]'; return 1 ;;
    esac
    unset_system_proxy
    _ui_ok_out "当前终端代理已关闭"
    if [ "${1:-}" = --stop ]; then
        clashstop
    fi
}

unset_system_proxy() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
}

off_help() {
    cat <<EOF

clashctl off - 关闭当前终端代理，默认保留内核运行

Usage:
  clashctl off [OPTIONS]

Options:
      --stop  同时停止内核
  -h, --help  显示帮助信息

停止内核失败时返回非零状态，当前终端代理仍保持关闭。

EOF
}
