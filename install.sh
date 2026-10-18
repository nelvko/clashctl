#!/usr/bin/env bash

# 同时供安装入口与 clashupdate 使用；source 本文件只加载函数。
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

# 自举入口已校验源码；同一套库覆盖落盘、初始化和失败恢复。
_install_lock() {
    CLASHCTL_INSTALL_SOURCE=$1
    # shellcheck source=/dev/null
    . "$1/scripts/lib/operation-lock.sh" || return 1
    operation_lock_acquire
}

# 尚未安装时，仅允许预先准备 archives，不放宽已安装目录的身份识别。
_install_prepared_archives_safe() {
    local home=$1 path owner mode unexpected
    for path in "$home" "$home/archives"; do
        if [ "$path" != "$home" ] && [ ! -e "$path" ] && [ ! -L "$path" ]; then continue; fi
        [ -d "$path" ] && [ ! -L "$path" ] || return 1
        owner=$(stat -c %u -- "$path") || return 1
        mode=$(stat -c %a -- "$path") || return 1
        [ "$owner" = "$(id -u)" ] && [ $((8#$mode & 0700)) -eq $((8#700)) ] &&
            [ $((8#$mode & 0022)) -eq 0 ] || return 1
    done
    unexpected=$(find "$home" -mindepth 1 -maxdepth 1 ! -name archives -print -quit) || return 1
    [ -z "$unexpected" ] || return 1
    if [ -d "$home/archives" ]; then
        unexpected=$(find "$home/archives" -mindepth 1 \
            \( ! -type f -o ! -user "$(id -u)" -o -perm /022 \) -print -quit) || return 1
        [ -z "$unexpected" ] || return 1
    fi
}

# 仅向已核验的预置目录提交源码；archives 留在原位，提交失败时撤回新增条目。
_install_commit_prepared_source() (
    local source=$1 home=$2 path name committed=false rc
    local -a moved=()
    _install_prepared_archives_safe "$home" || return 1
    trap 'rc=$?; trap - EXIT; if [ "$committed" = false ]; then
        for name in "${moved[@]}"; do
            if [ ! -e "$source/$name" ] && [ ! -L "$source/$name" ]; then
                mv -T -- "$home/$name" "$source/$name" || printf "无法撤回安装文件：%s\n" "$home/$name" >&2
            fi
        done
    fi; exit "$rc"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    for path in "$source"/* "$source"/.[!.]* "$source"/..?*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        name=${path##*/}
        [ ! -e "$home/$name" ] && [ ! -L "$home/$name" ] || return 1
        moved+=("$name")
        mv -T -- "$path" "$home/$name" || return 1
    done
    committed=true
)

# 旧格式只识别并提示，不加载配置、搬迁目录或接管进程。
_install_existing_kind() {
    local home=$1 owner mode path unsafe
    [ -d "$home" ] && [ ! -L "$home" ] || return 1
    if [ ! -e "$home/.clashctl-install" ] && [ ! -L "$home/.clashctl-install" ]; then
        if [ -e "$home/.clashctl-installation" ] ||
            { [ -f "$home/.env" ] && [ -d "$home/scripts" ]; }; then
            printf 'legacy\n'
            return 0
        fi
        return 1
    fi
    owner=$(stat -c %u -- "$home") || return 1
    mode=$(stat -c %a -- "$home") || return 1
    [ "$owner" = "$(id -u)" ] && [ $((8#$mode & 0022)) -eq 0 ] || return 1
    for path in install.sh scripts/preflight.sh scripts/lib/common.sh .clashctl-install; do
        [ -f "$home/$path" ] && [ ! -L "$home/$path" ] || return 1
        [ "$(stat -c %u -- "$home/$path")" = "$owner" ] || return 1
        mode=$(stat -c %a -- "$home/$path") || return 1
        [ $((8#$mode & 0022)) -eq 0 ] || return 1
    done
    [ "$(stat -c %a -- "$home/.clashctl-install")" = 600 ] || return 1
    unsafe=$(find "$home/scripts" \( -type l -o ! -user "$owner" -o -perm /022 \) -print -quit) || return 1
    [ -z "$unsafe" ] && [ ! -L "$home/.clashctl-incomplete" ] || return 1
    if [ -e "$home/.env" ] || [ -L "$home/.env" ]; then
        [ -f "$home/.env" ] && [ ! -L "$home/.env" ] &&
            [ "$(stat -c %u -- "$home/.env")" = "$owner" ] || return 1
    fi
    _install_method "$home" >/dev/null || return 1
    if [ ! -d "$home/bin/mihomo" ] && _source_validate "$home" installed >/dev/null 2>&1; then
        printf 'current\n'
    else
        printf 'legacy\n'
    fi
}

_install_reject_legacy() {
    printf '检测到旧版安装：%s；请先使用旧版卸载脚本卸载，或通过 --home 指定其他目录\n' "$1" >&2
    return 1
}

_install_refresh_current() (
    local home=$1 local_source=$2 script_dir=$3 branch=$4 proxy=$5
    local work='' stage update_source
    update_source=$CLASHCTL_INSTALL_SOURCE
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
    export CLASHCTL_HOME="$home" CLASHCTL_SRC="$update_source"
    . "$update_source/scripts/preflight.sh" || return 1
    . "$update_source/scripts/cmd/update.sh" || return 1
    export CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    if [ "$local_source" = true ]; then
        work=$(mktemp -d "${home}.update.XXXXXX") || return 1
        # 回滚失败时，更新器会标记 keep 并留下 previous.tar 供手动恢复。
        stage="$work/source"
        mkdir "$stage" || return 1
        _install_copy_local_source "$script_dir" "$stage" || return 1
        _source_validate "$stage" || return 1
        operation_lock_acquire || return 1
        # 使用本次安装器的样式，避免旧安装的输出函数改变阶段前缀。
        printf '\n' >&2
        _install_bootstrap_step '应用本地源码更新'
        _update_archive "$stage" "$work"
    else
        _update_scripts
    fi
)

_install_copy_local_source() (
    set -o pipefail
    tar -C "$1" --exclude-vcs-ignores \
        --exclude='./.git' --exclude='./.env' --exclude='./.clashctl-*' \
        --exclude='./data' --exclude='./bin' --exclude='./archives' \
        --exclude='./resources/dist' --exclude='./resources/cache.db' \
        --exclude='./resources/proxies' --exclude='./resources/rules' -cf - . |
        tar --no-same-owner --no-same-permissions -xf - -C "$2"
)

_install_prepare_source() {
    local destination=$1 branch=$2 proxy=$3 local_source=$4 script_dir=$5 url
    if [ "$local_source" = true ]; then
        method=archive
        _install_copy_local_source "$script_dir" "$destination" || return 1
    elif command -v git >/dev/null 2>&1; then
        method=git
        url=https://github.com/nelvko/clashctl.git
        local -a clone_options=(--depth 1 --branch "$branch")
        [ "${_INSTALL_VERBOSE:-}" = 1 ] || clone_options+=(--quiet)
        [ -z "$proxy" ] || url="${proxy%/}/$url"
        git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
            clone "${clone_options[@]}" -- "$url" "$destination" || return 1
    else
        method=archive
        _source_archive "$destination" "$branch" "$proxy" || return 1
        [ ! -e "$destination/.git" ] && [ ! -L "$destination/.git" ] || return 1
    fi
    _source_validate "$destination"
}

# 初始化失败时保留本次安装；服务后端切换仍恢复原配置。
_install_main_cleanup() {
    local rc=$?
    trap - EXIT
    trap '' INT TERM HUP
    set +e
    if [ "${service_switch_pending:-false}" = true ]; then
        _install_restore_service || {
            printf '无法完整恢复原服务，请保留安装目录并检查 INIT_TYPE 和服务状态\n' >&2
            rc=1
        }
    fi
    [ -z "${stage:-}" ] || rm -rf -- "$stage"
    if declare -F operation_lock_release >/dev/null 2>&1; then
        operation_lock_release || true
    fi
    exit "$rc"
}

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
    for file in .env.example install.sh uninstall.sh scripts/preflight.sh scripts/lib/operation-lock.sh scripts/lib/install-maintenance.sh scripts/cmd/clashctl.sh scripts/cmd/update.sh; do
        if [ ! -f "$directory/$file" ] || [ -L "$directory/$file" ]; then
            printf '源码不兼容：缺少必需文件 %s\n' "$file" >&2
            return 1
        fi
    done
    grep -q '^_directory_lock_acquire()' "$directory/scripts/lib/operation-lock.sh" || {
        printf '源码不兼容：操作锁实现过旧，请选择更新的安装源码或分支\n' >&2
        return 1
    }
    [ "${2:-}" != installed ] || return 0
    while IFS= read -r -d '' file; do
        relative=${file#"$directory/"}
        if ! _source_path_allowed "$relative" || [ -L "$file" ] || { [ ! -d "$file" ] && [ ! -f "$file" ]; }; then
            printf '源码包含不支持的路径：%s\n' "$relative" >&2
            return 1
        fi
        case "$file" in *.sh) bash -n "$file" || return 1 ;; esac
    done < <(find "$directory" -mindepth 1 -path "$directory/.git" -prune -o -print0)
}

_source_manifest() (
    set -o pipefail
    cd -- "$1" || return 1
    find . -path './.git' -prune -o -type f ! -name '.clashctl-*' -print0 |
        sort -z | xargs -0 -r sha256sum
)

# 在线安装的第一个阶段尚无公共库；颜色规则与 _ui_color_enabled 保持一致。
_install_bootstrap_log() {
    local level=$1 msg=$2 prefix color colored=false
    case $level in
    step) prefix='[STEP]'; color=36 ;;
    ok) prefix='[ OK ]'; color=32 ;;
    *) prefix='[INFO]'; color=36 ;;
    esac
    if [ "${NO_COLOR+x}" != x ]; then
        case ${CLASHCTL_COLOR:-auto} in
        always) colored=true ;;
        never) ;;
        *)
            if [ "${CI+x}" != x ] && [ "${TERM:-dumb}" != dumb ] && [ -t 2 ]; then
                colored=true
            fi
            ;;
        esac
    fi
    if [ "$colored" = true ]; then
        if [ "$level" = step ]; then
            printf '\033[1;%sm%s %s\033[0m\n' "$color" "$prefix" "$msg" >&2
        else
            printf '\033[1;%sm%s\033[0m %s\n' "$color" "$prefix" "$msg" >&2
        fi
    else
        printf '%s %s\n' "$prefix" "$msg" >&2
    fi
}

_install_bootstrap_step() { _install_bootstrap_log step "$1"; }

_install_intro() {
    local action=$1 home=$2 home_source=$3 local_source=$4 branch=$5
    if [ "$local_source" = true ]; then
        _install_bootstrap_step "$action（本地源码）"
    else
        _install_bootstrap_step "$action（分支 $branch）"
    fi
    if [ "$home_source" = CLASHCTL_HOME ]; then
        printf '       安装目录: %s（CLASHCTL_HOME）\n' "$home" >&2
    else
        printf '       安装目录: %s\n' "$home" >&2
    fi
}

_install_next_step() {
    local shell=$1 rc_var rc_path load_command command_width=32
    case "$shell" in bash | zsh | fish) ;; *) shell=bash ;; esac
    rc_var=SHELL_RC_${shell^^}
    rc_path=${!rc_var:-}
    if [ -f "$rc_path" ]; then
        printf -v load_command 'source %q' "$rc_path"
        if [[ $rc_path == "$HOME/"* ]]; then
            printf -v load_command 'source ~/%q' "${rc_path#"$HOME/"}"
        fi
    elif [ "$shell" = fish ]; then
        printf -v load_command 'set -gx CLASHCTL_HOME %q; source %q' \
            "$CLASHCTL_HOME" "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"
    else
        printf -v load_command 'export CLASHCTL_HOME=%q; source %q' \
            "$CLASHCTL_HOME" "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
    fi
    [ "${#load_command}" -le "$command_width" ] || command_width=${#load_command}
    printf '\n在当前终端执行（%s）:\n' "$shell" >&2
    printf '  %-*s  # %s\n' "$command_width" "$load_command" '加载命令' >&2
    printf '  %-*s  # %s\n' "$command_width" 'clashctl on' '启用当前终端代理' >&2
    if service_is_active >/dev/null 2>&1; then
        printf '  %-*s  # %s\n' "$command_width" 'clashctl ui' '查看面板地址' >&2
    fi
    if [ ! -s "$CLASH_CONFIG_BASE" ] || [ "${_INSTALL_SUBSCRIPTION_RETRY:-false}" = true ]; then
        printf '\n按需添加订阅:\n  %s\n' 'clashctl sub add --use "<URL>"' >&2
    fi
    if [ "${service_manager:-}" = systemd-user ] &&
        ! _is_tun_enabled; then
        printf '\n按需设置（需管理员权限）:\n' >&2
        printf '  sudo loginctl enable-linger %s  # 开机自启与退出登录后常驻\n' "$(id -un)" >&2
    fi
}

_install_complete() {
    printf '\n' >&2
    _install_ui_ok '安装完成'
    # 安装器运行在子进程中；优先识别调用它的 Shell，登录 Shell 只作兜底。
    local shell
    shell=$(readlink "/proc/$PPID/exe" 2>/dev/null) || shell=${SHELL:-bash}
    case ${shell##*/} in bash | zsh | fish) ;; *) shell=${SHELL:-bash} ;; esac
    _install_next_step "${shell##*/}"
}

# 自动模式只为首次安装选型；保存过的后端不随登录会话变化。
_install_select_service() {
    local requested=${1:-auto} saved=${2-${INIT_TYPE:-}} answer
    _INSTALL_SELECTED_SERVICE=$service_manager
    case $requested in
    nohup) _INSTALL_SELECTED_SERVICE='nohup' ;;
    systemd-user)
        if ! service_user_available; then
            _install_ui_error '用户级 systemd 不可用（需要 systemd 243 或更高版本），请在该用户的登录会话中重试，或使用 --service nohup'
            return 1
        fi
        _INSTALL_SELECTED_SERVICE=systemd-user
        ;;
    auto)
        [ -z "$saved" ] || return 0
        _is_root && return 0
        if service_user_available; then
            _INSTALL_SELECTED_SERVICE=systemd-user
            if [ "${CI+x}" != x ] && ( : </dev/tty ) 2>/dev/null; then
                printf '%s\n' \
                    '       服务类型：' \
                    '         1) systemd --user' \
                    '            开机自启与退出登录后常驻可能需要管理员权限设置。' \
                    '         2) nohup' \
                    '            可后台常驻，无开机自启和异常自动重启。' >&2
                while :; do
                    printf '       请选择 [1/2，默认 1]: ' >&2
                    IFS= read -r answer </dev/tty || answer=1
                    case $answer in
                    '' | 1) break ;;
                    2) _INSTALL_SELECTED_SERVICE='nohup'; break ;;
                    *) _install_ui_warn '请输入 1 或 2' ;;
                    esac
                done
            fi
        else
            _INSTALL_SELECTED_SERVICE='nohup'
            _install_ui_info '用户级 systemd 不可用，使用 nohup'
        fi
        ;;
    esac
}

