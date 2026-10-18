#!/usr/bin/env bash

# 已安装时存在；install.sh 首跑物化前（依赖下载阶段）暂缺
if [ -f "$CLASHCTL_HOME/.env" ]; then
    . "$CLASHCTL_HOME/.env" || return 1
fi

for lib_file in "$CLASHCTL_SRC"/scripts/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    # shellcheck disable=SC1090
    . "$lib_file"
done

# 查询最新版本失败时使用已知可用版本。
DEFAULT_VERSION_MIHOMO=v1.19.27
DEFAULT_VERSION_YQ=v4.53.3
DEFAULT_VERSION_SUBCONVERTER=v0.9.9
DEFAULT_VERSION_UI=v3.20.0

ZIP_BASE_DIR="${CLASHCTL_SRC}/archives"

valid_required() {
    local required_cmds=(curl tar unzip gzip shuf od timeout)
    local missing=()

    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" >&/dev/null || missing+=("$cmd")
    done

    command -v ss >&/dev/null || command -v netstat >&/dev/null || missing+=("ss/netstat")
    command -v ip >&/dev/null || command -v hostname >&/dev/null || missing+=("ip/hostname")

    if [ ${#missing[@]} -gt 0 ]; then
        _ui_error "缺少安装所需的系统命令"
        _ui_detail "缺少" "${missing[*]}"
        _ui_detail "处理" "安装上述命令后重新运行安装脚本"
        return 1
    fi
    return 0
}

prepare_zip() {
    # 首次安装与按需补装共用；下载结果仅在本次调用内有效。
    _INSTALL_DOWNLOAD_FAILED_URL='' _INSTALL_DOWNLOAD_FAILED_TARGET=''
    local -a normalized=()
    local item system_yq kernel_version ZIP_KERNEL='' ZIP_YQ='' ZIP_SUBCONVERTER='' ZIP_UI='' ZIP_KERNEL_LOCAL=0
    for item in "$@"; do
        [ "$item" != kernel ] || item=$CLASHCTL_KERNEL
        [ "$item" != mihomo ] || _mihomo_install_path_available || return 1
        if [ "$item" = mihomo ] && _managed_directory_is_safe "$BIN_BASE_DIR" &&
            _component_file_is_safe "$BIN_KERNEL" 755 &&
            kernel_version=$(_mihomo_binary_version "$BIN_KERNEL"); then
            _ui_ok "使用已安装的 mihomo $kernel_version"
            [ "${_INSTALL_VERBOSE:-}" != 1 ] || _ui_detail '文件' "$BIN_KERNEL"
            continue
        fi
        # 系统 yq 兼容且本地未下载时复用系统副本，跳过下载（bin/yq 存在则照常刷新）
        if [ "$item" = yq ] && [ ! -x "${BIN_BASE_DIR}/yq" ] &&
            system_yq=$(_get_system_yq); then
            _ui_info "使用系统 yq: $system_yq"
            continue
        fi
        normalized+=("$item")
    done
    if [ ${#normalized[@]} -eq 0 ]; then
        _ui_ok '依赖组件已就绪'
        return 0
    fi

    download_zip "${normalized[@]}" || return 1
    unzip_zip
}

_mihomo_install_path_available() {
    [ ! -d "$BIN_KERNEL" ] && return 0
    _ui_error 'mihomo 程序路径被目录占用'
    _ui_detail '路径' "$BIN_KERNEL"
    _ui_detail '处理' '请备份并移走该目录，然后重新执行安装命令'
    return 1
}

_mihomo_binary_version() {
    local file=$1 banner version
    [ -f "$file" ] && [ ! -L "$file" ] && [ -x "$file" ] || return 1
    banner=$(timeout 3 "$file" -v 2>/dev/null) || return 1
    banner=${banner%%$'\n'*}
    case $banner in
    'Mihomo Meta '* | 'Clash Meta '*) version=${banner#* Meta } ;;
    'Mihomo '*) version=${banner#Mihomo } ;;
    *) return 1 ;;
    esac
    version=${version%% *}
    [ -n "$version" ] || return 1
    printf '%s\n' "$version"
}

_mihomo_cpu_level() {
    local flags level=v1
    flags=$(grep -m1 '^flags' /proc/cpuinfo) || flags=''
    if grep -qw sse4_2 <<<"$flags" && grep -qw popcnt <<<"$flags"; then
        level=v2
        if grep -qw avx2 <<<"$flags" && grep -qw fma <<<"$flags"; then
            level=v3
        fi
    fi
    printf '%s\n' "$level"
}

_find_mihomo_archive() {
    local arch=$1 level=$2 file name variant rank
    local -a candidates=()
    for file in "$ZIP_BASE_DIR"/mihomo-linux-*.gz; do
        if [ ! -f "$file" ] || [ -L "$file" ]; then continue; fi
        name=${file##*/}
        [[ $name =~ ^mihomo-linux-(amd64(-v([123]))?|386|arm64|armv7)-(v[0-9]+\.[0-9]+\.[0-9]+)\.gz$ ]] || continue
        variant=${BASH_REMATCH[1]}
        rank=${BASH_REMATCH[3]:-1}
        if [ "$arch" = amd64 ]; then
            case $variant in amd64 | amd64-v[123]) ;; *) continue ;; esac
            [ "$rank" -le "${level#v}" ] || continue
        else
            [ "$variant" = "$arch" ] || continue
        fi
        if ! _archive_is_valid "$file"; then
            _ui_warn "本地安装包不完整或已损坏，已跳过：$name"
            continue
        fi
        candidates+=("$file")
    done
    case ${#candidates[@]} in
    0) return 1 ;;
    1) printf '%s\n' "${candidates[0]}" ;;
    *)
        _ui_error '发现多个适用的 mihomo 安装包'
        for file in "${candidates[@]}"; do _ui_detail '文件' "$file"; done
        _ui_detail '建议' '请在 archives 中仅保留需要使用的一份安装包，然后重新执行安装命令'
        return 2 ;;
    esac
}

