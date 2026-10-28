#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

# ── 术语约定（内部命名）───────────────────────────────────────
#   group   策略组：含 .all 成员列表的项（Selector/URLTest…）；用户可见称“策略组”
#   proxy   节点：无 .all 的叶子代理，可单独测速；用户可见称“节点”
#   member  组内节点：某策略组 .all 里的成员（本质仍是一个 proxy）
#   _node_  仅是本文件的模块前缀，不单独表示上述任何概念
# ─────────────────────────────────────────────────────────────

clashnode() {
    case "${1:-}" in
    -h | --help | help)
        node_help
        return 0
        ;;
    esac

    # node 使用 Bash 数组和关联数组；交给 Bash 子进程执行。
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashnode "$@"
        return
    fi

    service_is_active >&/dev/null || {
        _failcat "$CLASHCTL_KERNEL 未运行，请先执行 clashctl on"
        return 1
    }

    local cmd=${1:-}
    case $cmd in
    -* | '') cmd=use ;; # 省略子命令或直接带选项 → 交互式切换；选项由 _node_use 自行解析
    *) shift ;;
    esac
    case $cmd in
    ls | list) _node_list "$@" ;;
    delay) _node_delay "$@" ;;
    use) _node_use "$@" ;;
    *)
        _errorcat "未知 node 子命令：$cmd"
        node_help
        return 1
        ;;
    esac
}

########################################
#            API 调用
########################################

_node_api_base() {
    _detect_ext_addr # 填充 EXT_PORT（服务运行时不会触发改端口分支）
    printf 'http://127.0.0.1:%s' "$EXT_PORT"
}

# 统一 curl 封装：--noproxy '*' 避免走系统代理；secret 非空时带 Bearer
# 用法：_node_curl <METHOD> <PATH> [额外 curl 参数...]
_node_curl() {
    local method=$1 path=$2
    shift 2
    local secret base auth=()
    base=$(_node_api_base)
    secret=$(_get_secret)
    [ -n "$secret" ] && auth=(-H "Authorization: Bearer $secret")
    curl -s --noproxy '*' --max-time "${CLASHCTL_API_TIMEOUT:-10}" \
        -X "$method" "${auth[@]}" "${base}${path}" "$@"
}

_node_require_arg() {
    local opt=$1 value=${2-}
    [ -n "$value" ] || {
        _errorcat "选项 $opt 需要参数"
        return 1
    }
}

_node_default_delay_url() {
    printf '%s' "${CLASHCTL_NODE_DELAY_URL:-http://www.gstatic.com/generate_204}"
}

_node_default_delay_timeout() {
    printf '%s' "${CLASHCTL_NODE_DELAY_TIMEOUT:-5000}"
}

_node_validate_delay_url() {
    [ -n "$1" ] || {
        _errorcat "测速 URL 不能为空"
        return 1
    }
    [[ $1 =~ ^https?:// ]] || {
        _errorcat "测速 URL 需以 http:// 或 https:// 开头：$1"
        return 1
    }
}

_node_validate_delay_timeout() {
    [[ $1 =~ ^[1-9][0-9]*$ ]] || {
        _errorcat "测速超时时间必须为正整数毫秒：$1"
        return 1
    }
}

# use 与 delay 共用的选项；结果写入调用方的 url、timeout、args、help、with_delay 或 mode。
_node_parse_opts() {
    local cmd=$1
    shift
    url=$(_node_default_delay_url)
    timeout=$(_node_default_delay_timeout)
    args=()

    while [ $# -gt 0 ]; do
        case "$cmd:$1" in
        use:-g | use:--group | use:-p | use:--proxy | delay:-d | delay:--delay)
            _errorcat "未知选项：$1"
            return 1
            ;;
        esac
        case "$1" in
        -h | --help)
            help=true
            return 0
            ;;
        -d | --delay)
            with_delay=true
            ;;
        -g | --group)
            [ "$mode" = proxy ] && {
                _errorcat "-g/--group 与 -p/--proxy 不能同时使用"
                return 1
            }
            mode=group
            ;;
        -p | --proxy)
            [ "$mode" = group ] && {
                _errorcat "-g/--group 与 -p/--proxy 不能同时使用"
                return 1
            }
            mode=proxy
            ;;
        -u | --url)
            _node_require_arg "$1" "${2-}" || return 1
            url=$2
            shift
            ;;
        --url=*)
            url="${1#*=}"
            ;;
        -t | --timeout)
            _node_require_arg "$1" "${2-}" || return 1
            timeout=$2
            shift
            ;;
        --timeout=*)
            timeout="${1#*=}"
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
#            数据读取
########################################

