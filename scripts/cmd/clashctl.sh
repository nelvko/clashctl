#!/usr/bin/env bash

# 已发布旧 update 先替换源码再加载这里；业务库读取数据前由安装模块完成转换。
if [ "${CLASHCTL_INSTALL_RUNNING:-}" != 1 ] &&
    { [ ! -f "$CLASHCTL_HOME/.clashctl-format" ] || [ -L "$CLASHCTL_HOME/.clashctl-format" ] ||
        [ "$(cat -- "$CLASHCTL_HOME/.clashctl-format")" != 1 ]; }; then
    if ! CLASHCTL_HOME="$CLASHCTL_HOME" bash -c '
        . "$CLASHCTL_HOME/scripts/install-migration.sh" && _install_bridge
    '; then
        . "$CLASHCTL_HOME/scripts/install-migration.sh" && _install_recovery_shell
        printf '安装迁移未完成；可使用 status、log、off、stop 诊断，或重新运行安装器。\n' >&2
        return 1
    fi
fi

# 首次初始化时 .env 尚未创建
[ -f "$CLASHCTL_HOME"/.env ] && . "$CLASHCTL_HOME"/.env

for lib_file in "$CLASHCTL_HOME"/scripts/lib/*.sh; do
    # 旧更新器要求保留的空占位文件无需加载。
    [ "${lib_file##*/}" != install-maintenance.sh ] || continue
    # shellcheck disable=SC1090  # 运行时按安装目录加载公共库
    . "$lib_file"
done

for cmd_file in "$CLASHCTL_HOME"/scripts/cmd/*.sh; do
    case "$cmd_file" in *clashctl.*) continue ;; esac
    # shellcheck disable=SC1090  # 运行时按安装目录加载子命令
    . "$cmd_file"
done

clashctl() {
    local sub_cmd
    sub_cmd=${1:-help}
    shift

    case $sub_cmd in
    -h | --help | help) sub_cmd=help ;;
    -v | --version) sub_cmd=version ;;
    -*)
        _ui_fail "Unknown option: $sub_cmd"
        _ui_fail "Use 'clashctl help' for usage information."
        return 1
        ;;
    esac

    local target="clash${sub_cmd}"
    typeset -f "$target" >/dev/null 2>&1 || {
        _ui_fail "Unknown subcommand: $sub_cmd"
        _ui_fail "Use 'clashctl help' for usage information."
        return 1
    }

    "$target" "$@"
}