_install_use_service() {
    INIT_TYPE=$1
    service_manager=''
    detect_service_manager
}

# 切换前先检查新服务冲突；旧服务停止后至初始化完成期间可由 EXIT 恢复。
_install_apply_service() {
    local selected=$1 saved=${2:-} state
    if [ "$selected" != "$service_manager" ] && [ -z "$saved" ]; then
        _install_use_service "$selected" || return 1
    elif [ "$selected" != "$service_manager" ]; then
        case "$service_manager:$selected" in
        nohup:systemd-user | systemd-user:nohup) ;;
        *) _install_ui_error '已有安装仅支持在 nohup 与 systemd-user 之间切换'; return 1 ;;
        esac
        ( _install_use_service "$selected" && _service_check_conflict ) || return 1
        state=$(service_state) || { _install_ui_error '无法确认原服务状态，未切换运行方式'; return 1; }
        case $state in
        running | stopped | failed) ;;
        *) _install_ui_error '原服务正在启动或停止，请稍后重试'; return 1 ;;
        esac
        service_previous_manager=$service_manager
        service_previous_init=${INIT_TYPE:-$service_manager}
        service_selected_manager=$selected
        service_previous_active=false
        service_previous_enabled=false
        service_previous_privileged=false
        [ "$state" != running ] || service_previous_active=true
        if [ "$service_manager" = systemd-user ]; then
            systemctl --user is-enabled --quiet "$CLASHCTL_KERNEL" && service_previous_enabled=true
        fi
        _service_privileged_marker_exists && service_previous_privileged=true
        service_switch_pending=true
        uninstall_service || return 1
        _install_use_service "$selected" || return 1
    fi
    _set_env INIT_TYPE "$service_manager" || return 1
    install_service || {
        local service_label=$service_manager
        [ "$service_label" != systemd-user ] || service_label='systemd --user'
        _install_ui_error "$service_label 服务注册失败"
        return 1
    }
}

