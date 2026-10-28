#!/usr/bin/env bash

# 解释器归一化：非 Bash（zsh 等）无法安全执行 lib/ 与 cmd/ 中的实现
# （read -r -a、${!arr[@]}、${s:i:1}、$BASHPID、$BASH_SOURCE 均为 Bash 语法）。
# 由各 clash* 入口函数调用，clashctl <sub> 与直接调用走同一条路径。
# on/off/help/version 留在当前 Shell；update 在 Bash 中更新后再重载命令。
_clashctl_in_bash() {
    [ -n "${BASH_VERSION:-}" ]
}

# 在 Bash 子进程中执行 clash* 函数，并原样返回其退出码。
# 子进程隔离：不改动当前 Shell 的变量 / PATH / setopt，交互式命令的 tty 与
# 退出码照常传递。调用方约定：仅在 ! _clashctl_in_bash 时调用本函数。
_clashctl_run_in_bash() (
    local func=$1
    shift
    command -v bash >/dev/null 2>&1 || {
        _ui_error '未找到 Bash，请安装后重试'
        return 127
    }
    # status 读取当前终端环境；只在子进程导出这些值，不改变父 Shell
    # 或其他命令使用代理变量的方式。
    if [ "$func" = clashstatus ]; then
        export http_proxy="${http_proxy:-}" HTTP_PROXY="${HTTP_PROXY:-}" \
            https_proxy="${https_proxy:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
            all_proxy="${all_proxy:-}" ALL_PROXY="${ALL_PROXY:-}"
    fi
    # _CLASHCTL_START_FROM_ON 是 on → start 的消息抑制标记，随子进程传递，
    # 保证 clashctl on 在非 Bash 解释器下与 Bash 下行为一致。
    CLASHCTL_HOME="$CLASHCTL_HOME" COLUMNS="${COLUMNS:-}" \
        _CLASHCTL_START_FROM_ON="${_CLASHCTL_START_FROM_ON:-}" \
        bash -c '
        unset ZSH_VERSION
        . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && "$@"
    ' -- "$func" "$@"
)
