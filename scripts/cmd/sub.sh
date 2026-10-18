#!/usr/bin/env bash

# ── 术语约定 ──────────────────────────────────────────────────
#   name    订阅名称：用户可见/输入的唯一键，允许中文/emoji/空格
#   path    该订阅在磁盘上的配置文件路径（权威来源，文件名已安全化）
#   use     顶层字段，记录当前生效订阅的 name
#   _sub_   本文件模块前缀
# ─────────────────────────────────────────────────────────────

clashsub() {
    case "${1:-}" in
    -h | --help)
        sub_help
        return 0
        ;;
    esac

    # 订阅命令使用 Bash 数组及文件描述符语法；交给 Bash 子进程执行。
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashsub "$@"
        return
    fi

    local cmd=${1:-}
    [ "$#" -eq 0 ] || shift
    case $cmd in
    add) sub_add "$@" ;;
    del | delete) _sub_del "$@" ;;
    list | ls) _sub_list "$@" ;;
    '')
        # 裸命令：交互终端直接进选择器（选中即切换），管道/脚本下输出表格
        if [ -t 0 ] && [ -t 1 ]; then
            _sub_use
        else
            _sub_list
        fi
        ;;
    use) _sub_use "$@" ;;
    update) _sub_update "$@" ;;
    rename) _sub_rename "$@" ;;
    log) _sub_log "$@" ;;
    *) sub_help ;;
    esac
}

########################################
#            元数据读取
########################################

# 订阅是否存在
_sub_has() {
    PROFILE_NAME=$1 "$BIN_YQ" -e '.profiles // [] | .[] | select(.name == strenv(PROFILE_NAME)) | .name' \
        "$CLASH_PROFILES_META" >/dev/null 2>&1
}

# 取某订阅的字段（field ∈ path|url|updated），不存在则输出空串
_sub_get() {
    PROFILE_NAME=$1 "$BIN_YQ" ".profiles // [] | .[] | select(.name == strenv(PROFILE_NAME)) | .$2 // \"\"" \
        "$CLASH_PROFILES_META" 2>/dev/null
}

# 逐行输出全部订阅名称（保持文件内顺序）
_sub_names() {
    "$BIN_YQ" '.profiles // [] | .[] | .name' "$CLASH_PROFILES_META" 2>/dev/null
}

# 一次性输出全部订阅字段（TSV：name<TAB>url<TAB>updated<TAB>userinfo，单次 yq）
_sub_rows() {
    "$BIN_YQ" '.profiles // [] | .[] | [.name, (.url // ""), (.updated // ""), (.userinfo // "")] | @tsv' \
        "$CLASH_PROFILES_META" 2>/dev/null
}

# 一次性载入全部订阅到全局并行数组（list/pick 共用，替代逐订阅×逐字段的 _sub_get）：
#   _SUB_NAMES/_SUB_URLS/_SUB_UPDS            原始字段（顺序与文件一致）
#   _SUB_TRAFFICS/_SUB_EXPIRES                 由 userinfo 派生的展示列
#   _SUB_CUR                                   当前生效订阅名
# 只取数不渲染，展示形态由调用方决定。
_sub_load() {
    _SUB_NAMES=() _SUB_URLS=() _SUB_UPDS=()
    _SUB_TRAFFICS=() _SUB_EXPIRES=()
    _SUB_CUR=$(_sub_current)

    local name url upd ui tf ex
    while IFS=$'\t' read -r name url upd ui; do
        [ -z "$name" ] && continue
        _SUB_NAMES+=("$name")
        _SUB_URLS+=("$url")
        _SUB_UPDS+=("$upd")
        IFS=$'\t' read -r tf ex < <(_userinfo_display "$ui")
        _SUB_TRAFFICS+=("$tf")
        _SUB_EXPIRES+=("$ex")
    done < <(_sub_rows)
}

# 当前生效订阅的 name
_sub_current() {
    "$BIN_YQ" '.use // "" | tostring' "$CLASH_PROFILES_META" 2>/dev/null
}

# url 是否已存在
_sub_url_exists() {
    PROFILE_URL=$1 "$BIN_YQ" -e '([.profiles // [] | .[] | select(.url == strenv(PROFILE_URL))] | length) > 0' \
        "$CLASH_PROFILES_META" >/dev/null 2>&1
}

_logging_sub() {
    printf '%s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$1" >>"$CLASH_PROFILES_LOG"
}