_install_restore_service() {
    [ "${service_switch_pending:-false}" = true ] || return 0
    local target=''
    _install_use_service "$service_selected_manager" || return 1
    target=$(_service_target 2>/dev/null) || target=''
    if [ "$service_selected_manager" = systemd-user ] && [ -n "$target" ] &&
        [ ! -e "$target" ] && [ ! -L "$target" ]; then
        # 注册失败可能尚未写入 unit；disable 不存在的单元会失败，不能因此跳过旧服务恢复。
        service_stop_checked && systemctl --user daemon-reload || return 1
    elif ! uninstall_service; then
        _install_ui_error '无法停止切换后的服务，已保留现场；请恢复用户级 systemd 连接后重试'
        return 1
    fi
    _install_use_service "$service_previous_init" || return 1
    _set_env INIT_TYPE "$service_previous_init" || return 1
    install_service || return 1
    [ "$service_previous_enabled" != true ] || service_enable || return 1
    if [ "$service_previous_active" = true ]; then
        if [ "$service_previous_privileged" = true ]; then
            service_sudo_start || return 1
        else
            service_start || return 1
        fi
    fi
    service_switch_pending=false
    _install_ui_warn "安装未完成，已恢复原运行方式：$service_previous_manager"
}

_install_initialize() {
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    . "$CLASHCTL_SRC/scripts/preflight.sh" || return 1
    [ "${4:-}" != x ] || CLASHCTL_DOWNLOAD_TIMEOUT=$5
    # 参数在 main 中保存，不受 preflight 加载已有 .env 的影响。
    local kernel=${1:-${CLASHCTL_KERNEL:-mihomo}} branch=${2:-${CLASHCTL_UPDATE_BRANCH:-master}}
    local proxy=${3:-} subscription=${6:-} requested_service=${7:-auto} rc secret
    _INSTALL_SUBSCRIPTION_RETRY=false
    export -n subscription secret
    export CLASHCTL_KERNEL="$kernel" CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    # shellcheck disable=SC2034  # preflight 中的组件安装与服务定义共用此路径。
    BIN_KERNEL=$(bin_kernel_path) || return 1
    operation_lock_acquire || return 1
    valid_required || return 1
    local saved_service=''
    [ ! -f "$CLASHCTL_HOME/.env" ] || saved_service=${INIT_TYPE:-}
    detect_service_manager
    _install_select_service "$requested_service" "$saved_service" || return 1
    local selected_service=$_INSTALL_SELECTED_SERVICE
    _service_check_conflict || return 1
    # 新后端冲突在下载运行组件和停止旧内核之前报告。
    if [ "$selected_service" != "$service_manager" ]; then
        ( _install_use_service "$selected_service" && _service_check_conflict ) || return 1
    fi

    _install_ui_step '准备运行组件'
    install -d -m 0700 "$CLASH_DATA_DIR" "$CLASH_PROFILES_DIR" || return 1
    local source target
    for source in mixin.yaml.example profiles.yaml; do
        target="$CLASH_DATA_DIR/${source%.example}"
        [ -f "$target" ] || install -m 0600 "$CLASH_RESOURCES_DIR/$source" "$target" || return 1
    done
    [ -f "$CLASH_CONFIG_BASE" ] || install -m 0600 /dev/null "$CLASH_CONFIG_BASE" || return 1
    _INSTALL_DEFER_DOWNLOAD_HINT=1 prepare_zip kernel yq || return 1
    # 在写入配置、注册服务之前撤销未初始化凭据；后续丢失 .env 不能按空安装删除。
    command rm -f -- "$CLASHCTL_HOME/.clashctl-uninitialized" || return 1
    [ -f "$CLASHCTL_HOME/.env" ] || install -m 0600 "$CLASHCTL_HOME/.env.example" "$CLASHCTL_HOME/.env" || return 1
    _set_env CLASHCTL_KERNEL "$kernel" || return 1
    _set_env CLASHCTL_UPDATE_BRANCH "$branch" || return 1
    _set_env GH_PROXY "$proxy" || return 1
    _set_env CLASHCTL_DOWNLOAD_TIMEOUT "$CLASHCTL_DOWNLOAD_TIMEOUT" || return 1
    _install_ui_step '配置运行环境'
    _install_apply_service "$selected_service" "$saved_service" || return 1
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || return 1
    # 命令加载器会重新加载 service.sh，清空之前检测到的服务方式与路径。
    detect_service_manager

    # 密钥直接写入 Mixin，无主配置时不生成 runtime。
    secret=$("$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_MIXIN") || return 1
    if [ -z "$secret" ]; then
        secret=$(_get_random_val) || return 1
        SECRET=$secret "$BIN_YQ" -i '.secret = env(SECRET)' "$CLASH_CONFIG_MIXIN" || return 1
    fi
    local kernel_status='已启动' runtime_mode=''
    if service_is_active >/dev/null 2>&1; then
        kernel_status='已在运行'
    fi

    if [ -z "$subscription" ] && [ ! -s "$CLASH_CONFIG_BASE" ] &&
        [ "${CI+x}" != x ] && ( : </dev/tty ) 2>/dev/null; then
        _read_subscription_url subscription '       订阅链接（回车跳过）: ' </dev/tty || subscription=''
    fi
    if [ -n "$subscription" ]; then
        # 订阅失败不算安装失败：组件、命令和服务都已就绪，此时报"安装未完成"会误导用户重装。
        if ! clashsub add --use "$subscription"; then
            _install_ui_warn '订阅添加失败，可稍后重试'
            _INSTALL_SUBSCRIPTION_RETRY=true
        fi
    fi
    # 订阅生效已启动内核；跳过订阅时以直连配置启动，续装保留已运行的内核。
    if ! service_is_active >/dev/null 2>&1; then
        clashstart >/dev/null || return 1
    fi
    service_is_active >/dev/null 2>&1 || {
        _install_ui_error '内核未启动，请检查服务日志'
        return 1
    }
    runtime_mode=$("$BIN_YQ" '.mode // "rule"' "$CLASH_CONFIG_RUNTIME" 2>/dev/null) || runtime_mode=''
    [ "$runtime_mode" != direct ] || kernel_status+='（直连）'
    _install_ui_ok "$CLASHCTL_KERNEL $kernel_status"
    # 已运行内核也需要恢复自启设置；nohup 的 service_enable 不执行操作。
    service_enable || return 1
    case "$service_manager" in
    systemd-user)
        _install_ui_ok '已注册 systemd --user 服务'
        if _is_tun_enabled; then
            _install_ui_info 'TUN 需 sudo 手动启动，不支持自启'
        else
            _install_ui_ok '已设置登录自启'
        fi
        ;;
    nohup) _install_ui_ok 'nohup 后台运行' ;;
    *)
        _install_ui_ok "已注册 $service_manager 服务"
        _install_ui_ok '已设置开机自启'
        ;;
    esac
    rc=0
    apply_rc || rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || return "$rc"
    return 0
}