# 策略组：name <TAB> type <TAB> now
_node_groups() {
    _node_curl GET /proxies | "$BIN_YQ" -p json '
        .proxies | to_entries | .[]
        | select(.value.all != null)
        | [.key, .value.type, (.value.now // "")] | @tsv' 2>/dev/null
}

_node_proxies() {
    _node_curl GET /proxies | "$BIN_YQ" -p json '
        .proxies | to_entries | .[]
        | select(.value.all == null)
        | [.key, .value.type] | @tsv' 2>/dev/null
}

# 单次拉取 /proxies，判定名称属于哪一类，结果打到 stdout：
#   group  含 .all 成员列表的策略组
#   proxy  无 .all 的叶子节点
#   none   不存在
_node_classify() {
    local exists is_group
    IFS=$'\t' read -r exists is_group < <(
        _node_curl GET /proxies | NODE_NAME=$1 "$BIN_YQ" -p json '
            [(.proxies[strenv(NODE_NAME)] != null),
             (.proxies[strenv(NODE_NAME)].all != null)] | @tsv' 2>/dev/null
    )
    if [ "$exists" != true ]; then
        printf 'none'
    elif [ "$is_group" = true ]; then
        printf 'group'
    else
        printf 'proxy'
    fi
}

# 一次读取组详情，写入调用方的 now、members；区分不存在的名称和空组。
_node_group() {
    local json name
    now='' members=()
    json=$(_node_curl GET "/proxies/$(_urlencode "$1")")
    while IFS= read -r name; do
        [ -n "$name" ] && members+=("$name")
    done < <("$BIN_YQ" -p json '.all // [] | .[]' <<<"$json" 2>/dev/null)
    now=$("$BIN_YQ" -p json '.now // ""' <<<"$json" 2>/dev/null)
    # 没有成员时再区分空组和非策略组
    [ ${#members[@]} -gt 0 ] || "$BIN_YQ" -p json -e '.all' <<<"$json" >/dev/null 2>&1
}

# 某组的成员节点列表（每行一个）
_node_members() {
    _node_curl GET "/proxies/$(_urlencode "$1")" | "$BIN_YQ" -p json '.all // [] | .[]' 2>/dev/null
}

# 读取到调用方 names、types、nows，并计算显示列宽；selector 仅保留可手动切换的组。
_node_load_groups() {
    local filter=${1:-all} name type now i shown=()
    names=() types=() nows=()
    while IFS=$'\t' read -r name type now; do
        [ "$filter" = selector ] && [ "$type" != Selector ] && continue
        names+=("$name")
        types+=("$type")
        nows+=("$now")
    done < <(_node_groups)
    for i in "${!nows[@]}"; do
        shown+=("${nows[$i]:-—}")
    done
    namew=$(_max_width "${names[@]}")
    noww=$(_max_width "${shown[@]}")
}

# 列表与交互菜单共用的策略组显示行。
_node_group_line() {
    printf '%s → %s  [%s]' \
        "$(_pad "${names[$1]}" "$namew")" \
        "$(_pad "${nows[$1]:-—}" "$noww")" \
        "${types[$1]}"
}

########################################
#            切换
########################################

# PUT /proxies/:group；204 成功、400 不可切换、404 组不存在。
_node_apply() {
    local group=$1 member=$2 enc body code rc
    enc=$(_urlencode "$group")
    body=$(NODE=$member "$BIN_YQ" -n -o=json '{"name": strenv(NODE)}') # 安全构造 JSON，免手动转义
    code=$(_node_curl PUT "/proxies/$enc" \
        -H 'Content-Type: application/json' --data-binary "$body" \
        -o /dev/null -w '%{http_code}') || {
        rc=$?
        _failcat "切换失败：控制器请求失败（curl 退出码：$rc）"
        return 1
    }
    case $code in
    204) _okcat "已切换 [$group] → $member" ;;
    400) _failcat "切换失败：节点 [$member] 不在策略组 [$group] 内，或该组不可手动切换" ;;
    404) _failcat "切换失败：策略组 [$group] 不存在" ;;
    *) _failcat "切换失败：控制器返回 $code（检查内核是否运行 / secret 是否正确）" ;;
    esac
}

