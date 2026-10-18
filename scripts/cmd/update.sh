#!/usr/bin/env bash

clashupdate() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashupdate\n更新 clashctl 的脚本与资源，保留用户配置和内核。来源由 .env 中 CLASHCTL_UPDATE_BRANCH 和 GH_PROXY 配置。\n'
        return 0 ;;
    '') ;;
    *) _ui_error '用法: clashupdate'; return 1 ;;
    esac
    # 文件更新使用 Bash 的数组和锁；非 Bash 解释器只负责加载更新后的命令。
    if _clashctl_in_bash; then
        _update_scripts
    else
        _clashctl_run_in_bash _update_scripts
    fi || return 1
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || {
        _ui_error 'clashctl 已更新，但当前 Shell 加载失败，请重开终端'
        return 1
    }
    _ui_ok_out '更新完成，当前 Shell 已加载新版本'
}

_update_scripts() (
    set -o pipefail
    local branch=${CLASHCTL_UPDATE_BRANCH:-master} url target dirty method work='' stage rc install_source
    trap '
        rc=$?
        trap - EXIT
        trap "" INT TERM HUP
        [ -z "$work" ] || [ -f "$work/keep" ] || rm -rf -- "$work"
        operation_lock_release || true
        exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    operation_lock_acquire || return 1
    [ -f "$CLASHCTL_HOME/.env" ] || [ "${CLASHCTL_INSTALL_RUNNING:-}" = 1 ] || { _ui_error '未找到安装配置'; return 1; }
    # 复用安装入口中的源码下载与检查，不执行初始化。
    # shellcheck source=/dev/null  # 只加载函数，安装入口有执行保护。
    install_source=${CLASHCTL_INSTALL_SOURCE:-$CLASHCTL_HOME}
    # shellcheck source=/dev/null
    . "$install_source/install.sh" || return 1
    method=$(_install_method "$(cd -- "$CLASHCTL_HOME" && pwd -P)") || {
        _ui_error '缺少匹配的安装标记，已停止更新'
        return 1
    }
    work=$(mktemp -d "${CLASHCTL_HOME}.update.XXXXXX") || return 1
    stage="$work/source"
    mkdir "$stage" || return 1
    _ui_step "下载更新：$branch"
    if [ "$method" = git ]; then
        if ! command -v git >/dev/null 2>&1 || [ ! -d "$CLASHCTL_HOME/.git" ] || [ -L "$CLASHCTL_HOME/.git" ]; then
            _ui_error '此安装使用 Git，请先恢复 git 命令或仓库；不会自动切换安装类型'
            return 1
        fi
        dirty=$(git -C "$CLASHCTL_HOME" status --porcelain --untracked-files=no) || return 1
        [ -z "$dirty" ] || { _ui_error '安装目录存在本地代码修改，请提交或暂存后重试'; return 1; }
        url=$(gh_proxy_url 'https://github.com/nelvko/clashctl.git')
        git -C "$CLASHCTL_HOME" -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
            fetch --depth 1 -- "$url" "$branch" || return 1
        target=$(git -C "$CLASHCTL_HOME" rev-parse FETCH_HEAD) || return 1
        git -C "$CLASHCTL_HOME" archive "$target" | tar -x -C "$stage" || return 1
    else
        if [ -e "$CLASHCTL_HOME/.git" ] || [ -L "$CLASHCTL_HOME/.git" ]; then
            _ui_error '压缩包安装目录出现 Git 元数据，已停止更新'
            return 1
        fi
        _source_archive "$stage" "$branch" "${GH_PROXY:-}" || return 1
    fi
    [ ! -e "$stage/.git" ] && [ ! -L "$stage/.git" ] || return 1
    _source_validate "$stage" || return 1
    if [ "$method" = git ]; then
        _update_git_checkout "$target" "$work" || return 1
    else
        _update_archive "$stage" "$work"
    fi
)

