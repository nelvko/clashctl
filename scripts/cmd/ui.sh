#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

clashui() {
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashui
        return
    fi
    [ -f "$CLASH_RESOURCES_DIR/dist/index.html" ] || _ci_provision ui || return 1
    _detect_ext_addr
    service_is_active >&/dev/null || service_start >/dev/null
    service_is_active >&/dev/null || _errorcat "无法启动服务，请检查日志" || return

    local query_url='https://api64.ipify.org'
    local public_ip
    public_ip=$(curl -s --noproxy "*" --location --max-time 2 "$query_url")
    local public_address="http://${public_ip:-公网}:${EXT_PORT}/ui"

    local local_ip=$EXT_IP
    local local_address="http://${local_ip}:${EXT_PORT}/ui"

    local common_address='http://board.zash.run.place'
    
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                  Web 控制台                   ║\n"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$EXT_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️ 公共：%-31s  ║\n" "$common_address"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}
