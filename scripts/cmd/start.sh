#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

clashstart() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashctl start\n启动内核，不修改当前终端代理环境；已运行时保持原状。\n'
        return 0 ;;
    '') ;;
    *) _ui_fail '用法: clashctl start'; return 1 ;;
    esac
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashstart
        return
    fi
    if service_is_active >&/dev/null; then
        # on 会报告终端代理状态；独立执行 start 时仍显示内核状态。
        [ "${_CLASHCTL_START_FROM_ON:-}" = 1 ] || _ui_ok_out "$CLASHCTL_KERNEL 已运行"
        return 0
    fi
    if [ ! -f "$BIN_KERNEL" ] || [ ! -x "$BIN_KERNEL" ]; then
        _ui_error "代理内核未安装（$CLASHCTL_KERNEL）"
        _ui_detail '修复' "CLASHCTL_HOME=$CLASHCTL_HOME bash $CLASHCTL_HOME/install.sh"
        return 1
    fi
    _merge_config || return 1
    _detect_proxy_port || return 1
    _detect_ext_addr || return 1
    service_start || return 1
    service_is_active >&/dev/null || {
        _ui_fail "$CLASHCTL_KERNEL 启动失败"
        return 1
    }
    service_enable || return 1
    _ui_ok_out "$CLASHCTL_KERNEL 已启动"
}