########################################
#            并发互斥
########################################
# 串行化所有订阅写操作（含 cron 自动更新）：交互与下载在锁外完成，
# 仅把“改元数据 + 落盘”的临界区放进锁内。加锁实现内部禁止再调用本函数
# （临界区之间改用 _xxx_locked 内层函数组合），以免自我死锁。
# 使用原子 mkdir 取得锁；独立子 shell 负责退出时清理，不改变调用方的 trap。
# .d 后缀避开旧版本可能保留的 profiles.lock 普通文件。
_with_profiles_lock() (
    local lock_dir="${CLASH_PROFILES_LOCK}.d" lock_pid='' lock_token='' rc=0
    # 先设置清理：取锁过程收到信号时，由共享实现先完成所有者记录再退出。
    trap 'trap "" HUP INT TERM; _directory_lock_release "$lock_dir" "${lock_pid:-${_DIRECTORY_LOCK_PID:-}}" "${lock_token:-${_DIRECTORY_LOCK_TOKEN:-}}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    _directory_lock_acquire "$lock_dir" 60 || rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ]; then
            _errorcat "另一订阅操作正在进行（可能是定时更新），请稍后再试"
        else
            _errorcat "无法安全创建订阅操作锁，本次未修改订阅"
        fi
        _directory_lock_report "$lock_dir"
        return 1
    fi
    lock_pid=$_DIRECTORY_LOCK_PID
    lock_token=$_DIRECTORY_LOCK_TOKEN
    "$@"
)

# 下载并校验订阅到独立的临时工作文件（mktemp，避免固定路径的并发互踩）。
#   用法：_sub_download <url> <strategy(auto|raw|convert)>
#     auto    下载；原生且有效则直用，否则回退 subconverter 转换（默认）
#     raw     仅下载，绝不转换（校验失败即失败）
#     convert 始终经 subconverter 转换
#   返回：0 表示已下载且通过内核校验；非 0 表示失败。
# 成功后：_SUB_DL_FILE 指向可原子 mv 到目标的工作文件。
# 失败后：产物落到 last-failed.*（供排障）并报错列出它们，
#   _SUB_DL_REASON 为去除颜色码后的最后一行错误（写入日志）
_sub_download() {
    local url=$1 strategy=${2:-auto}
    local work err_log rc
    _SUB_DL_FILE=''
    _SUB_DL_REASON=''
    FETCH_USERINFO='' # 由 _download_raw_config 在成功时填充（机场流量信息）
    FETCH_FILENAME='' # 由 _download_raw_config 在成功时填充（content-disposition 文件名）

    work=$(mktemp "${CLASH_RESOURCES_DIR}/.fetch.XXXXXX") || {
        _errorcat "无法创建临时文件：$CLASH_RESOURCES_DIR"
        return 1
    }
    err_log="${work}.err"

    case $strategy in
    convert) _convert_sub_config "$work" "$url" 2>"$err_log" ;;
    raw) _download_config "$work" "$url" false 2>"$err_log" ;;
    *) _download_config "$work" "$url" true 2>"$err_log" ;;
    esac
    rc=$?
    [ -s "$err_log" ] && cat "$err_log" >&2
    _SUB_DL_REASON=$(sed $'s/\x1b\\[[0-9;]*m//g' "$err_log" 2>/dev/null | awk 'NF{last=$0} END{print last}')
    /usr/bin/rm -f "$err_log"

    [ "$rc" -eq 0 ] && {
        _SUB_DL_FILE=$work
        /usr/bin/rm -f "${work}.raw" # 转换成功遗留的原始订阅，无需保留
        return 0
    }

    # 失败：保留调试产物到稳定路径，并按实际存在的文件拼装提示
    local hint='' converted=false
    { [ "$strategy" = convert ] || [ -f "${work}.raw" ]; } && converted=true
    if [ -s "$work" ]; then
        /bin/mv -f "$work" "$CLASH_CONFIG_DEBUG"
        hint="待检配置：$CLASH_CONFIG_DEBUG"
    else
        /usr/bin/rm -f "$work"
    fi
    [ -f "${work}.raw" ] && {
        /bin/mv -f "${work}.raw" "$CLASH_CONFIG_DEBUG_RAW"
        hint="${hint:+$hint
}原始订阅：$CLASH_CONFIG_DEBUG_RAW"
    }
    [ "$converted" = true ] && hint="${hint:+$hint
}转换日志：$BIN_SUBCONVERTER_LOG"
    _errorcat "订阅无效${hint:+，请检查：