_node_use() {
    local with_delay=false url timeout args help=false
    _node_parse_opts use "$@" || return 1
    if [ "$help" = true ]; then
        cat <<EOF

Usage:
  clashctl node use [OPTIONS] [组] [节点]

切换策略组所选节点（名称需与 clashctl node ls / 组内节点一致）：
  - 不带参数：交互选择策略组与节点，默认不测速
  - 仅指定组：在该组内交互选择节点，默认不测速
  - 同时指定组与节点：直接切换

Options:
  -d, --delay              交互选择节点时显示实时延迟
  -u, --url <URL>          测速目标 URL（仅配合 -d 使用，默认: $(_node_default_delay_url)）
  -t, --timeout <毫秒>     单节点测速超时（仅配合 -d 使用，默认: $(_node_default_delay_timeout)）
  -h, --help               显示帮助信息

Examples:
  clashctl node use
  clashctl node use -d proxy
  clashctl node use proxy "香港 01"

EOF
        return 0
    fi

    set -- "${args[@]}"
    if [ "$with_delay" = true ]; then
        _node_validate_delay_url "$url" || return 1
        _node_validate_delay_timeout "$timeout" || return 1
    fi

    local group member
    case $# in
    0)
        group=$(_node_pick_group "请选择要切换的策略组：" selector) || return 1
        member=$(_node_pick_member "$group" "$with_delay" "$url" "$timeout") || return 1
        ;;
    1)
        group=$1
        member=$(_node_pick_member "$group" "$with_delay" "$url" "$timeout") || return 1
        ;;
    2)
        group=$1
        member=$2
        ;;
    *)
        _errorcat "用法：clashctl node use [-d] [-u URL] [-t 毫秒] [组] [节点]"
        return 1
        ;;
    esac
    _node_apply "$group" "$member"
}

########################################
#            列表
########################################

_node_list() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl node ls [组]

不带参数：列出所有策略组、类型与当前选中节点。
指定组名：列出该组的成员节点（* 为当前选中）。

EOF
        return 0
        ;;
    esac
    [ $# -gt 1 ] && {
        _errorcat "用法：clashctl node ls [组]"
        return 1
    }
    [ $# -eq 1 ] && {
        _node_list_members "$1"
        return
    }

    local names=() types=() nows=() namew noww i
    _node_load_groups
    [ ${#names[@]} -eq 0 ] && {
        _failcat "未获取到策略组（内核是否运行？）"
        return 1
    }
    for i in "${!names[@]}"; do
        printf '  %s\n' "$(_node_group_line "$i")"
    done
    return 0
}