# 最新版查询与下载同走 GH_PROXY 通道；代理查询失败后回退直连。
_fetch_latest_tag() {
    local repo=$1 url body tag
    local direct_url="https://api.github.com/repos/${repo}/releases/latest"
    local -a urls=("$direct_url")
    [ -z "${GH_PROXY:-}" ] || urls=("$(gh_proxy_url "$direct_url")" "$direct_url")
    for url in "${urls[@]}"; do
        body=$(curl -sSL --fail --connect-timeout 4 --max-time 12 --retry 1 \
            -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null) || continue
        tag=$(printf '%s' "$body" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 |
            sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')
        [ -n "$tag" ] && {
            printf '%s\n' "$tag"
            return 0
        }
    done
    return 1
}

_resolve_version() {
    local varname=$1 repo=$2 tag local_version default_var

    if typeset -f _install_ui_output >/dev/null 2>&1; then
        _ui_info "查询 ${repo##*/} 最新版本"
    fi
    # 版本来源优先级：最新版本查询 > 内置备用版本
    if tag=$(_fetch_latest_tag "$repo"); then
        printf -v "$varname" '%s' "$tag"
        printf -v "${varname}_SOURCE" '%s' '最新版本'
        if ! typeset -f _install_ui_output >/dev/null 2>&1 || [ "${_INSTALL_VERBOSE:-}" = 1 ]; then
            _ui_detail "$repo" "$tag（最新版本）"
        fi
        return 0
    fi

    default_var=DEFAULT_$varname
    local_version=${!default_var}
    if [ "${CLASHCTL_LATEST_VERSION_FALLBACK_WARNED:-0}" -eq 0 ]; then
        _ui_warn "无法查询部分组件的最新版本，改用内置版本"
        CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=1
    fi
    printf -v "$varname" '%s' "$local_version"
    printf -v "${varname}_SOURCE" '%s' '内置版本'
    if ! typeset -f _install_ui_output >/dev/null 2>&1 || [ "${_INSTALL_VERBOSE:-}" = 1 ]; then
        _ui_detail "$repo" "$local_version（内置版本）"
    fi
    return 0
}

_archive_is_valid() {
    local archive=$1
    local expected=${archive%.part}

    [ -f "$archive" ] && [ ! -L "$archive" ] && [ -s "$archive" ] || return 1
    case $expected in
    *.zip) unzip -tqq "$archive" >/dev/null 2>&1 ;;
    *.tar.gz | *.tgz) tar -tzf "$archive" >/dev/null 2>&1 ;;
    *.gz) gzip -tq "$archive" >/dev/null 2>&1 ;;
    *) gzip -tq "$archive" >/dev/null 2>&1 || unzip -tqq "$archive" >/dev/null 2>&1 ;;
    esac
}

