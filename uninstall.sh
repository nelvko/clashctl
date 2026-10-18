#!/usr/bin/env bash

# 确认卸载前尚未加载安装配置，仍需提供相同的前缀和颜色规则。
_uninstall_ui_log() {
    local level=$1 msg=$2 fd=${3:-2} prefix color colored=false
    if declare -F _install_ui_emit_fd >/dev/null 2>&1; then
        _install_ui_emit_fd "$fd" "$level" "$msg"
        return
    fi
    case $level in
    step) prefix='[STEP]'; color=36 ;;
    ok) prefix='[ OK ]'; color=32 ;;
    warn) prefix='[WARN]'; color=33 ;;
    error | fail) prefix='[FAIL]'; color=31 ;;
    *) prefix='[INFO]'; color=36 ;;
    esac
    if [ "${NO_COLOR+x}" != x ]; then
        case ${CLASHCTL_COLOR:-auto} in
        always) colored=true ;;
        never) ;;
        *)
            if [ "${CI+x}" != x ] && [ "${TERM:-dumb}" != dumb ] && [ -t "$fd" ]; then
                colored=true
            fi
            ;;
        esac
    fi
    if [ "$colored" = true ]; then
        if [ "$level" = step ]; then
            printf '\033[1;%sm%s %s\033[0m\n' "$color" "$prefix" "$msg" >&"$fd"
        else
            printf '\033[1;%sm%s\033[0m %s\n' "$color" "$prefix" "$msg" >&"$fd"
        fi
    else
        printf '%s %s\n' "$prefix" "$msg" >&"$fd"
    fi
}

