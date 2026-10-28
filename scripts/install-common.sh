#!/usr/bin/env bash
# 安装与更新共用的源码操作；source 只定义函数。

_install_method() {
    local home=$1 marker
    if [ -f "$home/.clashctl-install" ] && [ ! -L "$home/.clashctl-install" ]; then
        marker=$(cat -- "$home/.clashctl-install") || return 1
        case "$marker" in
        "$home"$'\ngit') printf 'git\n'; return 0 ;;
        "$home"$'\narchive') printf 'archive\n'; return 0 ;;
        '') printf '安装标记为空，无法识别安装类型，也不能卸载：%s；请备份后重新安装\n' "$home/.clashctl-install" >&2; return 1 ;;
        esac
        printf '安装标记与当前路径不匹配，无法更新或卸载：%s\n' "$home/.clashctl-install" >&2
    fi
    return 1
}

# 自举取得源码后选定锁实现；安装器持锁覆盖提交、迁移与失败恢复。
_install_lock() {
    CLASHCTL_INSTALL_LOCK_LIB="$1/scripts/lib/operation-lock.sh"
    _install_restore_operation_lock || return 1
    operation_lock_acquire
}

# preflight 或旧加载器可能重定义锁函数，恢复本次选定的实现。
_install_restore_operation_lock() {
    [ -n "${CLASHCTL_INSTALL_LOCK_LIB:-}" ] || return 0
    grep -q '^_directory_lock_acquire()' "$CLASHCTL_INSTALL_LOCK_LIB" 2>/dev/null || {
        printf '本次源码不支持目录操作锁，请使用更新的安装源码或分支后重试：%s\n' "$CLASHCTL_INSTALL_LOCK_LIB" >&2
        return 1
    }
    # shellcheck source=/dev/null
    . "$CLASHCTL_INSTALL_LOCK_LIB"
}