_managed_directory_is_safe() {
    local path=$1 metadata mode

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    metadata=$(stat -c '%u:%a' -- "$path" 2>/dev/null) || return 1
    mode=${metadata#*:}
    [ "${metadata%%:*}" -eq "$EUID" ] &&
        [ $((8#$mode & 0700)) -eq $((8#700)) ] &&
        [ $((8#$mode & 0022)) -eq 0 ]
}

_managed_directory_prepare() {
    local path=$1 mode=${2:-0755}

    if [ -e "$path" ] || [ -L "$path" ]; then
        _managed_directory_is_safe "$path"
        return
    fi
    /usr/bin/install -d -m "$mode" -- "$path" || return 1
    _managed_directory_is_safe "$path"
}

_managed_cache_file_discard() {
    local archive=$1 owner cache_dir archive_dir archive_parent

    _managed_directory_is_safe "$ZIP_BASE_DIR" || return 2
    [ -f "$archive" ] && [ ! -L "$archive" ] || return 2
    owner=$(stat -c %u -- "$archive" 2>/dev/null) || return 2
    [ "$owner" -eq "$(id -u)" ] || return 2

    cache_dir=$(cd -P -- "$ZIP_BASE_DIR" 2>/dev/null && pwd -P) || return 2
    archive_parent=$(dirname -- "$archive") || return 2
    archive_dir=$(cd -P -- "$archive_parent" 2>/dev/null && pwd -P) || return 2
    [ "$archive_dir" = "$cache_dir" ] || return 2

    command rm -f -- "$archive" || return 1
    [ ! -e "$archive" ] && [ ! -L "$archive" ]
}

_component_discard_invalid_cache() {
    local label=$1 archive=$2 discard_rc=0

    _managed_cache_file_discard "$archive" || discard_rc=$?
    if [ "$discard_rc" -eq 0 ]; then
        _ui_warn "已废弃布局无效的依赖缓存：$label"
        _ui_detail "缓存" "$archive"
        _ui_detail "重试" "重新运行安装；安装器将重新下载该组件"
    else
        _ui_warn "布局无效的依赖缓存未被删除：$label"
        _ui_detail "缓存" "$archive"
        if [ "$discard_rc" -eq 2 ]; then
            _ui_detail "原因" "路径、归属或文件类型未通过托管缓存安全校验"
        else
            _ui_detail "原因" "删除缓存文件失败"
        fi
        _ui_detail "处理" "检查该文件后手动移除，再重新运行安装"
    fi
    return 0
}

_cache_token() {
    local value=$1
    value=${value//\//_}
    value=${value// /_}
    printf '%s' "$value"
}

_download_archive_output() {
    if [ "${_INSTALL_VERBOSE:-}" = 1 ]; then
        cat >&2
        return
    fi

    # curl 用回车刷新进度条；按回车读取可实时保留进度，同时隐藏原始错误。
    local chunk='' progress=0
    while IFS= read -r -d $'\r' chunk || [ -n "$chunk" ]; do
        if [ "$progress" -eq 1 ]; then
            case "$chunk" in
            *curl:*)
                chunk=${chunk%%curl:*}
                printf '\r%s\n' "${chunk%$'\n'}" >&2
                ;;
            *) printf '\r%s' "$chunk" >&2 ;;
            esac
        fi
        progress=1
    done
}

_download_archive_fetch() {
    local url=$1 part=$2
    shift 2
    local download_rc http_code resumed attempt=0 restarted=0 retryable reason

    while :; do
        resumed=0
        if [ -s "$part" ]; then
            resumed=1
            [ "$attempt" -ne 0 ] || _ui_info '检测到上次未完成的下载，继续下载'
        fi
        download_rc=0
        # curl 内置重试会回退本轮新增的字节；每轮独立调用才能从最新位置续传。
        http_code=$(curl "$@" --retry 0 --continue-at - --write-out '%{http_code}' \
            --output "$part" --url "$url" 2> >(_download_archive_output)) || download_rc=$?

        # 部分 curl 版本在续传收到 HTTP 416 时仍返回 0，必须单独判断。
        if [ "$resumed" -eq 1 ] && [ "$restarted" -eq 0 ] &&
            { [ "$download_rc" -eq 33 ] || [ "$http_code" = 416 ]; }; then
            _ui_warn '无法继续上次的下载，将从头重新下载'
            command rm -f -- "$part" || return 1
            restarted=1
            continue
        fi
        [ "$http_code" != 416 ] || download_rc=22
        [ "$download_rc" -ne 0 ] || return 0

        retryable=0
        case "$download_rc" in
        5 | 6 | 7 | 18 | 28 | 52 | 55 | 56) retryable=1 ;;
        22)
            case "$http_code" in
            408 | 429 | 500 | 502 | 503 | 504 | 522 | 524) retryable=1 ;;
            esac
            ;;
        esac
        if [ "$attempt" -ge 1 ] || [ "$retryable" -eq 0 ]; then
            return "$download_rc"
        fi
        attempt=$((attempt + 1))
        case "$download_rc" in
        28) reason='下载超时' ;;
        18 | 52 | 55 | 56) reason='下载连接中断' ;;
        *) reason='暂时无法完成下载' ;;
        esac
        if [ -s "$part" ]; then
            _ui_warn "$reason，1 秒后继续下载（自动重试 1/1）"
        else
            _ui_warn "$reason，1 秒后自动重试（1/1）"
        fi
        sleep 1
    done
}

_download_archive_failure_hint() {
    if [ "${_INSTALL_DEFER_DOWNLOAD_HINT:-0}" = 1 ]; then
        _INSTALL_DOWNLOAD_FAILED_URL=$1 _INSTALL_DOWNLOAD_FAILED_TARGET=$2
        return 0
    fi
    printf '\n手动下载安装包:\n  下载地址: %s\n  保存位置: %s\n  保存完整安装包后，重新执行原命令。\n' \
        "$1" "$2" >&2
}

_download_archive() {
    local label=$1 url=$2 target=$3 failure_label
    _INSTALL_DOWNLOAD_FAILED_URL='' _INSTALL_DOWNLOAD_FAILED_TARGET=''
    failure_label=${label%%（*}
    local download_url download_rc=0 part_complete=0
    download_url=$(gh_proxy_url "$url")
    local part="${target}.part"
    local -a curl_args=(
        --show-error
        --fail
        --location
        --connect-timeout 15
        --speed-limit 1024
        --speed-time 60
        --max-time "$CLASHCTL_DOWNLOAD_TIMEOUT"
    )

    if _archive_is_valid "$target"; then
        _ui_ok "$label 使用本地安装包"
        if ! typeset -f _install_ui_output >/dev/null 2>&1 || [ "${_INSTALL_VERBOSE:-}" = 1 ]; then
            _ui_detail "文件" "$target"
        else
            _ui_detail "文件" "${target##*/}"
        fi
        return 0
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then
        _ui_warn "本地安装包不完整或已损坏，将重新下载：$label"
        _ui_detail "文件" "$target"
        command rm -f -- "$target" || {
            _ui_error "无法删除损坏的安装包：$label"
            _ui_detail '建议' '请检查文件和目录权限后重试'
            return 1
        }
    fi
    # 仅续写当前用户所有的单链接普通文件，避免跟随符号链接或修改外部硬链接。
    if { [ -e "$part" ] || [ -L "$part" ]; } &&
        { [ ! -f "$part" ] || [ -L "$part" ] ||
            [ "$(stat -c '%u:%h' -- "$part" 2>/dev/null)" != "$(id -u):1" ]; }; then
        command rm -f -- "$part" || {
            _ui_error "无法清理未完成的下载文件：$label"
            _ui_detail '文件' "$part"
            _ui_detail '建议' '请检查文件和目录权限后重试'
            return 1
        }
    fi

    if [ -t 2 ] && { [ "${_INSTALL_VERBOSE:-}" = 1 ] ||
        typeset -f _install_ui_output >/dev/null 2>&1; }; then
        curl_args+=(--progress-bar)
    else
        curl_args+=(--silent)
    fi

    if _archive_is_valid "$part"; then
        part_complete=1
        _ui_info "使用上次已下载完成的安装包：$label"
    else
        _ui_info "下载 $label"
    fi
    if ! typeset -f _install_ui_output >/dev/null 2>&1 || [ "${_INSTALL_VERBOSE:-}" = 1 ]; then
        _ui_detail "下载地址" "$download_url"
    else
        _ui_detail "文件" "${target##*/}"
    fi
    if [ "$part_complete" -eq 0 ] && [ -n "${GH_PROXY:-}" ]; then
        _ui_detail '加速代理' "$GH_PROXY"
    fi
    # 中断发生在下载完成之后时，完整的 .part 可以直接校验并采用。
    if [ "$part_complete" -eq 0 ]; then
        _download_archive_fetch "$download_url" "$part" "${curl_args[@]}" || download_rc=$?
    fi
    if [ "$download_rc" -ne 0 ]; then
        if [ "$download_rc" -eq 28 ]; then
            # shellcheck disable=SC2034  # 安装入口在下载失败后读取此状态生成重试命令。
            CLASHCTL_DOWNLOAD_TIMED_OUT=1
            if [ "$CLASHCTL_DOWNLOAD_TIMEOUT" = 0 ]; then
                _ui_error "$failure_label 下载超时"
            else
                _ui_error "$failure_label 下载超时（单次限时 $CLASHCTL_DOWNLOAD_TIMEOUT 秒）"
            fi
        else
            _ui_error "$failure_label 下载失败"
        fi
        if [ -s "$part" ]; then
            _ui_detail '进度' '已保留，重试时继续下载'
        fi
        if [ "$download_rc" -eq 28 ]; then
            if [ "$CLASHCTL_DOWNLOAD_TIMEOUT" = 0 ]; then
                _ui_detail '原因' '连接超过 15 秒，或下载速度连续 60 秒低于 1 KiB/s'
                if [ -n "${GH_PROXY:-}" ]; then
                    _ui_detail '建议' '请检查网络或更换加速代理后重试'
                else
                    _ui_detail '建议' '请检查网络后重试，也可使用加速代理'
                fi
            else
                local proxy_action='使用加速代理'
                [ -z "${GH_PROXY:-}" ] || proxy_action='更换加速代理'
                _ui_detail '建议' "延长单次下载时限，或$proxy_action"
            fi
        else
            case "$download_rc" in
            5 | 6) _ui_detail '原因' '无法解析下载服务器地址，请检查网络或代理设置' ;;
            7) _ui_detail '原因' '无法连接下载服务器，请检查网络或稍后重试' ;;
            18 | 52 | 55 | 56) _ui_detail '原因' '下载连接中断，请稍后重试或更换下载地址' ;;
            23) _ui_detail '原因' '无法保存下载文件，请检查磁盘空间和目录权限' ;;
            35 | 60) _ui_detail '原因' '无法建立安全连接，请检查系统时间、证书或代理设置' ;;
            *)
                if [ -n "${GH_PROXY:-}" ]; then
                    _ui_detail '建议' '请检查或更换加速代理，也可尝试直连'
                else
                    _ui_detail '建议' '请检查网络后重试，也可用 --gh-proxy 指定加速代理'
                fi
                ;;
            esac
        fi
        _download_archive_failure_hint "$download_url" "$target"
        return 1
    fi
    if ! _archive_is_valid "$part"; then
        _ui_error "下载的安装包不完整或已损坏：$label"
        # 下载已完成仍校验失败，不能继续复用这份残片。
        command rm -f -- "$part" || _ui_warn "无法删除损坏的下载文件：$part"
        _ui_detail '建议' '请重新运行刚才的命令，重新下载文件'
        _download_archive_failure_hint "$download_url" "$target"
        return 1
    fi
    if ! /bin/mv -f -- "$part" "$target"; then
        _ui_error "无法保存安装包：$label"
        _ui_detail "目标" "$target"
        _ui_detail '建议' '请检查磁盘空间和目录权限后重试'
        return 1
    fi

    if typeset -f _install_ui_output >/dev/null 2>&1; then
        _ui_ok '下载完成，文件检查通过'
    else
        _ui_ok "$label 下载完成，文件检查通过"
    fi
    return 0
}

