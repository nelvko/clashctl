#!/usr/bin/env bash

clashversion() {
    if [ "$#" -gt 0 ]; then
        if [ "$#" -eq 1 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then
            printf '用法: clashctl version（或 clashctl -v / --version）\n'
            return 0
        fi
        _ui_error '用法: clashctl version（或 clashctl -v / --version）'
        return 1
    fi

    local revision
    # 归档安装可能位于另一个 Git 仓库内，不能读取父目录的提交号。
    if [ -e "$CLASHCTL_HOME/.git" ] &&
        revision=$(git -C "$CLASHCTL_HOME" rev-parse --short HEAD 2>/dev/null); then
        printf 'clashctl %s\n' "$revision"
    else
        printf 'clashctl（无 Git 版本信息）\n'
    fi

    if [ ! -f "$BIN_KERNEL" ] || [ ! -x "$BIN_KERNEL" ]; then
        printf '%s：未安装\n' "${CLASHCTL_KERNEL:-mihomo}"
        return 0
    fi
    local kernel_info kernel_version
    kernel_info=$("$BIN_KERNEL" -v) || return
    kernel_version=$(_kernel_version "$kernel_info") || {
        _ui_error '无法读取内核版本信息'
        return 1
    }
    printf '%s %s\n' "${CLASHCTL_KERNEL:-mihomo}" "$kernel_version"
}

# 无参数时查询内核；也可传入已读取的 banner，以区分查询失败与格式错误。
_kernel_version() {
    local kernel_info kernel_version
    if [ "$#" -eq 0 ]; then
        kernel_info=$("$BIN_KERNEL" -v) || return
    else
        kernel_info=$1
    fi
    kernel_info=${kernel_info%%$'\n'*}
    case $kernel_info in
    'Mihomo Meta '* | 'Clash Meta '*) kernel_version=${kernel_info#* Meta } ;;
    'Mihomo '*) kernel_version=${kernel_info#* } ;;
    *) kernel_version='' ;;
    esac
    kernel_version=${kernel_version%% *}
    [ -n "$kernel_version" ] || return 1
    printf '%s\n' "$kernel_version"
}