$hint}"
    return "$rc"
}

########################################
#            名称与文件工具
########################################

# 从订阅链接派生默认名称（取 host；file:// → local）
_sub_default_name() {
    local url=$1 host
    case $url in
    file://*) host=local ;;
    *)
        host=${url#*://}
        host=${host%%/*}
        host=${host%%\?*}
        host=${host%%:*}
        ;;
    esac
    [ -z "$host" ] && host=sub
    printf '%s' "$host"
}

# 清洗 content-disposition 文件名为可用订阅名（保留中文等 Unicode）：
# 去扩展名、路径分隔符与控制字符、首尾空白；非法（空/以 - 开头）则输出空串
_sub_sanitize_name() {
    local s=$1
    s=${s%.*}      # 去最后一个扩展名，如 .yaml/.txt
    s=${s//\//_}   # 路径分隔符 → _
    s=$(printf '%s' "$s" | tr -d '\000-\037\177')
    s="${s#"${s%%[![:space:]]*}"}" # 去前导空白
    s="${s%"${s##*[![:space:]]}"}" # 去尾随空白
    case $s in -*) s='' ;; esac
    printf '%s' "$s"
}

# 基于 base 生成未占用的名称（冲突则追加 -2/-3…）
_sub_unique_name() {
    local base=$1 name=$1 n=1
    while _sub_has "$name"; do
        n=$((n + 1))
        name="${base}-${n}"
    done
    printf '%s' "$name"
}

# 校验用户提供的名称
_sub_validate_name() {
    local name=$1
    [ -z "$name" ] && {
        _errorcat "订阅名称不能为空"
        return 1
    }
    case $name in
    -*)
        _errorcat "订阅名称不能以 - 开头：$name"
        return 1
        ;;
    esac
    return 0
}

# 由名称派生安全的磁盘文件路径（非 [A-Za-z0-9._-] → _，冲突追加 -2/-3…）
_sub_filename() {
    local name=$1 safe path n=1
    safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
    path="${CLASH_PROFILES_DIR}/${safe}.yaml"
    while [ -e "$path" ]; do
        n=$((n + 1))
        path="${CLASH_PROFILES_DIR}/${safe}-${n}.yaml"
    done
    printf '%s' "$path"
}

########################################
#            交互式选择
########################################

# 交互选择一个订阅：选中的 name 输出到 stdout，菜单打到 stderr。
# fzf 可用则用 fzf（列表行内嵌流量/到期，链接在 preview），否则数字菜单回退。
_sub_pick() {
    local prompt=$1
    _sub_load

    [ ${#_SUB_NAMES[@]} -eq 0 ] && {
        _errorcat "当前无可用订阅，请先添加订阅"
        return 1
    }
    # 即使只有 1 个订阅也进入选择界面：use 会重启内核、del 为破坏性操作，
    # 需用户明确确认，不做隐式自动选择。

    local i namew trafw
    namew=$(_max_width "${_SUB_NAMES[@]}")
    trafw=$(_max_width "${_SUB_TRAFFICS[@]}")

    # 列标题行（与数据行同宽对齐），fzf 与编号菜单共用
    local col_header
    col_header="$(_pad '名称' "$namew")  $(_pad '流量' "$trafw")  到期"

    local marker
    if _has_fzf; then
        local preview_dir now
        preview_dir=$(_pick_preview_dir)
        if [ -n "$preview_dir" ]; then
            for i in "${!_SUB_NAMES[@]}"; do
                now=否
                [ "${_SUB_NAMES[$i]}" = "$_SUB_CUR" ] && now=是
                {
                    printf '订阅\n'
                    printf '  名称：%s\n' "${_SUB_NAMES[$i]}"
                    printf '  当前：%s\n' "$now"
                    printf '  更新：%s\n' "${_SUB_UPDS[$i]:-—}"
                    printf '  流量：%s\n' "${_SUB_TRAFFICS[$i]}"
                    printf '  到期：%s\n' "${_SUB_EXPIRES[$i]}"
                    printf '  链接：%s\n' "${_SUB_URLS[$i]}"
                } >"$preview_dir/$((i + 1))"
            done
        fi
        for i in "${!_SUB_NAMES[@]}"; do
            marker=' '
            [ "${_SUB_NAMES[$i]}" = "$_SUB_CUR" ] && marker='*'
            printf '%s\t%s\t%s %s  %s  %s\n' \
                "$((i + 1))" \
                "${_SUB_NAMES[$i]}" \
                "$marker" \
                "$(_pad "${_SUB_NAMES[$i]}" "$namew")" \
                "$(_pad "${_SUB_TRAFFICS[$i]}" "$trafw")" \
                "${_SUB_EXPIRES[$i]}"
        done | _pick_fzf "$prompt" "  $col_header
选择订阅，Enter 确认，Esc 退出" "$preview_dir"
        return
    fi

    _hint_fzf

    local idxw=${#_SUB_NAMES[@]}
    idxw=${#idxw} # 序号位数
    # 序号列宽 + 标记列（空格偏移）后输出标题，与数据行对齐
    printf '  %*s   %s\n' "$((idxw + 2))" '' "$col_header" >&2
    for i in "${!_SUB_NAMES[@]}"; do
        marker=' '
        [ "${_SUB_NAMES[$i]}" = "$_SUB_CUR" ] && marker='*'
        printf '  %-*s %s %s  %s  %s\n' \
            $((idxw + 2)) "[$((i + 1))]" \
            "$marker" \
            "$(_pad "${_SUB_NAMES[$i]}" "$namew")" \
            "$(_pad "${_SUB_TRAFFICS[$i]}" "$trafw")" \
            "${_SUB_EXPIRES[$i]}" >&2
    done
    _pick_read "$prompt" "${_SUB_NAMES[@]}"
}

# 解析 add 与 update 共用的选项，结果写入调用方的 strategy、args、help，
# 以及 add 的 name、use_after_add 和 update 的 all。$1 为子命令名。
_sub_parse_opts() {
    local cmd=$1
    shift
    args=()
    while [ $# -gt 0 ]; do
        case "$cmd:$1" in
        update:-u | update:--use | update:-n | update:--name | update:--name=* | add:--all)
            _errorcat "未知选项：$1"
            return 1
            ;;
        esac
        case "$1" in
        -h | --help)
            help=true
            return 0
            ;;
        -u | --use)
            use_after_add=true
            ;;
        --all)
            all=true
            ;;
        --convert | --raw)
            [ "$strategy" = auto ] || [ "$strategy" = "${1#--}" ] || {
                _errorcat "$1 与 --$strategy 互斥"
                return 1
            }
            strategy=${1#--}
            ;;
        -n | --name)
            [ -n "${2-}" ] || {
                _errorcat "选项 $1 需要一个名称参数"
                return 1
            }
            name=$2
            shift
            ;;
        --name=*)
            name="${1#*=}"
            ;;
        -t | --timeout)
            [ -n "${2-}" ] || {
                _errorcat "选项 $1 需要一个超时参数（秒）"
                return 1
            }
            CLASHCTL_SUB_TIMEOUT=$2
            shift
            ;;
        --timeout=*)
            CLASHCTL_SUB_TIMEOUT="${1#*=}"
            ;;
        --ua)
            [ -n "${2-}" ] || {
                _errorcat "选项 $1 需要一个 UA 参数"
                return 1
            }
            # shellcheck disable=SC2034  # 供 scripts/lib/convert.sh 读取
            CLASHCTL_SUB_UA=$2
            shift
            ;;
        --ua=*)
            # shellcheck disable=SC2034  # 供 scripts/lib/convert.sh 读取
            CLASHCTL_SUB_UA="${1#*=}"
            [ -n "$CLASHCTL_SUB_UA" ] || {
                _errorcat "选项 $1 需要一个 UA 参数"
                return 1
            }
            ;;
        --)
            shift
            args+=("$@")
            break
            ;;
        -*)
            _errorcat "未知选项：$1"
            return 1
            ;;
        *)
            args+=("$1")
            ;;
        esac
        shift
    done
}

########################################
#            子命令
########################################

sub_add() {
    local use_after_add=false name='' strategy=auto args help=false url
    _sub_parse_opts add "$@" || return 1
    if [ "$help" = true ]; then
        cat <<EOF

Usage:
  clashctl sub add [选项] [URL]

下载并校验订阅，成功后保存；默认不启用。省略 URL 时交互输入。
默认直接校验下载内容，失败时尝试转换并重新校验。

Options:
  -n, --name <名称>   指定名称（默认取订阅文件名或链接域名）
  -u, --use           保存后立即启用
  --raw               不转换，直接校验下载内容
  --convert           强制转换后校验
  -t, --timeout <秒>  下载超时（默认 ${CLASHCTL_SUB_TIMEOUT:-20} 秒）
  --ua <UA>           请求 User-Agent（默认 ${CLASHCTL_SUB_UA:-clash-verge/v2.4.0}）

--raw 和 --convert 仅对本次添加生效，更新时需重新指定。
示例：clashctl sub add --use "<URL>"

EOF
        return 0
    fi
    [ ${#args[@]} -gt 1 ] && {
        _errorcat "仅支持一个订阅链接"
        return 1
    }
    url=${args[0]:-}
    [ -z "$url" ] && {
        _read_subscription_url url '请输入要添加的订阅链接：' || return 1
        [ -z "$url" ] && {
            _errorcat "订阅链接不能为空"
            return 1
        }
    }

    if [ -n "$name" ]; then
        _sub_validate_name "$name" || return 1
        _sub_has "$name" && {
            _errorcat "订阅名称已存在：$name"
            return 1
        }
    fi

    _sub_url_exists "$url" && {
        _errorcat "该订阅链接已存在：$url"
        return 1
    }

    _sub_download "$url" "$strategy" || return 1

    local dl_file=$_SUB_DL_FILE rc=0
    _with_profiles_lock _sub_add_locked "$name" "$url" "$use_after_add" "$dl_file" "$FETCH_USERINFO" "$FETCH_FILENAME" || rc=$?
    [ "$rc" -eq 0 ] || /usr/bin/rm -f -- "$dl_file"
    return "$rc"
}

# 临界区：确定唯一名称/路径、落盘、写入元数据（可选立即启用）
_sub_add_locked() {
    local name=$1 url=$2 use_after_add=$3 dl_file=$4 userinfo=$5 filename=$6

    # 下载期间可能已有并发操作占用了同名/同链接，锁内再权威校验一次
    if [ -n "$name" ]; then
        _sub_has "$name" && {
            _errorcat "订阅名称已存在：$name"
            return 1
        }
    else
        # 默认名优先取 content-disposition 文件名（多为机场名），否则回退链接 host
        local base
        base=$(_sub_sanitize_name "$filename")
        [ -z "$base" ] && base=$(_sub_default_name "$url")
        name=$(_sub_unique_name "$base")
    fi
    _sub_url_exists "$url" && {
        _errorcat "该订阅链接已存在：$url"
        return 1
    }

    /bin/mkdir -p "$CLASH_PROFILES_DIR"
    local profile_path
    profile_path=$(_sub_filename "$name")
    /bin/mv "$dl_file" "$profile_path"

    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    PROFILE_NAME=$name PROFILE_PATH=$profile_path PROFILE_URL=$url PROFILE_UPDATED=$now PROFILE_USERINFO=$userinfo \
        "$BIN_YQ" -i '
            .profiles = (.profiles // []) +
            [{
              "name": strenv(PROFILE_NAME),
              "path": strenv(PROFILE_PATH),
              "url": strenv(PROFILE_URL),
              "updated": strenv(PROFILE_UPDATED),
              "userinfo": strenv(PROFILE_USERINFO)
            }]
        ' "$CLASH_PROFILES_META"

    _logging_sub "➕ 已添加订阅：[$name]"
    _okcat '🎉' "订阅已添加：[$name]"
    if [ "$use_after_add" = true ]; then
        _sub_use_locked "$name"
    fi
}

_sub_del() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub del [名称]

删除订阅；省略名称时交互选择。正在使用的订阅需先切换。

EOF
        return 0
        ;;
    esac

    local name=$1
    [ -z "$name" ] && {
        name=$(_sub_pick "请选择要删除的订阅：") || return 1
    }

    _with_profiles_lock _sub_del_locked "$name"
}

_sub_del_locked() {
    local name=$1
    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    [ "$(_sub_current)" = "$name" ] && {
        _errorcat "删除失败：订阅 [$name] 正在使用中，请先切换订阅"
        return 1
    }

    local path url
    path=$(_sub_get "$name" path)
    url=$(_sub_get "$name" url)

    /usr/bin/rm -f "$path"
    PROFILE_NAME=$name "$BIN_YQ" -i 'del(.profiles[] | select(.name == strenv(PROFILE_NAME)))' "$CLASH_PROFILES_META"
    _logging_sub "➖ 已删除订阅：[$name] $url"
    _okcat '🎉' "订阅已删除：[$name] $url"
}

# 字节数转人类可读（B/KB/MB/GB/...）
_fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if (b <= 0) { print "0B"; exit }
        split("B KB MB GB TB PB", u, " ");
        i = 1; while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d%s", b, u[i]; else printf "%.2f%s", b, u[i];
    }'
}

# 由 subscription-userinfo 原始串生成展示用「流量」「到期」两字段（无信息为 —），以 TAB 分隔
_userinfo_display() {
    local raw=$1 kv k v upload=0 download=0 used total=0 expire=0 traffic exp
    [ -z "$raw" ] && {
        printf '%s\t%s' '—' '—'
        return
    }
    for kv in ${raw//;/ }; do
        k=${kv%%=*}
        v=${kv#*=}
        [[ $v =~ ^[0-9]+$ ]] || continue
        case $k in
        upload) upload=$v ;;
        download) download=$v ;;
        total) total=$v ;;
        expire) expire=$v ;;
        esac
    done
    used=$((upload + download))
    if [ "${total:-0}" -gt 0 ] 2>/dev/null; then
        traffic="$(_fmt_bytes "$used")/$(_fmt_bytes "$total")"
    elif [ "${used:-0}" -gt 0 ] 2>/dev/null; then
        traffic=$(_fmt_bytes "$used")
    else
        traffic='—'
    fi
    if [ "${expire:-0}" -gt 0 ] 2>/dev/null; then
        exp=$(date -d "@$expire" +%Y-%m-%d 2>/dev/null || printf '—')
    else
        exp='—'
    fi
    printf '%s\t%s' "$traffic" "$exp"
}

_sub_list() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub ls

列出全部订阅，不进入交互选择。当前订阅以 * 标记。
显示名称、更新时间、流量、到期时间和链接。

EOF
        return 0
        ;;
    esac

    _sub_load

    [ ${#_SUB_NAMES[@]} -eq 0 ] && {
        _ui_emit_fd 1 info '暂无订阅，使用 clashctl sub add <url> 添加'
        return 0
    }

    local NAME_H='名称' UPD_H='更新时间' TRAF_H='流量' EXP_H='到期'
    local namew updw trafw expw i upds=()
    for i in "${!_SUB_UPDS[@]}"; do
        upds+=("${_SUB_UPDS[$i]:-—}")
    done
    namew=$(_max_width "$NAME_H" "${_SUB_NAMES[@]}")
    updw=$(_max_width "$UPD_H" "${upds[@]}")
    trafw=$(_max_width "$TRAF_H" "${_SUB_TRAFFICS[@]}")
    expw=$(_max_width "$EXP_H" "${_SUB_EXPIRES[@]}")

    printf '  %s %s  %s  %s  %s  %s\n' \
        ' ' \
        "$(_pad "$NAME_H" "$namew")" \
        "$(_pad "$UPD_H" "$updw")" \
        "$(_pad "$TRAF_H" "$trafw")" \
        "$(_pad "$EXP_H" "$expw")" \
        '链接'

    local marker
    for i in "${!_SUB_NAMES[@]}"; do
        marker=' '
        [ "${_SUB_NAMES[$i]}" = "$_SUB_CUR" ] && marker='*'
        printf '  %s %s  %s  %s  %s  %s\n' \
            "$marker" \
            "$(_pad "${_SUB_NAMES[$i]}" "$namew")" \
            "$(_pad "${upds[$i]}" "$updw")" \
            "$(_pad "${_SUB_TRAFFICS[$i]}" "$trafw")" \
            "$(_pad "${_SUB_EXPIRES[$i]}" "$expw")" \
            "${_SUB_URLS[$i]}"
    done
    return 0
}

_sub_use() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub use [名称]

切换并启用订阅；省略名称时交互选择。
启用前会校验订阅与 Mixin 合并后的配置。

EOF
        return 0
        ;;
    esac

    local name=$1
    [ -z "$name" ] && {
        name=$(_sub_pick "请选择要使用的订阅：") || return 1
    }

    _with_profiles_lock _sub_use_locked "$name"
}

_sub_use_locked() {
    local name=$1 rc base_existed=true
    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    local path url
    path=$(_sub_get "$name" path)
    url=$(_sub_get "$name" url)

    [ -f "$path" ] && [ -s "$path" ] || {
        _errorcat "订阅配置文件缺失或为空：$path"
        return 1
    }
    _valid_sub_nodes "$path" || return 1

    # 切换前备份 BASE：合并校验失败（rc=1）时连同运行配置一起回滚，避免 BASE 与 runtime 不一致
    if [ -e "$CLASH_CONFIG_BASE" ] || [ -L "$CLASH_CONFIG_BASE" ]; then
        cat "$CLASH_CONFIG_BASE" >"${CLASH_CONFIG_BASE}.bak" || {
            _errorcat "无法备份当前配置（磁盘已满？），已取消切换"
            return 1
        }
    else
        base_existed=false
    fi
    rc=0
    if cat "$path" >"$CLASH_CONFIG_BASE"; then
        _merge_config_restart || rc=$?
    else
        _errorcat '无法写入订阅配置，已取消切换'
        rc=1
    fi
    if [ "$rc" -eq 1 ]; then
        if [ "$base_existed" = true ]; then
            cat "${CLASH_CONFIG_BASE}.bak" >"$CLASH_CONFIG_BASE" || {
                _errorcat "回滚失败，原配置备份在 ${CLASH_CONFIG_BASE}.bak，请手动恢复"
                return 1
            }
        else
            command rm -f -- "$CLASH_CONFIG_BASE" || return 1
        fi
        /usr/bin/rm -f "${CLASH_CONFIG_BASE}.bak"
        _errorcat "订阅 [$name] 校验未通过（含 Mixin 合并结果），已回滚"
        return 1
    fi
    /usr/bin/rm -f "${CLASH_CONFIG_BASE}.bak"

    PROFILE_NAME=$name "$BIN_YQ" -i '.use = strenv(PROFILE_NAME)' "$CLASH_PROFILES_META"
    _logging_sub "🔥 订阅已切换为：[$name] $url"
    # rc=2：配置本身已切换成功（BASE/runtime 均为新配置），仅服务重启失败
    if [ "$rc" -eq 2 ]; then
        _failcat '🍂' "配置已切换，但服务重启失败，请检查代理内核日志"
        return 1
    fi
    _okcat '🔥' '订阅已生效'
}

_sub_update() {
    local strategy=auto name='' all=false args help=false
    _sub_parse_opts update "$@" || return 1
    if [ "$help" = true ]; then
        cat <<EOF

Usage:
  clashctl sub update [名称] [选项]

重新下载并校验订阅；更新当前订阅后会重新应用配置。
省略名称时更新当前订阅；没有当前订阅时，仅交互终端可选择。
默认直接校验下载内容，失败时尝试转换并重新校验。

Options:
  --all               更新全部订阅
  --raw               不转换，直接校验下载内容
  --convert           强制转换后校验
  -t, --timeout <秒>  下载超时（默认 ${CLASHCTL_SUB_TIMEOUT:-20} 秒）
  --ua <UA>           请求 User-Agent（默认 ${CLASHCTL_SUB_UA:-clash-verge/v2.4.0}）

--raw 和 --convert 仅对本次更新生效。
示例：clashctl sub update --all

EOF
        return 0
    fi
    name=${args[0]:-}

    [ "$all" = true ] && {
        [ -n "$name" ] && {
            _errorcat "--all 不能与订阅名同时指定"
            return 1
        }
        local names=() n rc=0
        while IFS= read -r n; do
            [ -n "$n" ] && names+=("$n")
        done < <(_sub_names)
        [ ${#names[@]} -eq 0 ] && {
            _errorcat "当前无可用订阅，请先添加订阅"
            return 1
        }
        for n in "${names[@]}"; do
            _sub_update_one "$n" "$strategy" || rc=1
        done
        return "$rc"
    }

    [ -z "$name" ] && name=$(_sub_current)
    [ -z "$name" ] && {
        # 无当前订阅：交互终端回退选择，非交互环境保持可脚本的明确报错
        if [ -t 0 ] && [ -t 1 ]; then
            name=$(_sub_pick "请选择要更新的订阅：") || return 1
        else
            _errorcat "当前无使用中的订阅，请指定订阅名称或使用 --all"
            return 1
        fi
    }
    _sub_update_one "$name" "$strategy"
}

# 更新单个订阅：下载/校验在锁外，提交在锁内（供单个与 --all 复用）
_sub_update_one() {
    local name=$1 strategy=$2
    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    local url path
    url=$(_sub_get "$name" url)
    path=$(_sub_get "$name" path)
    _ui_emit_fd 1 step "更新订阅：[$name] $url"

    _sub_download "$url" "$strategy" || {
        _logging_sub "❌ 订阅更新失败：[$name] $url${_SUB_DL_REASON:+ — ${_SUB_DL_REASON}}"
        return 1
    }

    local dl_file=$_SUB_DL_FILE rc=0
    _with_profiles_lock _sub_update_locked "$name" "$url" "$path" "$dl_file" "$FETCH_USERINFO" || rc=$?
    [ "$rc" -eq 0 ] || /usr/bin/rm -f -- "$dl_file"
    return "$rc"
}

_sub_update_locked() {
    local name=$1 url=$2 path=$3 dl_file=$4 userinfo=$5

    # 下载期间该订阅可能已被并发删除，锁内复检
    _sub_has "$name" || {
        _errorcat "订阅不存在（可能已被删除）：$name"
        return 1
    }

    _logging_sub "✅ 订阅更新成功：[$name] $url"
    /bin/mv -f "$dl_file" "$path"

    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    PROFILE_NAME=$name PROFILE_UPDATED=$now "$BIN_YQ" -i \
        '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .updated) = strenv(PROFILE_UPDATED)' \
        "$CLASH_PROFILES_META"
    # 仅在本次抓到流量信息时更新，避免转换路径的空值覆盖既有数据
    [ -n "$userinfo" ] && PROFILE_NAME=$name PROFILE_USERINFO=$userinfo "$BIN_YQ" -i \
        '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .userinfo) = strenv(PROFILE_USERINFO)' \
        "$CLASH_PROFILES_META"

    [ "$(_sub_current)" = "$name" ] && {
        _sub_use_locked "$name"
        return
    }
    _okcat '订阅已更新'
}

_sub_rename() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub rename [旧名称] [新名称]

重命名订阅；省略旧名称时交互选择，省略新名称时提示输入。

EOF
        return 0
        ;;
    esac

    local old=$1 new=$2

    [ -z "$old" ] && {
        old=$(_sub_pick "请选择要重命名的订阅：") || return 1
    }
    _sub_has "$old" || {
        _errorcat "订阅不存在：$old"
        return 1
    }

    [ -z "$new" ] && {
        printf '%s' "请输入 [$old] 的新名称："
        read -r new
    }
    _sub_validate_name "$new" || return 1
    [ "$new" = "$old" ] && {
        _ui_emit_fd 1 info "名称未变化：$old"
        return 0
    }
    _sub_has "$new" && {
        _errorcat "订阅名称已存在：$new"
        return 1
    }

    _with_profiles_lock _sub_rename_locked "$old" "$new"
}

_sub_rename_locked() {
    local old=$1 new=$2
    _sub_has "$old" || {
        _errorcat "订阅不存在：$old"
        return 1
    }
    _sub_has "$new" && {
        _errorcat "订阅名称已存在：$new"
        return 1
    }

    OLD_NAME=$old NEW_NAME=$new "$BIN_YQ" -i \
        '(.profiles[] | select(.name == strenv(OLD_NAME)) | .name) = strenv(NEW_NAME)' \
        "$CLASH_PROFILES_META"
    [ "$(_sub_current)" = "$old" ] && {
        NEW_NAME=$new "$BIN_YQ" -i '.use = strenv(NEW_NAME)' "$CLASH_PROFILES_META"
    }

    _logging_sub "✏️ 订阅重命名：[$old] → [$new]"
    _okcat '✏️' "订阅已重命名：[$old] → [$new]"
}

_sub_log() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub log [-n 行数] [-f]

查看订阅操作日志；默认显示末尾 10 行。选项传给 tail。

Options:
  -n <行数>  显示末尾指定行数
  -f         持续显示新日志

EOF
        return 0
        ;;
    esac

    tail "$@" "$CLASH_PROFILES_LOG"
}

sub_help() {
    cat <<EOF

clashctl sub - 订阅管理

Usage:
  clashctl sub [命令] [选项]

省略命令时：交互终端选择并启用订阅；非交互环境列出订阅。

Commands:
  add [URL]             添加并校验订阅（--use 添加后立即启用）
  ls                    列出订阅（别名 list）
  use [名称]            切换并启用订阅
  del [名称]            删除订阅（别名 delete）
  update [名称]         更新订阅（--all 更新全部）
  rename [旧名称] [新名称]  重命名订阅
  log                   查看订阅操作日志

查看子命令选项，例如：clashctl sub add -h

EOF
}