main() (
    _install_ui_output() { _uninstall_ui_log "$2" "$3" "$1"; }
    local answer='' initialized=true script_home install_home marker cache recovery_home
    local caller_shell proxy_present=false rc=0
    [ -z "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ] || proxy_present=true
    caller_shell=$(readlink "/proc/$PPID/exe" 2>/dev/null) || caller_shell=${SHELL:-}
    caller_shell=${caller_shell##*/}
    case $caller_shell in
    bash | zsh | fish) ;;
    *) caller_shell=${SHELL:-}; caller_shell=${caller_shell##*/} ;;
    esac
    [ "$#" -le 1 ] || { printf '用法: bash uninstall.sh [--yes]\n' >&2; return 1; }
    case ${1:-} in
    -y | --yes) answer=y ;;
    -h | --help)
        printf '用法: bash uninstall.sh [--yes]\n安装目录：脚本所在的安装目录优先，否则使用 CLASHCTL_HOME 或 ~/.clashctl。\n停止内核，移除服务、Shell 引导和安装目录。\n订阅、自定义配置、内核及日志都会删除，请提前备份。\n--yes  跳过确认，不跳过安装归属与停止检查。\n'
        return 0 ;;
    '') ;;
    *) printf '未知参数\n' >&2; return 1 ;;
    esac
    script_home="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
    # 源码入口只定位安装；存在标记时必须校验本目录，不绕过损坏或复制的标记。
    if [ -e "$script_home/.clashctl-install" ] || [ -L "$script_home/.clashctl-install" ]; then
        install_home=$script_home
    else
        install_home=${CLASHCTL_HOME:-$HOME/.clashctl}
    fi
    if [ ! -d "$install_home" ]; then
        printf '未找到 clashctl 安装：%s\n' "$install_home" >&2
        return 1
    fi
    install_home=$(cd -- "$install_home" && pwd -P) || return 1
    export CLASHCTL_HOME="$install_home"
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    if [ ! -f "$CLASHCTL_HOME/install.sh" ] || [ ! -f "$CLASHCTL_HOME/scripts/preflight.sh" ] ||
        [ "$CLASHCTL_HOME" = / ] || [ "$CLASHCTL_HOME" = "$(cd -- "$HOME" && pwd -P)" ]; then
        printf '无效的 clashctl 安装目录：%s\n' "$install_home" >&2; return 1
    fi
    # 安装标记不依赖 Git；严格匹配物理路径，复制后的目录不能卸载。
    marker=''
    if [ -f "$install_home/.clashctl-install" ] && [ ! -L "$install_home/.clashctl-install" ]; then
        marker=$(cat -- "$install_home/.clashctl-install") || return 1
    fi
    case "$marker" in
    "$install_home"$'\ngit' | "$install_home"$'\narchive') ;;
    *)
        printf '安装标记不匹配，已取消卸载：%s\n' "$install_home" >&2
        return 1 ;;
    esac
    # 校验兼容边界；锁和卸载操作都使用目标安装中的同一套库。
    . "$script_home/install.sh" || return 1
    _source_validate "$install_home" installed >/dev/null 2>&1 || {
        _install_reject_legacy "$install_home"
        return 1
    }
    # shellcheck source=/dev/null
    . "$install_home/scripts/lib/operation-lock.sh" || return 1
    trap 'rc=$?; trap - EXIT; trap "" INT TERM HUP; operation_lock_release || true; exit "$rc"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    operation_lock_acquire || return 1
    if [ ! -e "$install_home/.env" ] && [ ! -L "$install_home/.env" ]; then
        if [ -f "$install_home/.clashctl-uninitialized" ] &&
            [ ! -L "$install_home/.clashctl-uninitialized" ] &&
            [ "$(cat -- "$install_home/.clashctl-uninitialized")" = "$install_home" ]; then
            initialized=false
        else
            printf '.env 缺失，无法确认服务状态，已保留安装目录：%s\n请从备份恢复 .env 后重试；不要直接删除目录。\n' "$install_home" >&2
            return 1
        fi
    fi
    _uninstall_ui_log step '卸载 clashctl'
    printf '       安装目录: %s\n       将删除订阅、自定义配置、程序和日志\n' "$install_home" >&2
    if [ "$answer" != y ]; then
        printf '       继续卸载？[y/N] ' >&2
        IFS= read -r answer || {
            printf '\n' >&2
            _uninstall_ui_log warn '未收到确认，已取消卸载；无人值守卸载请显式使用 --yes'
            return 1
        }
        [ -t 0 ] || printf '\n' >&2
        if [[ $answer != y && $answer != Y ]]; then
            _uninstall_ui_log info '已取消卸载'
            return 1
        fi
    fi
    if [ "$initialized" = true ]; then
        # 必须从本次安装的 .env 读取内核，不能沿用调用终端的安装状态。
        if [ ! -f "$CLASHCTL_HOME/.env" ] || [ ! -r "$CLASHCTL_HOME/.env" ]; then
            printf '.env 无法读取，已保留安装目录\n' >&2; return 1
        fi
        unset CLASHCTL_KERNEL INIT_TYPE
        . "$install_home/scripts/preflight.sh" || {
            _uninstall_ui_log error '加载安装配置失败，卸载中止，已保留安装目录'
            return 1
        }
        if [ "$CLASHCTL_HOME" != "$install_home" ] || [ "$CLASHCTL_SRC" != "$install_home" ]; then
            _install_ui_error '.env 改写了安装路径，已停止卸载'
            return 1
        fi
        case ${CLASHCTL_KERNEL:-} in
        mihomo | clash) ;;
        *) _install_ui_error '.env 中缺少有效的内核信息，已保留安装目录'; return 1 ;;
        esac
        _uninstall_ui_log info '停止内核并移除服务'
        uninstall_service || {
            _uninstall_ui_log error '停止内核或移除服务失败，卸载中止，已保留安装目录'
            return 1
        }
        _uninstall_ui_log info '清理 Shell 配置'
        revoke_rc || {
            _uninstall_ui_log error '清理 Shell 配置失败，卸载中止，已保留安装目录'
            return 1
        }
    fi
    _uninstall_ui_log info '删除安装目录'
    command rm -rf -- "$install_home" || {
        _uninstall_ui_log error '删除安装目录失败，请检查残留文件'
        return 1
    }
    _uninstall_ui_log ok '卸载完成' 1
    recovery_home="${install_home%/*}/.clashctl-backups"
    if [ -d "$recovery_home" ] && [ ! -L "$recovery_home" ] &&
        [ -n "$(find "$recovery_home" -mindepth 2 -maxdepth 2 -type d -print -quit 2>/dev/null)" ]; then
        _uninstall_ui_log info "恢复资料已保留，确认无需回退后可手动清理：$recovery_home" 1
    fi
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/clashctl/proxy.fish"
    if [ -e "$cache" ] || [ -L "$cache" ]; then
        _uninstall_ui_log warn "保留了无法确认安装归属的 Fish 代理缓存，请检查后手动清理：$cache" 1
    fi
    if [ "$proxy_present" = true ]; then
        local proxy_vars='http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY'
        printf '\n'
        case $caller_shell in
        bash | zsh)
            printf '清除当前终端代理（%s）:\n  unset %s\n' "$caller_shell" "$proxy_vars"
            ;;
        fish)
            printf '清除当前终端代理（fish）:\n  set -e %s\n' "$proxy_vars"
            ;;
        *)
            printf '清除当前终端代理，请按所用 Shell 执行:\n  bash/zsh: unset %s\n  fish: set -e %s\n' "$proxy_vars" "$proxy_vars"
            ;;
        esac
    fi
)

main "$@"