# 可直接 curl .../install.sh | bash；交互输入从 /dev/tty 读取。
main() (
    set -e
    _install_ui_output() { _install_ui_emit_fd "$@"; }
    # 更新器会再次 source 安装器以复用函数；同一路径执行时不能递归进入 main。
    CLASHCTL_INSTALL_RUNNING=1
    local install_home=${CLASHCTL_HOME:-$HOME/.clashctl}
    local _INSTALL_VERBOSE=${_INSTALL_VERBOSE:-}
    local _INSTALL_DOWNLOAD_FAILED_URL='' _INSTALL_DOWNLOAD_FAILED_TARGET=''
    local home_source='默认值（~/.clashctl）'
    [ -z "${CLASHCTL_HOME:-}" ] || home_source=CLASHCTL_HOME
    local branch=${CLASHCTL_UPDATE_BRANCH:-} kernel='' subscription='' requested_service=auto
    local proxy=${GH_PROXY:-} proxy_set=${GH_PROXY+x} stage='' arg option value_name method
    local requested_timeout=${CLASHCTL_DOWNLOAD_TIMEOUT-} timeout_set=${CLASHCTL_DOWNLOAD_TIMEOUT+x}
    local local_source=false script_dir='' existing_kind=''
    local prepared_archives=false replacing_clash=false
    local CLASHCTL_INSTALL_SOURCE=''
    local service_switch_pending=false service_previous_manager='' service_previous_init='' service_selected_manager=''
    local service_previous_active=false service_previous_enabled=false service_previous_privileged=false
    trap _install_main_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    while [ "$#" -gt 0 ]; do
        arg=$1
        option=$arg
        shift
        case $arg in
        --branch | --kernel | --sub | --service | --home | --gh-proxy)
            case $arg in
            --branch) value_name='一个分支名称' ;;
            --kernel) value_name=' mihomo' ;;
            --sub) value_name='一个订阅链接' ;;
            --service) value_name=' auto、systemd-user 或 nohup' ;;
            --home) value_name='一个绝对路径' ;;
            --gh-proxy) value_name='一个值' ;;
            esac
            if [ "$#" -eq 0 ] ||
                { [ -z "$1" ] && [ "$arg" != --kernel ] && [ "$arg" != --gh-proxy ]; }; then
                printf '%s 需要%s\n' "$arg" "$value_name" >&2
                return 1
            fi
            arg+="=$1"
            shift
            ;;
        esac
        case $arg in
        --branch=*)
            branch=${arg#*=}
            [ -n "$branch" ] && [[ "$branch" != -* ]] || { printf '%s\n' '--branch 需要一个分支名称' >&2; return 1; }
            ;;
        --kernel=*)
            kernel=${arg#*=}
            [ -n "$kernel" ] || [ "$option" = --kernel ] || { printf '%s\n' '--kernel 需要 mihomo' >&2; return 1; }
            ;;
        --sub=*)
            subscription=${arg#*=}
            [ -n "$subscription" ] || { printf '%s\n' '--sub 需要一个订阅链接' >&2; return 1; }
            ;;
        --local) local_source=true ;;
        --service=*) requested_service=${arg#*=} ;;
        --verbose) _INSTALL_VERBOSE=1 ;;
        --home=*)
            install_home=${arg#--home=}
            home_source=--home
            [ -n "$install_home" ] || { printf '%s\n' '--home 需要一个绝对路径' >&2; return 1; }
            ;;
        --gh-proxy=*) proxy=${arg#--gh-proxy=}; proxy_set=x ;;
        -h | --help)
            cat <<'HELP'
