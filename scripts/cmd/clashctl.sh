#!/usr/bin/env bash

# 安装器完成迁移后才开放命令；旧更新器只替换脚本时也走同一个入口。
_clashctl_migration_required() {
    printf 'clashctl 需要先完成安装迁移，请执行：\n  bash "%s/install.sh" --home "%s"\n' "$CLASHCTL_HOME" "$CLASHCTL_HOME" >&2
    return 1
}
if [ "${CLASHCTL_INSTALL_RUNNING:-}" != 1 ] &&
    { [ ! -f "$CLASHCTL_HOME/.clashctl-format" ] || [ -L "$CLASHCTL_HOME/.clashctl-format" ] ||
        [ "$(cat -- "$CLASHCTL_HOME/.clashctl-format")" != 1 ]; }; then
    # 覆盖当前 Shell 中已加载的旧入口，避免旧 updater 更新后仍调用旧函数。
    for cmd_name in clashctl clashon clashoff clashstart clashstop clashstatus clashui clashsub clashnode clashtun clashmixin clashsecret clashlog clashupgrade clashupdate clashversion clashhelp; do
        eval "$cmd_name() { _clashctl_migration_required; }"
    done
    unset cmd_name
    _clashctl_migration_required || true
    return 0
fi

# 首次初始化时 .env 尚未创建
[ -f "$CLASHCTL_HOME"/.env ] && . "$CLASHCTL_HOME"/.env

for lib_file in "$CLASHCTL_HOME"/scripts/lib/*.sh; do
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