# 列出某策略组的成员节点（* 标当前选中）；成员类型仅叶子节点可知，否则显示 —
_node_list_members() {
    local group=$1 now members=() name type
    _node_group "$group" || {
        _failcat "策略组 [$group] 不存在"
        return 1
    }
    [ ${#members[@]} -eq 0 ] && {
        _failcat "策略组 [$group] 无可用节点"
        return 1
    }

    declare -A member_types=()
    while IFS=$'\t' read -r name type; do
        [ -n "$name" ] && member_types["$name"]=$type
    done < <(_node_proxies)

    local i namew marker
    namew=$(_max_width "${members[@]}")
    for i in "${!members[@]}"; do
        marker=' '
        [ "${members[$i]}" = "$now" ] && marker='*'
        printf '  %s %s  [%s]\n' \
            "$marker" \
            "$(_pad "${members[$i]}" "$namew")" \
            "${member_types[${members[$i]}]:-—}"
    done
    return 0
}

########################################
#            交互式选择
########################################

# 交互选组，选中的组名输出到 stdout，菜单打到 stderr
# $1: 提示语  $2: 过滤（selector=仅可切换组 / all=全部，默认 all）
_node_pick_group() {
    local prompt=$1 filter=${2:-all}
    local names=() types=() nows=() namew noww i
    _node_load_groups "$filter"

    [ ${#names[@]} -eq 0 ] && {
        if [ "$filter" = selector ]; then
            _errorcat "无可手动切换的策略组（Selector）"
        else
            _errorcat "未获取到策略组（内核是否运行？）"
        fi
        return 1
    }
    # 仅一个组时自动选中
    [ ${#names[@]} -eq 1 ] && {
        printf '%s\n' "${names[0]}"
        return 0
    }

    if _has_fzf; then
        local preview_dir member count
        preview_dir=$(_pick_preview_dir)
        if [ -n "$preview_dir" ]; then
            for i in "${!names[@]}"; do
                {
                    printf '策略组\n'
                    printf '  名称：%s\n' "${names[$i]}"
                    printf '  类型：%s\n' "${types[$i]}"
                    printf '  当前：%s\n' "${nows[$i]:-—}"
                    printf '\n节点\n'
                    count=0
                    while IFS= read -r member; do
                        [ -z "$member" ] && continue
                        ((count += 1))
                        if [ "$member" = "${nows[$i]}" ]; then
                            printf '  * %s\n' "$member"
                        else
                            printf '    %s\n' "$member"
                        fi
                        [ "$count" -ge 60 ] && {
                            printf '    ...\n'
                            break
                        }
                    done < <(_node_members "${names[$i]}")
                    [ "$count" -gt 0 ] || printf '  —\n'
                } >"$preview_dir/$((i + 1))"
            done
        fi
        for i in "${!names[@]}"; do
            printf '%s\t%s\t%s\n' "$((i + 1))" "${names[$i]}" "$(_node_group_line "$i")"
        done | _pick_fzf "$prompt" '选择策略组，Enter 确认，Esc 退出' "$preview_dir"
        return
    fi

    _hint_fzf

    # 与 ls 一致：[序号] 名字 → 当前节点 [type]，按显示宽度对齐
    local idxw=${#names[@]}
    idxw=${#idxw} # 序号位数；[n] 整体左对齐补齐到 idxw+2
    for i in "${!names[@]}"; do
        printf '  %-*s %s\n' $((idxw + 2)) "[$((i + 1))]" "$(_node_group_line "$i")" >&2
    done
    _pick_read "$prompt" "${names[@]}"
}

_node_pick_proxy() {
    local prompt=$1
    local names=() types=() name type i
    while IFS=$'\t' read -r name type; do
        [ -n "$name" ] && {
            names+=("$name")
            types+=("$type")
        }
    done < <(_node_proxies)

    [ ${#names[@]} -eq 0 ] && {
        _errorcat "未获取到可测速的节点"
        return 1
    }

    if _has_fzf; then
        local preview_dir namew
        namew=$(_max_width "${names[@]}")
        preview_dir=$(_pick_preview_dir)
        if [ -n "$preview_dir" ]; then
            for i in "${!names[@]}"; do
                {
                    printf '节点\n'
                    printf '  名称：%s\n' "${names[$i]}"
                    printf '  类型：%s\n' "${types[$i]}"
                } >"$preview_dir/$((i + 1))"
            done
        fi
        for i in "${!names[@]}"; do
            printf '%s\t%s\t%s  [%s]\n' \
                "$((i + 1))" \
                "${names[$i]}" \
                "$(_pad "${names[$i]}" "$namew")" \
                "${types[$i]}"
        done | _pick_fzf "$prompt" '选择节点，Enter 确认，Esc 退出' "$preview_dir"
        return
    fi

    _hint_fzf

    local idxw=${#names[@]}
    idxw=${#idxw}
    for i in "${!names[@]}"; do
        printf '  %-*s %s  [%s]\n' $((idxw + 2)) "[$((i + 1))]" "${names[$i]}" "${types[$i]}" >&2
    done
    _pick_read "$prompt" "${names[@]}"
}

# 交互选组内节点，选中的节点名输出到 stdout，菜单打到 stderr（* 标记当前）
_node_pick_member() {
    local group=$1 with_delay=${2:-false} url=${3:-} timeout=${4:-}
    local now members=() labels=() name type delay i marker namew=0 delayw=0
    _node_group "$group" || :

    [ ${#members[@]} -eq 0 ] && {
        _errorcat "策略组 [$group] 无可用节点"
        return 1
    }

    if [ "$with_delay" = true ]; then
        _ui_step "正在测速 [$group]（可能需要数秒）..."
        [ -n "$url" ] || url=$(_node_default_delay_url)
        [ -n "$timeout" ] || timeout=$(_node_default_delay_timeout)
        declare -A delays=()
        while IFS=$'\t' read -r name delay; do
            [ -n "$name" ] && delays["$name"]=$delay
        done < <(_node_delay_rows "$group" "$(_node_delay_query "$url" "$timeout")" "${members[@]}")
        for i in "${!members[@]}"; do
            labels+=("$(_node_delay_label "${delays[${members[$i]}]:-}")")
        done
        namew=$(_max_width "${members[@]}")
        delayw=$(_max_width "${labels[@]}")
    fi

    if _has_fzf; then
        declare -A proxy_types=()
        while IFS=$'\t' read -r name type; do
            [ -n "$name" ] && proxy_types["$name"]=$type
        done < <(_node_proxies)

        local preview_dir
        preview_dir=$(_pick_preview_dir)
        if [ -n "$preview_dir" ]; then
            for i in "${!members[@]}"; do
                {
                    printf '节点\n'
                    printf '  名称：%s\n' "${members[$i]}"
                    printf '  策略组：%s\n' "$group"
                    printf '  类型：%s\n' "${proxy_types[${members[$i]}]:-—}"
                    if [ "${members[$i]}" = "$now" ]; then
                        printf '  状态：当前选中\n'
                    else
                        printf '  状态：可切换\n'
                    fi
                    if [ "$with_delay" = true ]; then
                        printf '  延迟：%s\n' "${labels[$i]}"
                    fi
                } >"$preview_dir/$((i + 1))"
            done
        fi

        for i in "${!members[@]}"; do
            marker=' '
            [ "${members[$i]}" = "$now" ] && marker='*'
            printf '%s\t%s\t%s %s\n' "$((i + 1))" "${members[$i]}" "$marker" "$(_node_member_cell "$i")"
        done | _pick_fzf "${group} > " '* 表示当前节点；Enter 切换，Esc 退出' "$preview_dir" --ansi
        return
    fi

    _hint_fzf

    local idxw=${#members[@]}
    idxw=${#idxw} # 序号位数；[n] 整体左对齐补齐到 idxw+2，使括号紧凑且名字列对齐
    for i in "${!members[@]}"; do
        marker=' '
        [ "${members[$i]}" = "$now" ] && marker='*'
        printf '%s %-*s %s\n' "$marker" $((idxw + 2)) "[$((i + 1))]" "$(_node_member_cell "$i")" >&2
    done
    _pick_read '请选择要切换到的节点（* 为当前）：' "${members[@]}"
}

# 组内节点显示列；测速时补齐名称，附上右对齐、着色的延迟。
_node_member_cell() {
    local i=$1
    if [ "$with_delay" = true ]; then
        printf '%s  %*s%s' \
            "$(_pad "${members[$i]}" "$namew")" \
            $((delayw - $(_dispwidth "${labels[$i]}"))) '' \
            "$(_node_delay_color "${labels[$i]}")"
    else
        printf '%s' "${members[$i]}"
    fi
}

########################################
#            延迟测速
########################################

# 超时、低于 200ms、低于 500ms 及其余延迟的颜色。
_node_delay_rgb() {
    local delay=$1
    if ! [[ "$delay" =~ ^[0-9]+$ ]] || [ "$delay" -le 0 ]; then
        printf '249;47;96'
    elif [ "$delay" -lt 200 ]; then
        printf '38;222;129'
    elif [ "$delay" -lt 500 ]; then
        printf '254;211;48'
    else
        printf '253;121;168'
    fi
}

# 读取 "name<TAB>delay" 行，按延迟排序输出（超时排末尾）。
_node_print_delays() {
    local name delay
    while IFS=$'\t' read -r name delay; do
        if [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ]; then
            printf '%010d\t%s\t%s\n' "$delay" "$name" "$delay"
        else
            printf '%010d\t%s\t%s\n' 9999999999 "$name" "timeout"
        fi
    done | sort -n | {
        local disp text
        while IFS=$'\t' read -r _ name disp; do
            if [ "$disp" = timeout ]; then
                text=$(printf '  ✗ %-26s 超时' "$name")
            else
                text=$(printf '  ● %-26s %sms' "$name" "$disp")
            fi
            # fd1 会随调用方重定向，因此按实际输出目标判定颜色。
            if _ui_color_enabled 1; then
                printf '\033[38;2;%sm%s\033[0m\n' "$(_node_delay_rgb "$disp")" "$text"
            else
                printf '%s\n' "$text"
            fi
        done
    }
}

_node_delay_label() {
    local delay=$1
    if [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ]; then
        printf '%sms' "$delay"
    else
        printf 'timeout'
    fi
}

_node_delay_color() {
    printf '\033[38;2;%sm%s\033[0m' "$(_node_delay_rgb "${1%ms}")" "$1"
}

_node_delay_query() {
    printf 'timeout=%s&url=%s' "$2" "$(_urlencode "$1")"
}

_node_delay_one() {
    local name=$1 qs=$2 resp delay
    resp=$(_node_curl GET "/proxies/$(_urlencode "$name")/delay?$qs")
    delay=$("$BIN_YQ" -p json '.delay // ""' <<<"$resp" 2>/dev/null)
    printf '%s\t%s\n' "$name" "$delay"
}

# 旧内核不支持组测速时，复用逐节点接口并限制并发数。
_node_delay_member_rows() {
    local qs=$1 name concurrency active=0
    shift
    concurrency=${CLASHCTL_NODE_DELAY_CONCURRENCY:-8}
    [[ "$concurrency" =~ ^[0-9]+$ ]] || concurrency=8
    ((concurrency < 1)) && concurrency=1
    for name; do
        _node_delay_one "$name" "$qs" &
        ((active += 1))
        if ((active >= concurrency)); then
            wait
            active=0
        fi
    done
    wait
}

# 404/405 表示旧内核不支持组测速；504 表示组内节点均超时，不重复测速。
_node_delay_rows() {
    local group=$1 qs=$2 resp code name delay
    shift 2
    declare -A delays=()
    resp=$(_node_curl GET "/group/$(_urlencode "$group")/delay?$qs" -w $'\n%{http_code}') || {
        _errorcat '组测速失败：无法连接控制器或请求超时'
        return 1
    }
    code=${resp##*$'\n'}
    case $code in
    200)
        while IFS=$'\t' read -r name delay; do
            [ -n "$name" ] && delays["$name"]=$delay
        done < <("$BIN_YQ" -p json 'to_entries | .[] | [.key, .value] | @tsv' <<<"${resp%$'\n'*}" 2>/dev/null)
        ;;
    404 | 405)
        _node_delay_member_rows "$qs" "$@"
        return
        ;;
    504) ;;
    *)
        _errorcat "组测速失败：控制器返回 $code"
        return 1
        ;;
    esac
    for name; do
        printf '%s\t%s\n' "$name" "${delays[$name]:-}"
    done
}

_node_delay_group() {
    local group=$1 url=$2 timeout=$3 members=() name rows
    _ui_emit_fd 1 step "正在测速策略组 [$group]（可能需要数秒）..."
    while IFS= read -r name; do
        [ -n "$name" ] && members+=("$name")
    done < <(_node_members "$group")
    [ ${#members[@]} -eq 0 ] && {
        _failcat "策略组 [$group] 无节点或不存在"
        return 1
    }
    rows=$(_node_delay_rows "$group" "$(_node_delay_query "$url" "$timeout")" "${members[@]}") || return 1
    _node_print_delays <<<"$rows"
}

_node_delay_proxy() {
    local proxy=$1 url=$2 timeout=$3
    _ui_emit_fd 1 step "正在测速节点 [$proxy]..."
    _node_delay_one "$proxy" "$(_node_delay_query "$url" "$timeout")" | _node_print_delays
}

_node_delay() {
    local url timeout args mode=auto help=false
    _node_parse_opts delay "$@" || return 1
    if [ "$help" = true ]; then
        cat <<EOF

Usage:
  clashctl node delay [OPTIONS] [名称]

对策略组或单个节点做延迟测速（单位 ms）：
  - 不指定名称：交互选择策略组并测速
  - 裸名称：优先按策略组测速，找不到策略组时按节点测速
  - -g, --group：强制按策略组测速
  - -p, --proxy：强制按节点测速

Options:
  -g, --group               强制把名称当策略组测速
  -p, --proxy               强制把名称当单个节点测速
  -u, --url <URL>           测速目标 URL（默认: $(_node_default_delay_url)）
  -t, --timeout <毫秒>      单节点测速超时（默认: $(_node_default_delay_timeout)）
  -h, --help                显示帮助信息

Examples:
  clashctl node delay
  clashctl node delay -p "香港 01"
  clashctl node delay -t 8000 -g PROXY

可选环境变量（.env）：
  CLASHCTL_NODE_DELAY_URL      测速目标 URL（默认 http://www.gstatic.com/generate_204）
  CLASHCTL_NODE_DELAY_TIMEOUT  单节点超时毫秒（默认 5000）
  CLASHCTL_NODE_DELAY_CONCURRENCY  旧内核 fallback 并发数（默认 8）

EOF
        return 0
    fi

    _node_validate_delay_url "$url" || return 1
    _node_validate_delay_timeout "$timeout" || return 1

    set -- "${args[@]}"
    local target=${1:-}
    [ $# -gt 1 ] && {
        _errorcat "用法：clashctl node delay [-g|-p] [-u URL] [-t 毫秒] [名称]"
        return 1
    }

    # 不指定名称时，除 -p 外都交互选择策略组
    if [ -z "$target" ] && [ "$mode" != proxy ]; then
        target=$(_node_pick_group "请选择要测速的策略组：" all) || return 1
        mode=group
    fi
    case $mode in
    group)
        _node_delay_group "$target" "$url" "$timeout"
        ;;
    proxy)
        if [ -z "$target" ]; then
            target=$(_node_pick_proxy "请选择要测速的节点：") || return 1
        elif [ "$(_node_classify "$target")" != proxy ]; then
            _failcat "节点 [$target] 不存在"
            return 1
        fi
        _node_delay_proxy "$target" "$url" "$timeout"
        ;;
    auto)
        case $(_node_classify "$target") in
        group) _node_delay_group "$target" "$url" "$timeout" ;;
        proxy) _node_delay_proxy "$target" "$url" "$timeout" ;;
        *)
            _errorcat "未找到策略组或节点：$target"
            return 1
            ;;
        esac
        ;;
    esac
}

########################################
#            帮助
########################################

node_help() {
    cat <<EOF

clashctl node - 节点切换与延迟测速

Usage:
  clashctl node [use 选项...]
  clashctl node COMMAND [选项...]

不指定 COMMAND 时进入交互式节点切换（等价于 node use）。
选项由各子命令自行解析，需写在子命令之后。

Commands:
  use                     交互/直接切换节点（默认命令）
  list, ls [组]           不带参数列出策略组；带组名列出该组成员
  delay                   延迟测速

Options:
  -h, --help              显示帮助信息

Help:
  clashctl node COMMAND -h    查看各子命令选项（-d/-u/-t/-g/-p 等）

EOF
}