安装或更新 clashctl

用法: bash install.sh [选项]

安装选项:
  --local                 使用本地源码安装，依赖仍按需下载
  --home <路径>           指定安装目录（绝对路径，默认 ~/.clashctl）
  --kernel <内核>         mihomo（默认）
  --sub <URL>             添加并启用订阅；无现有配置时交互询问
  --service <方式>        auto（默认）、systemd-user 或 nohup
                          auto 沿用已有方式；新装普通用户优先用户级 systemd

下载与更新:
  --branch <分支>         源码及后续更新分支（新安装默认 master）
                          配合 --local 时，仅设置后续更新分支
  --gh-proxy <URL>        GitHub 下载代理前缀；--gh-proxy= 表示直连
  --verbose               显示源码下载详情、完整下载地址和缓存路径
  -h, --help              显示帮助

环境变量（可选）:
  CLASHCTL_HOME              安装目录
  CLASHCTL_UPDATE_BRANCH     源码及后续更新分支
  GH_PROXY                   GitHub 下载代理前缀
  CLASHCTL_DOWNLOAD_TIMEOUT   每次依赖下载尝试的最长时间（秒，默认 0 表示不限）
                             重试重新计时，连接或下载停滞时仍会中断

重复安装沿用已保存配置，命令行参数可覆盖。参数支持 --选项 值 或 --选项=值。
--local 需从本地 install.sh 执行，不支持管道安装。