download_zip() {
    _INSTALL_DOWNLOAD_FAILED_URL='' _INSTALL_DOWNLOAD_FAILED_TARGET=''
    _managed_directory_prepare "$ZIP_BASE_DIR" 0755 || {
        _ui_error "依赖缓存目录无法安全使用"
        _ui_detail "目录" "$ZIP_BASE_DIR"
        _ui_detail "要求" "必须是当前用户所有的真实目录，且组用户和其他用户不可写"
        return 1
    }
    local arch mihomo_arch='' yq_arch sub_arch level=v1 mihomo_archive='' archive_rc=0
    arch=$(uname -m) || {
        _ui_error "无法检测系统架构"
        return 1
    }
    case "$arch" in
    x86_64) mihomo_arch=amd64 yq_arch=amd64 sub_arch=linux64; level=$(_mihomo_cpu_level) ;;
    *86*) mihomo_arch=386 yq_arch=386 sub_arch=linux32 ;;
    armv*) mihomo_arch=armv7 yq_arch=arm sub_arch=armv7 ;;
    aarch64) mihomo_arch=arm64 yq_arch=arm64 sub_arch=aarch64 ;;
    esac

    CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=0
    local item
    for item in "$@"; do
        case $item in
        mihomo)
            archive_rc=0
            mihomo_archive=$(_find_mihomo_archive "$mihomo_arch" "$level") || archive_rc=$?
            case $archive_rc in
            0)
                VERSION_MIHOMO=${mihomo_archive##*-}
                VERSION_MIHOMO=${VERSION_MIHOMO%.gz}
                # shellcheck disable=SC2034  # 组件标签通过变量名间接读取来源。
                VERSION_MIHOMO_SOURCE='本地安装包'
                ;;
            1) _resolve_version VERSION_MIHOMO MetaCubeX/mihomo || return 1 ;;
            *) return 1 ;;
            esac
            ;;
        yq) _resolve_version VERSION_YQ mikefarah/yq || return 1 ;;
        subconverter) _resolve_version VERSION_SUBCONVERTER "$SUBCONVERTER_REPO" || return 1 ;;
        ui) _resolve_version VERSION_UI Zephyruso/zashboard || return 1 ;;
        *)
            _ui_error "未知依赖组件：$item"
            return 1
            ;;
        esac
    done

    [ -n "$mihomo_arch" ] || {
        _ui_error "不支持的系统架构：$arch"
        _ui_detail "缓存目录" "$ZIP_BASE_DIR"
        return 1
    }
    local mihomo_variant=$mihomo_arch
    [ "$mihomo_arch" != amd64 ] || mihomo_variant+="-$level"
    local url target label version_token version_source_var

    for item in "$@"; do
        case $item in
        mihomo)
            url="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-${mihomo_variant}-${VERSION_MIHOMO##*-}.gz"
            ZIP_KERNEL_LOCAL=0
            if [ -n "$mihomo_archive" ]; then
                target=$mihomo_archive
                url="https://github.com/MetaCubeX/mihomo/releases/download/$VERSION_MIHOMO/${target##*/}"
                ZIP_KERNEL_LOCAL=1
            else
                target="${ZIP_BASE_DIR}/$(basename -- "$url")"
            fi
            label="mihomo ${VERSION_MIHOMO}"
            ;;
        yq)
            url="https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_${yq_arch}.tar.gz"
            version_token=$(_cache_token "$VERSION_YQ")
            target="${ZIP_BASE_DIR}/yq-${version_token}-${arch}.tar.gz"
            label="yq ${VERSION_YQ}"
            ;;
        subconverter)
            url="https://github.com/${SUBCONVERTER_REPO}/releases/download/${VERSION_SUBCONVERTER}/subconverter_${sub_arch}.tar.gz"
            version_token=$(_cache_token "$VERSION_SUBCONVERTER")
            target="${ZIP_BASE_DIR}/subconverter-${version_token}-${arch}.tar.gz"
            label="subconverter ${VERSION_SUBCONVERTER}"
            ;;
        ui)
            url="https://github.com/Zephyruso/zashboard/releases/download/${VERSION_UI}/dist.zip"
            version_token=$(_cache_token "$VERSION_UI")
            target="${ZIP_BASE_DIR}/dist-${version_token}.zip"
            label="zashboard ${VERSION_UI}"
            ;;
        esac

        if typeset -f _install_ui_output >/dev/null 2>&1 &&
            [ "${_INSTALL_VERBOSE:-}" != 1 ]; then
            version_source_var="VERSION_${item^^}_SOURCE"
            case ${!version_source_var:-} in
            '' | 本地安装包) ;;
            *) label+="（${!version_source_var}）" ;;
            esac
        fi
        _download_archive "$label" "$url" "$target" || return 1
        case $item in
        mihomo) ZIP_KERNEL=$target ;;
        yq) ZIP_YQ=$target ;;
        subconverter) ZIP_SUBCONVERTER=$target ;;
        ui) ZIP_UI=$target ;;
        esac
    done
    return 0
}