# 只接管身份、归属和脚本布局均可验证的已有安装。
_install_existing_kind() {
    local home=$1 marker owner mode path unsafe
    local -a required
    [ -d "$home" ] && [ ! -L "$home" ] || return 1
    owner=$(stat -c %u -- "$home") || return 1
    mode=$(stat -c %a -- "$home") || return 1
    [ "$owner" = "$(id -u)" ] && [ $((8#$mode & 0022)) -eq 0 ] || return 1
    if [ -e "$home/.clashctl-install" ] || [ -L "$home/.clashctl-install" ] ||
        [ -e "$home/.clashctl-installation" ] || [ -L "$home/.clashctl-installation" ]; then
        required=(install.sh scripts/preflight.sh scripts/lib/common.sh)
    else
        # master 的运行目录只复制卸载器和运行脚本，不含安装器、preflight。
        required=(uninstall.sh scripts/cmd/clashctl.sh scripts/lib/common.sh scripts/lib/service.sh)
    fi
    for path in "${required[@]}"; do
        [ -f "$home/$path" ] && [ ! -L "$home/$path" ] || return 1
        [ "$(stat -c %u -- "$home/$path")" = "$owner" ] || return 1
        mode=$(stat -c %a -- "$home/$path") || return 1
        [ $((8#$mode & 0022)) -eq 0 ] || return 1
    done
    unsafe=$(find "$home/scripts" \( -type l -o ! -user "$owner" -o -perm /022 \) -print -quit) || return 1
    [ -z "$unsafe" ] || return 1
    if [ -e "$home/.clashctl-install" ] || [ -L "$home/.clashctl-install" ]; then
        [ -f "$home/.clashctl-install" ] && [ ! -L "$home/.clashctl-install" ] || return 1
        [ "$(stat -c %u -- "$home/.clashctl-install")" = "$owner" ] &&
            [ "$(stat -c %a -- "$home/.clashctl-install")" = 600 ] || return 1
        [ ! -L "$home/.clashctl-incomplete" ] || return 1
        if [ -e "$home/.env" ] || [ -L "$home/.env" ]; then
            [ -f "$home/.env" ] && [ ! -L "$home/.env" ] &&
                [ "$(stat -c %u -- "$home/.env")" = "$owner" ] || return 1
        fi
        _install_method "$home" >/dev/null || return 1
        printf 'current\n'
        return 0
    fi
    marker="$home/.clashctl-installation"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
        [ "$(stat -c %u -- "$marker")" = "$owner" ] &&
            [ "$(stat -c %a -- "$marker")" = 600 ] &&
            [ "$(wc -l <"$marker")" -eq 4 ] || return 1
        grep -Fqx 'CLASHCTL_INSTALLATION=clashctl' "$marker" &&
            grep -Fqx 'CLASHCTL_INSTALLATION_FORMAT=1' "$marker" &&
            grep -Fqx "CLASHCTL_INSTALLATION_HOME=$home" "$marker" &&
            grep -Fqx "CLASHCTL_INSTALLATION_UID=$owner" "$marker" || return 1
        printf 'legacy-v2\n'
        return 0
    fi
    # 早期版本没有身份标记，必须同时具有旧版代码特征和实际用户数据。
    [ ! -e "$home/.git" ] && [ ! -L "$home/.git" ] &&
        [ -d "$home/resources" ] && [ ! -L "$home/resources" ] &&
        [ -f "$home/.env" ] && [ ! -L "$home/.env" ] &&
        [ "$(stat -c %u -- "$home/.env")" = "$owner" ] &&
        grep -Fqx 'CLASH_CONFIG_BASE="${CLASH_RESOURCES_DIR}/config.yaml"' "$home/scripts/lib/common.sh" &&
        grep -Fq 'CLASH_PROFILES_DIR="${CLASH_RESOURCES_DIR}/profiles"' "$home/scripts/lib/common.sh" &&
        { [ -f "$home/resources/config.yaml" ] || [ -d "$home/resources/profiles" ]; } || return 1
    printf 'legacy-v1\n'
}

_install_format_current() {
    [ -f "$CLASHCTL_HOME/.clashctl-format" ] && [ ! -L "$CLASHCTL_HOME/.clashctl-format" ] &&
        [ "$(cat -- "$CLASHCTL_HOME/.clashctl-format")" = 1 ]
}

_install_apply_update() {
    local stage=$1 method=$2 target=$3 work=$4
    if [ -e "$CLASHCTL_HOME/.clashctl-uninitialized" ] ||
        _install_format_current; then
        if [ "$method" = git ]; then _update_git_checkout "$target" "$work";
        else _update_archive "$stage" "$work"; fi
    else
        . "$stage/scripts/install-migration.sh" || return 1
        _install_migrate_current "$stage" "$method" "$target" "$work"
    fi
}

# 跨版本只调用稳定更新入口；私有模块的位置和应用过程由目标版本决定。
_source_apply_update() (
    local stage=$1
    unset -f _update_apply_source
    . "$stage/scripts/cmd/update.sh" || return 1
    declare -F _update_apply_source >/dev/null || {
        printf '源码不兼容：更新入口不支持应用已下载的源码\n' >&2
        return 1
    }
    _update_apply_source "$@"
)

_source_path_allowed() {
    local path=${1#./}
    [[ -n "$path" && "$path" != /* && "$path" != *[^a-zA-Z0-9_./-]* ]] || return 1
    case "/$path/" in */../* | */./*) return 1 ;; esac
    case "$path" in
    .git | .git/* | .env | .env/* | .clashctl-* | data | data/* | bin | bin/* | archives | archives/* | resources/dist | resources/dist/* | resources/cache.db | resources/proxies | resources/proxies/* | resources/rules | resources/rules/*)
        return 1 ;;
    esac
}

_source_archive() (
    local destination=$1 branch=$2 proxy=$3 archive entries url
    [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./-]*$ ]] || { printf '分支名称无效\n' >&2; return 1; }
    archive=$(mktemp) || return 1
    entries="${archive}.list"
    trap 'rm -f -- "$archive" "$entries"' EXIT
    url="https://github.com/nelvko/clashctl/archive/refs/heads/${branch}.tar.gz"
    [ -z "$proxy" ] || url="${proxy%/}/$url"
    command -v curl >/dev/null 2>&1 || { printf '缺少依赖: curl，请先安装后重试\n' >&2; return 1; }
    curl -fsSL --connect-timeout 10 --max-time 180 --retry 2 -o "$archive" "$url" || return 1
    # 仅允许单个顶层目录内的普通文件/目录；拒绝越界路径和链接后再解压。
    tar -tzf "$archive" >"$entries" || return 1
    awk '
        /[^a-zA-Z0-9_.\/-]/ || /^\// || /(^|\/)\.\.?($|\/)/ { exit 1 }
        { split($0, parts, "/"); if (!root) root=parts[1]; if (parts[1]!=root || !index($0,"/")) exit 1 }
        END { if (!root) exit 1 }
    ' "$entries" || { printf '源码归档路径无效\n' >&2; return 1; }
    tar -tvzf "$archive" >"$entries" || return 1
    if LC_ALL=C grep -qv '^[-d]' "$entries"; then
        printf '源码归档包含非普通文件\n' >&2
        return 1
    fi
    tar -xzf "$archive" --strip-components=1 --no-same-owner --no-same-permissions -C "$destination"
)

_source_validate() {
    local directory=$1 file relative
    for file in install.sh scripts/cmd/update.sh; do
        if [ ! -f "$directory/$file" ] || [ -L "$directory/$file" ]; then
            printf '源码不兼容：缺少必需文件 %s\n' "$file" >&2
            return 1
        fi
    done
    while IFS= read -r -d '' file; do
        relative=${file#"$directory/"}
        if ! _source_path_allowed "$relative" || [ -L "$file" ] || { [ ! -d "$file" ] && [ ! -f "$file" ]; }; then
            printf '源码包含不支持的路径：%s\n' "$relative" >&2
            return 1
        fi
        case "$file" in *.sh) bash -n "$file" || return 1 ;; esac
    done < <(find "$directory" -mindepth 1 -path "$directory/.git" -prune -o -print0)
}

# 仅由目标版本自己的入口检查其内部布局，不把私有文件名变成升级协议。
_install_validate_source() {
    local directory=$1 file
    _source_validate "$directory" || return 1
    for file in .env.example uninstall.sh scripts/preflight.sh scripts/install-common.sh scripts/install-migration.sh scripts/lib/operation-lock.sh scripts/cmd/clashctl.sh; do
        if [ ! -f "$directory/$file" ] || [ -L "$directory/$file" ]; then
            printf '源码不兼容：缺少必需文件 %s\n' "$file" >&2
            return 1
        fi
    done
    grep -q '^_directory_lock_acquire()' "$directory/scripts/lib/operation-lock.sh" || {
        printf '源码不兼容：操作锁实现过旧，请选择更新的安装源码或分支\n' >&2
        return 1
    }
}

_source_manifest() (
    set -o pipefail
    cd -- "$1" || return 1
    find . -path './.git' -prune -o -type f ! -name '.clashctl-*' -print0 |
        sort -z | xargs -0 -r sha256sum
)

# 工作树已确认干净；失败只回退程序文件，保留用户数据。
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
        trap - EXIT ERR
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
        operation_lock_release || true
        exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    started=true
    git -C "$CLASHCTL_HOME" checkout --detach -q "$target" || return 1
    [ "${_INSTALL_UPDATE_FINISH:-}" != 1 ] || _install_migration_finish || return 1
    complete=true
)

# 核对完整路径，防止通过目录软链接写入安装目录以外。
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
        trap - EXIT ERR
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
        operation_lock_release || true
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
    [ "${_INSTALL_UPDATE_FINISH:-}" != 1 ] || _install_migration_finish || return 1
    complete=true
)