示例:
  本地源码安装:
    bash install.sh --local --gh-proxy https://gh-proxy.org
  指定分支安装:
    bash install.sh --branch install-update --gh-proxy https://gh-proxy.org

更多说明: https://github.com/nelvko/clashctl/wiki
HELP
            return 0 ;;
        *) printf '未知安装参数\n' >&2; return 1 ;;
        esac
    done
    case $kernel in
    '' | mihomo) ;;
    *) printf '%s\n' '--kernel 仅支持 mihomo' >&2; return 1 ;;
    esac
    case $requested_service in
    auto | systemd-user | nohup) ;;
    *) printf '%s\n' '--service 仅支持 auto、systemd-user 或 nohup' >&2; return 1 ;;
    esac
    if [ "$requested_service" = systemd-user ] && [ "$(id -u)" -eq 0 ]; then
        printf '%s\n' 'systemd-user 需要以目标普通用户运行安装器' >&2
        return 1
    fi
    if [ -f "${BASH_SOURCE[0]:-}" ]; then
        script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    fi
    if [ "$local_source" = true ] && [ -z "$script_dir" ]; then
        printf '%s\n' '--local 需要从本地源码目录中的 install.sh 执行，不支持管道输入' >&2
        return 1
    fi
    # 服务单元名与内核二进制路径都派生自它，必须在 sourcing 前导出。
    export CLASHCTL_KERNEL="$kernel"
    for arg in curl tar gzip unzip sha256sum; do
        command -v "$arg" >/dev/null || { printf '缺少依赖: %s\n' "$arg" >&2; return 1; }
    done
    # 服务模板使用绝对路径；拒绝会影响模板或 Shell 解析的字符。
    [[ $install_home == /* && $install_home != *[^a-zA-Z0-9_./-]* ]] || {
        printf '安装目录必须是绝对路径，且只包含字母、数字、_、.、/、-\n' >&2
        return 1
    }
    install_home=$(readlink -m -- "$install_home") || return 1
    if [ "$install_home" = / ] || [ "$install_home" = "$(cd -- "$HOME" && pwd -P)" ]; then
        printf '不能使用根目录或用户主目录作为安装目录\n' >&2
        return 1
    fi
    if [ "$local_source" = true ]; then
        case "$install_home/" in
        "$script_dir/"*) printf '本地安装目录不能位于源码目录内，请通过 --home 指定其他目录\n' >&2; return 1 ;;
        esac
    fi
    if [ -e "$install_home" ] || [ -L "$install_home" ]; then
        if ! existing_kind=$(_install_existing_kind "$install_home"); then
            if _install_prepared_archives_safe "$install_home"; then
                existing_kind=prepared
            else
                printf '无法确认现有目录属于 clashctl 安装：%s；未修改目录\n' "$install_home" >&2
                return 1
            fi
        fi
        if [ "$existing_kind" = current ]; then
            if [ -n "$script_dir" ] && [ -f "$script_dir/scripts/lib/operation-lock.sh" ] &&
                _source_validate "$script_dir" installed; then
                _install_lock "$script_dir" || return 1
            else
                # 管道入口没有伴随库；先取得本次源码，不能借用旧安装中的锁实现。
                stage=$(mktemp -d "${install_home}.download.XXXXXX") || return 1
                _install_prepare_source "$stage" "${branch:-master}" "$proxy" false '' || return 1
                _install_lock "$stage" || return 1
            fi
            # 等待准备/加锁期间，另一操作可能已经卸载或替换此目录。
            [ "$(_install_existing_kind "$install_home")" = current ] || {
                printf '安装目录状态已变化，请重新运行安装器\n' >&2
                return 1
            }
            method=$(_install_method "$install_home") || return 1
            # 先读取已保存的选项；本次显式参数与环境变量优先。
            if [ -f "$install_home/.env" ]; then
                local requested_kernel=$kernel requested_branch=$branch requested_proxy=$proxy
                # shellcheck source=/dev/null
                . "$install_home/.env" || return 1
                kernel=${requested_kernel:-${CLASHCTL_KERNEL:-mihomo}}
                if [ "$kernel" = clash ]; then kernel=mihomo; fi
                [ "${CLASHCTL_KERNEL:-}" != clash ] || replacing_clash=true
                branch=${requested_branch:-${CLASHCTL_UPDATE_BRANCH:-master}}
                [ "$proxy_set" = x ] && proxy=$requested_proxy || proxy=${GH_PROXY:-}
            else
                kernel=${kernel:-mihomo}
                branch=${branch:-master}
            fi
            export CLASHCTL_HOME="$install_home" CLASHCTL_SRC="$install_home"
            if [ -f "$install_home/.env" ] && [ ! -e "$install_home/.clashctl-uninitialized" ] &&
                [ ! -e "$install_home/.clashctl-incomplete" ]; then
                _install_intro '更新现有安装' "$install_home" "$home_source" "$local_source" "$branch"
            else
                _install_intro '继续未完成的安装' "$install_home" "$home_source" "$local_source" "$branch"
            fi
            if [ "$local_source" = true ] && [ "$method" != archive ]; then
                printf 'Git 安装不能直接覆盖为未提交的本地源码；请使用远端更新或另选安装目录\n' >&2
                return 1
            fi
            if [ "$replacing_clash" = true ]; then
                if [ "$local_source" = true ]; then
                    # 停止已退役的内核前，先排除源码和本地修改等确定性错误。
                    [ -z "$stage" ] || rm -rf -- "$stage"
                    stage=$(mktemp -d "${install_home}.download.XXXXXX") || return 1
                    _install_prepare_source "$stage" "$branch" "$proxy" true "$script_dir" || return 1
                    CLASHCTL_INSTALL_SOURCE=$stage
                    script_dir=$stage
                fi
                if [ "$method" = archive ]; then
                    [ -f "$install_home/.clashctl-files" ] && [ ! -L "$install_home/.clashctl-files" ] &&
                        (cd -- "$install_home" && sha256sum --status -c .clashctl-files) || {
                        printf '安装目录存在本地代码修改或文件清单无效，未停止 clash\n' >&2
                        return 1
                    }
                else
                    local dirty
                    dirty=$(git -C "$install_home" status --porcelain --untracked-files=no) || return 1
                    [ -z "$dirty" ] || return 1
                fi
                (
                    # 先按旧安装的完整参数退役 clash，再写入新的内核选项。
                    export CLASHCTL_HOME="$install_home" CLASHCTL_SRC="$install_home"
                    . "$install_home/scripts/preflight.sh" || return 1
                    [ "$CLASHCTL_HOME" = "$install_home" ] && [ "$CLASHCTL_SRC" = "$install_home" ] || return 1
                    uninstall_service || return 1
                    . "$CLASHCTL_INSTALL_SOURCE/scripts/lib/common.sh" || return 1
                    _set_env CLASHCTL_KERNEL mihomo
                ) || return 1
            fi
            _install_refresh_current "$install_home" "$local_source" "$script_dir" "$branch" "$proxy" || return 1
        elif [ "$existing_kind" = prepared ]; then
            prepared_archives=true
            existing_kind=''
        else
            _install_reject_legacy "$install_home"
            return 1
        fi
    elif [ "$install_home" = "$HOME/.clashctl" ] && [ -d "$HOME/clashctl" ]; then
        if [ "$(_install_existing_kind "$HOME/clashctl")" = current ]; then
            printf '已在旧默认路径发现新版安装，请使用 --home %s 后重试\n' "$HOME/clashctl" >&2
            return 1
        elif [ -f "$HOME/clashctl/.env" ] && [ -d "$HOME/clashctl/scripts" ]; then
            _install_reject_legacy "$HOME/clashctl"
            return 1
        fi
    fi
    if [ -z "$existing_kind" ]; then
        branch=${branch:-master}
        _install_intro '新安装 clashctl' "$install_home" "$home_source" "$local_source" "$branch"
        mkdir -p -- "$(dirname -- "$install_home")"
        stage=$(mktemp -d "${install_home}.download.XXXXXX")
        [ "$local_source" = true ] || _install_bootstrap_log info "下载源码（分支 $branch）"
        _install_prepare_source "$stage" "$branch" "$proxy" "$local_source" "$script_dir"
        [ "$local_source" = true ] || _install_bootstrap_log ok '源码已准备'
        _install_lock "$stage" || return 1
        # 源码准备不占锁；取得锁后重新核对目录，避免覆盖并发安装的结果。
        if [ "$prepared_archives" = true ]; then
            _install_prepared_archives_safe "$install_home" || {
                printf '预置安装包目录状态已变化，请重新运行安装器\n' >&2
                return 1
            }
        elif [ -e "$install_home" ] || [ -L "$install_home" ]; then
            printf '安装目录在准备源码期间已被创建，未修改目录：%s\n' "$install_home" >&2
            return 1
        fi
        if [ "$method" = archive ]; then
            _source_manifest "$stage" >"$stage/.clashctl-files"
        fi
        (umask 077; printf '%s\n%s\n' "$install_home" "$method" >"$stage/.clashctl-install")
        (umask 077; printf '%s\n' "$install_home" >"$stage/.clashctl-uninitialized")
        if [ "$prepared_archives" = true ]; then
            _install_commit_prepared_source "$stage" "$install_home" || return 1
            rmdir -- "$stage" || return 1
        elif ! mv -T -- "$stage" "$install_home"; then
            return 1
        fi
        CLASHCTL_INSTALL_SOURCE=$install_home
        stage=''
    fi
    export CLASHCTL_HOME="$install_home" CLASHCTL_SRC="$install_home" CLASHCTL_KERNEL="$kernel"
    export CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    if ! { (umask 077; : >"$install_home/.clashctl-incomplete") &&
        _install_initialize "$kernel" "$branch" "$proxy" "$timeout_set" "$requested_timeout" "$subscription" "$requested_service"; }; then
        local retry_command branch_arg proxy_arg
        if [ "${CLASHCTL_DOWNLOAD_TIMED_OUT:-0}" = 1 ]; then
            local retry_timeout=${CLASHCTL_DOWNLOAD_TIMEOUT:-0}
            [[ $retry_timeout =~ ^[0-9]+$ ]] || retry_timeout=0
            if [ "$retry_timeout" -gt 0 ] && [ "$retry_timeout" -lt 180 ]; then
                retry_timeout=180
            fi
            printf -v retry_command 'CLASHCTL_DOWNLOAD_TIMEOUT=%q bash %q --home %q' \
                "$retry_timeout" "$install_home/install.sh" "$install_home"
        else
            printf -v retry_command 'bash %q --home %q' "$install_home/install.sh" "$install_home"
        fi
        printf -v branch_arg ' --branch=%q' "$branch"
        retry_command+=$branch_arg
        if [ -n "$proxy" ] || [ "$proxy_set" = x ]; then
            printf -v proxy_arg ' --gh-proxy=%q' "$proxy"
            retry_command+=$proxy_arg
        fi
        if [ "$requested_service" != auto ]; then
            printf -v arg ' --service=%q' "$requested_service"
            retry_command+=$arg
        fi
        printf '\n安装未完成，已保留目录：%s\n' "$install_home" >&2
        printf '\n重试:\n  %s\n' "$retry_command" >&2
        if [ -n "$_INSTALL_DOWNLOAD_FAILED_URL" ] && [ -n "$_INSTALL_DOWNLOAD_FAILED_TARGET" ]; then
            printf '\n手动下载安装包:\n  下载地址: %s\n  保存位置: %s\n  保存完整安装包后，执行上述重试命令。\n' \
                "$_INSTALL_DOWNLOAD_FAILED_URL" "$_INSTALL_DOWNLOAD_FAILED_TARGET" >&2
        fi
        return 1
    fi
    rm -f -- "$install_home/.clashctl-incomplete" || return 1
    service_switch_pending=false
    _install_complete
)

# 完整读取脚本后才执行，下载中断时不会提前开始安装。
if [ "${CLASHCTL_INSTALL_RUNNING:-}" != 1 ] &&
    { [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; }; then
    main "$@"
fi