_component_file_is_safe() {
    local path=$1 expected_mode=$2 metadata

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    metadata=$(stat -c '%u:%a' -- "$path" 2>/dev/null) || return 1
    [ "$metadata" = "$EUID:$expected_mode" ]
}

_component_tree_is_safe() {
    local root=$1 unexpected

    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    unexpected=$(find "$root" \
        \( ! -user "$EUID" -o \( ! -type d ! -type f \) -o -perm /022 \) \
        -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ]
}

_component_public_tree_is_safe() {
    local root=$1 unexpected

    _component_tree_is_safe "$root" || return 1
    unexpected=$(find "$root" \
        \( \( -type d ! -perm 0755 \) -o \( -type f ! -perm 0644 \) \) \
        -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ]
}

_component_subconverter_is_safe() {
    local root=$1

    _component_tree_is_safe "$root" || return 1
    _component_file_is_safe "$root/subconverter" 755 || return 1
    _component_file_is_safe "$root/pref.yml" 600
}

_component_normalize_public_tree() {
    local root=$1

    find "$root" -type d -exec chmod 0755 -- {} + &&
        find "$root" -type f -exec chmod 0644 -- {} +
}

_component_extract_tar() {
    local archive=$1 destination=$2

    tar --extract --no-same-owner --no-same-permissions \
        --file "$archive" --directory "$destination"
}