# 工作树已确认干净；只回退程序文件，保留未跟踪的用户文件。
_update_git_checkout() (
    local target=$1 work=$2 previous previous_ref file dirty failed=false
    local started=false complete=false rc
    local -a added_files=()
    previous=$(git -C "$CLASHCTL_HOME" rev-parse HEAD) || return 1
    previous_ref=$(git -C "$CLASHCTL_HOME" symbolic-ref --quiet HEAD) || previous_ref=''
    git -C "$CLASHCTL_HOME" ls-tree -rz --name-only "$target" >"$work/git-target-files" || return 1
    while IFS= read -r -d '' file; do
        _update_path_safe "$file" || { _ui_error "更新路径无法安全使用：$file"; return 1; }
        if ! git -C "$CLASHCTL_HOME" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
            if [ -e "$CLASHCTL_HOME/$file" ] || [ -L "$CLASHCTL_HOME/$file" ]; then
                _ui_error "更新会覆盖未跟踪文件，已停止更新：$file"
                return 1
            fi
            added_files+=("$file")
        fi
    done <"$work/git-target-files"
    printf '%s\n%s\n' "$previous" "$previous_ref" >"$work/git-previous" || return 1
    trap '
        rc=$?
        trap - EXIT
        trap "" INT TERM HUP
        if [ "$started" = true ] && [ "$complete" = false ]; then
            # checkout 可能只写了新文件，尚未更新索引；reset 不一定会清理它们。
            for file in "${added_files[@]}"; do
                rm -f -- "$CLASHCTL_HOME/$file" || failed=true
            done
            git -C "$CLASHCTL_HOME" reset --hard -q "$previous" || failed=true
            if [ -n "$previous_ref" ]; then
                git -C "$CLASHCTL_HOME" symbolic-ref HEAD "$previous_ref" || failed=true
            fi
            dirty=$(git -C "$CLASHCTL_HOME" status --porcelain --untracked-files=no) || failed=true
            [ -z "$dirty" ] || failed=true
            [ "$(git -C "$CLASHCTL_HOME" rev-parse HEAD)" = "$previous" ] || failed=true
            if [ "$failed" = true ]; then
                touch "$work/keep"
                _ui_error "更新失败且无法完整恢复原版本，请保留现场检查"
                _ui_detail "恢复信息" "$work/git-previous"
            else
                _ui_error "更新未完成，已恢复原版本"
            fi
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    started=true
    git -C "$CLASHCTL_HOME" checkout --detach -q "$target" || return 1
    complete=true
)

# 检查整个目标路径，防止通过目录软链接覆盖安装目录以外的文件。
_update_path_safe() {
    local path=$1
    while [ "$path" != . ]; do
        [ ! -L "$CLASHCTL_HOME/$path" ] || return 1
        path=$(dirname -- "$path")
        [ ! -e "$CLASHCTL_HOME/$path" ] || [ -d "$CLASHCTL_HOME/$path" ] || return 1
    done
}

_update_archive() (
    set -o pipefail
    local stage=$1 work=$2 hash file started=false complete=false failed=false rc
    local manifest="$CLASHCTL_HOME/.clashctl-files"
    local -a old_files=() new_files=()
    local -A old_set=() new_set=()
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        _ui_error '源码文件清单缺失，已停止更新'; return 1
    fi
    while read -r hash file; do
        if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]] || [[ "$file" != ./* ]] ||
            ! _source_path_allowed "$file" || ! _update_path_safe "$file" || [ ! -f "$CLASHCTL_HOME/$file" ]; then
            _ui_error '源码文件清单或安装路径无效'; return 1
        fi
        old_files+=("$file")
        old_set[$file]=1
    done <"$manifest"
    [ "${#old_files[@]}" -gt 0 ] || return 1
    (cd -- "$CLASHCTL_HOME" && sha256sum --status -c .clashctl-files) || {
        _ui_error '安装目录存在本地代码修改或缺失文件，请恢复后重试'
        return 1
    }
    _source_manifest "$stage" >"$stage/.clashctl-files" || return 1
    while read -r hash file; do
        _update_path_safe "$file" || { _ui_error "更新路径无法安全使用：$file"; return 1; }
        if [ -e "$CLASHCTL_HOME/$file" ]; then
            if [ ! -f "$CLASHCTL_HOME/$file" ] || [ "${old_set[$file]:-}" != 1 ]; then
                _ui_error "更新会覆盖非托管文件：$file"
                return 1
            fi
        fi
        new_files+=("$file")
        new_set[$file]=1
    done <"$stage/.clashctl-files"
    tar -cf "$work/previous.tar" -C "$CLASHCTL_HOME" -- "${old_files[@]}" .clashctl-files || return 1
    # 更新失败只恢复程序文件；订阅、组件和运行数据始终不参与替换。
    trap '
        rc=$?
        trap - EXIT
        trap "" INT TERM HUP
        if [ "$started" = true ] && [ "$complete" = false ]; then
            for file in "${new_files[@]}"; do
                [ "${old_set[$file]:-}" = 1 ] || rm -f -- "$CLASHCTL_HOME/$file" || failed=true
            done
            tar -xf "$work/previous.tar" -C "$CLASHCTL_HOME" || failed=true
            if [ "$failed" = true ]; then
                touch "$work/keep"
                _ui_error "恢复源码失败，备份保留在 $work/previous.tar"
            else
                _ui_error "更新未完成，原程序文件已恢复"
            fi
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    started=true
    tar -cf - -C "$stage" -- "${new_files[@]}" .clashctl-files |
        tar -xf - -C "$CLASHCTL_HOME" || return 1
    for file in "${old_files[@]}"; do
        [ "${new_set[$file]:-}" = 1 ] || rm -f -- "$CLASHCTL_HOME/$file" || return 1
    done
    complete=true
)