_component_prepare_yq() {
    local archive=$1 stage=$2
    local extract_dir="$stage/yq.extract"
    local candidate='' count=0 path

    /usr/bin/install -d -m 0700 -- "$extract_dir" || return 1
    _component_extract_tar "$archive" "$extract_dir" || return 1
    while IFS= read -r -d '' path; do
        candidate=$path
        count=$((count + 1))
    done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -type f \
        -name 'yq_linux_*' -print0)
    [ "$count" -eq 1 ] && [ -n "$candidate" ] && [ ! -L "$candidate" ] &&
        [ -x "$candidate" ] || return 2
    /usr/bin/install -m 0755 -- "$candidate" "$stage/yq.ready" || return 1
}

_component_prepare_subconverter() {
    local archive=$1 stage=$2
    local extract_dir="$stage/subconverter.extract"
    local candidate="$extract_dir/subconverter" unexpected

    /usr/bin/install -d -m 0700 -- "$extract_dir" || return 1
    _component_extract_tar "$archive" "$extract_dir" || return 1
    unexpected=$(find "$extract_dir" -mindepth 1 -maxdepth 1 \
        ! -name subconverter -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ] && [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 2
    [ -f "$candidate/subconverter" ] && [ ! -L "$candidate/subconverter" ] || return 2
    [ -f "$candidate/pref.example.yml" ] && [ ! -L "$candidate/pref.example.yml" ] || return 2
    _component_normalize_public_tree "$candidate" || return 1
    chmod 0755 -- "$candidate/subconverter" || return 1
    /usr/bin/install -m 0600 -- "$candidate/pref.example.yml" \
        "$candidate/pref.yml" || return 1
}

_component_prepare_ui() {
    local archive=$1 stage=$2
    local extract_dir="$stage/ui.extract"
    local candidate="$extract_dir/dist" unexpected

    /usr/bin/install -d -m 0700 -- "$extract_dir" || return 1
    unzip -oqq "$archive" -d "$extract_dir" 2>/dev/null || return 1
    unexpected=$(find "$extract_dir" -mindepth 1 -maxdepth 1 \
        ! -name dist -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ] && [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 2
    [ -f "$candidate/index.html" ] && [ ! -L "$candidate/index.html" ] || return 2
    _component_normalize_public_tree "$candidate" || return 1
}

# 使用 _install_component 子 shell 的局部状态，只恢复正在替换的组件。
_component_cleanup() {
    [ -n "$stage" ] || return 0
    if [ "$pending" = true ]; then
        if [ -e "$stage/previous" ] || [ -L "$stage/previous" ]; then
            if ! command rm -rf -- "$target" ||
                ! /bin/mv -T -- "$stage/previous" "$target"; then
                _ui_error "组件恢复失败，已保留暂存目录"
                _ui_detail "暂存" "$stage"
                return 1
            fi
        elif [ "$had_previous" = false ]; then
            command rm -rf -- "$target" || return 1
        fi
    fi
    command rm -rf -- "$stage"
}

_install_component() (
    local component=$1 archive=$2 target root label parent stage='' candidate kernel_version
    local pending=false had_previous=false prepare_rc=0
    local -a verifier
    umask 077
    case "$component" in
    kernel)
        target=$BIN_KERNEL root=$BIN_BASE_DIR label=运行组件目录
        _mihomo_install_path_available || return 1
        verifier=(_component_file_is_safe 755)
        ;;
    yq)
        target=$BIN_YQ root=$BIN_BASE_DIR label=运行组件目录
        verifier=(_component_file_is_safe 755)
        ;;
    subconverter)
        target=$BIN_SUBCONVERTER_DIR root=$BIN_BASE_DIR label=运行组件目录
        verifier=(_component_subconverter_is_safe)
        ;;
    ui)
        target="$CLASH_RESOURCES_DIR/dist" root=$CLASH_RESOURCES_DIR label=资源目录
        verifier=(_component_public_tree_is_safe)
        ;;
    *) return 1 ;;
    esac
    _managed_directory_prepare "$root" 0755 || {
        _ui_error "${label}无法安全使用"
        _ui_detail "目录" "$root"
        return 1
    }
    parent=$(dirname -- "$target")
    [ "$parent" = "$root" ] || _managed_directory_prepare "$parent" 0755 || {
        _ui_error "组件安装目录无法安全使用"
        _ui_detail "目录" "$parent"
        return 1
    }
    trap '_component_cleanup || exit 1' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stage=$(mktemp -d "$parent/.components.XXXXXX") || return 1
    case "$component" in
    kernel)
        candidate="$stage/kernel.ready"
        gzip -dc "$archive" >"$candidate" && chmod 0755 -- "$candidate" || prepare_rc=1
        if [ "$prepare_rc" -eq 0 ] && [ "${ZIP_KERNEL_LOCAL:-0}" = 1 ]; then
            if ! kernel_version=$(_mihomo_binary_version "$candidate"); then
                _ui_error '本地安装包中的 mihomo 无法运行或无法识别'
                _ui_detail '文件' "$archive"
                return 1
            fi
            if [ "$kernel_version" != "$VERSION_MIHOMO" ]; then
                _ui_error '安装包文件名与 mihomo 实际版本不一致'
                _ui_detail '文件' "$archive"
                _ui_detail '实际版本' "$kernel_version"
                return 1
            fi
        fi
        ;;
    yq)
        candidate="$stage/yq.ready"
        _component_prepare_yq "$archive" "$stage" || prepare_rc=$?
        ;;
    subconverter)
        candidate="$stage/subconverter.extract/subconverter"
        _component_prepare_subconverter "$archive" "$stage" || prepare_rc=$?
        ;;
    ui)
        candidate="$stage/ui.extract/dist"
        _component_prepare_ui "$archive" "$stage" || prepare_rc=$?
        ;;
    esac
    if [ "$prepare_rc" -ne 0 ]; then
        if [ "$prepare_rc" -eq 2 ]; then
            _ui_error "$component 归档结构无效"
            _component_discard_invalid_cache "$component" "$archive"
        else
            _ui_error "准备 $component 失败"
        fi
        return 1
    fi
    "${verifier[0]}" "$candidate" "${verifier[@]:1}" || {
        _ui_error "$component 文件的归属或权限校验失败"
        return 1
    }

    [ ! -e "$target" ] && [ ! -L "$target" ] || had_previous=true
    pending=true
    if [ "$had_previous" = true ]; then
        /bin/mv -T -- "$target" "$stage/previous" || return 1
    fi
    if ! /bin/mv -T -- "$candidate" "$target" ||
        ! "${verifier[0]}" "$target" "${verifier[@]:1}"; then
        _ui_error "安装 $component 失败，正在恢复原组件"
        return 1
    fi
    pending=false
)

unzip_zip() {
    local component archive
    for component in kernel yq subconverter ui; do
        case "$component" in
        kernel) archive=${ZIP_KERNEL:-} ;;
        yq) archive=${ZIP_YQ:-} ;;
        subconverter) archive=${ZIP_SUBCONVERTER:-} ;;
        ui) archive=${ZIP_UI:-} ;;
        esac
        [ -n "$archive" ] || continue
        _install_component "$component" "$archive" || return 1
    done
    _ui_ok "运行组件已安装"
}

apply_rc() {
    detect_rc

    local rc rc_status shell_name detail configured=()
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ -f "$rc" ] || continue

        rc_status=0
        _append_source_block "$rc" || rc_status=$?
        if [ "$rc_status" -eq 2 ]; then
            _ui_error "Shell 配置中的 clashctl 托管标记不完整，已保留原文件"
            _ui_detail "文件" "$rc"
            return 1
        elif [ "$rc_status" -ne 0 ]; then
            _ui_error "无法更新 Shell 配置"
            _ui_detail "文件" "$rc"
            return 1
        fi
        configured+=("$rc")
    done

    if [ -n "$SHELL_RC_FISH" ]; then
        rc_status=0
        _write_fish_rc || rc_status=$?
        if [ "$rc_status" -eq 3 ]; then
            _ui_error "Fish 配置不是 clashctl 托管文件，已保留原文件"
            _ui_detail "文件" "$SHELL_RC_FISH"
            return 1
        elif [ "$rc_status" -ne 0 ]; then
            _ui_error "无法更新 Shell 配置"
            _ui_detail "文件" "$SHELL_RC_FISH"
            return 1
        fi
        configured+=("$SHELL_RC_FISH")
    fi

    if [ ${#configured[@]} -gt 0 ]; then
        _ui_ok "终端命令已配置"
        for rc in "${configured[@]}"; do
            case "$rc" in
            "$SHELL_RC_BASH") shell_name=Bash ;;
            "$SHELL_RC_ZSH") shell_name=Zsh ;;
            *) shell_name=Fish ;;
            esac
            printf -v detail '%-5s %s' "$shell_name:" "$rc"
            _ui_detail "$detail"
        done
    fi

    [ ${#configured[@]} -gt 0 ] && return 0
    return 2
}
revoke_rc() {
    detect_rc --installed

    local rc failures=0
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ -n "$rc" ] || continue
        _remove_source_block "$rc" || {
            _ui_error "无法清理 Shell 配置"
            _ui_detail "文件" "$rc"
            failures=1
        }
    done

    if [ -n "$SHELL_RC_FISH" ] && [ -e "$SHELL_RC_FISH" ]; then
        if [ ! -L "$SHELL_RC_FISH" ] &&
            [ "$(head -n 1 -- "$SHELL_RC_FISH")" = "$CLASHCTL_FISH_MANAGED_MARKER" ] &&
            [ "$(sed -n '2p' "$SHELL_RC_FISH")" = "$(_fish_home_export)" ]; then
            command rm -f -- "$SHELL_RC_FISH" || {
                _ui_error "无法清理 Fish 配置"
                _ui_detail "文件" "$SHELL_RC_FISH"
                failures=1
            }
        else
            _ui_warn "Fish 配置不属于当前安装或已被修改，已保留"
            _ui_detail "文件" "$SHELL_RC_FISH"
        fi
    fi
    return "$failures"
}
