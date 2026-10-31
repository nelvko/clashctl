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
        _failcat "$CLASHCTL_KERNEL 未运行，请先执行 clashctl start"
        return 1
    }

    case "${1:-}" in
    ls | list)
        shift
        _node_list "$@"
        ;;
    delay)
        shift
        _node_delay "$@"
        ;;
    use)
        shift
        _node_use "$@"
        ;;
    -* | '')
        # 省略子命令或直接带选项 → 交互式切换；选项由 _node_use 自行解析
        _node_use "$@"
        ;;
    *)
        _errorcat "未知 node 子命令：$1"
        node_help
        return 1
        ;;
    esac
}

########################################
#            API 调用
########################################

_node_api_base() {
    local controller host
    controller=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME") || return 1
    [ -n "$controller" ] && [[ $controller == *:* ]] || return 1
    host=$(_proxy_local_host "${controller%:*}") || return 1
    local port
    port=$(_proxy_port "${controller##*:}") || return 1
    printf 'http://%s:%s' "$host" "$port"
}

# 统一 curl 封装：--noproxy '*' 避免走系统代理；secret 非空时带 Bearer
# 用法：_node_curl <METHOD> <PATH> [额外 curl 参数...]
_node_curl() {
    local method=$1 path=$2
    shift 2
    local secret base auth=()
    base=$(_node_api_base) || return 1
    secret=$(_get_secret) || return 1
    [ -n "$secret" ] && auth=(-H "Authorization: Bearer $secret")
    curl -s --noproxy '*' --max-time "${CLASHCTL_API_TIMEOUT:-10}" \
        -X "$method" "${auth[@]}" "${base}${path}" "$@"
}

# 路径段 URL 编码（组/节点名常含空格、中文、emoji）；LC_ALL=C 按字节百分号编码
_node_urlencode() {
    local LC_ALL=C s=$1 out='' c i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
        [a-zA-Z0-9._~-]) out+=$c ;;
        *)
            printf -v c '%%%02X' "'$c"
            out+=$c
            ;;
        esac
    done
    printf '%s' "$out"
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

########################################
#            数据读取
########################################

# 列出所有"策略组"（含 .all 成员列表的项）：name <TAB> type <TAB> now
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

# 某组的成员节点列表（每行一个）
_node_members() {
    local enc
    enc=$(_node_urlencode "$1")
    _node_curl GET "/proxies/$enc" | "$BIN_YQ" -p json '.all // [] | .[]' 2>/dev/null
}

# 一次拉取某组详情 JSON（供需同时读取 now 与 members 的场景本地复用，省一次 HTTP）
_node_group_json() {
    local enc
    enc=$(_node_urlencode "$1")
    _node_curl GET "/proxies/$enc"
}

# 某组当前选中节点
_node_now() {
    local enc
    enc=$(_node_urlencode "$1")
    _node_curl GET "/proxies/$enc" | "$BIN_YQ" -p json '.now // ""' 2>/dev/null
}

########################################
#            切换
########################################

# PUT /proxies/:group  body {"name":"<member>"}；204=成功 400=不可切换 404=组不存在
_node_apply() {
    local group=$1 member=$2 enc body code rc
    enc=$(_node_urlencode "$group")
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
    local with_delay=false
    local url timeout
    local args=()
    url=$(_node_default_delay_url)
    timeout=$(_node_default_delay_timeout)

    while [ $# -gt 0 ]; do
        case "$1" in
        -d | --delay)
            with_delay=true
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
        -h | --help)
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

    # 先缓冲所有行并按显示宽度求列宽，再补齐输出，使各列对齐
    local names=() types=() nows=() name type now
    while IFS=$'\t' read -r name type now; do
        names+=("$name")
        types+=("$type")
        nows+=("${now:-—}")
    done < <(_node_groups)

    [ ${#names[@]} -eq 0 ] && {
        _failcat "未获取到策略组（内核是否运行？）"
        return 1
    }

    local i w namew=0 noww=0
    for i in "${!names[@]}"; do
        w=$(_dispwidth "${names[$i]}")
        ((w > namew)) && namew=$w
        w=$(_dispwidth "${nows[$i]}")
        ((w > noww)) && noww=$w
    done

    for i in "${!names[@]}"; do
        printf '  %s → %s  [%s]\n' \
            "$(_pad "${names[$i]}" "$namew")" \
            "$(_pad "${nows[$i]}" "$noww")" \
            "${types[$i]}"
    done
    return 0
}

# 列出某策略组的成员节点（* 标当前选中）；成员类型仅叶子节点可知，否则显示 —
_node_list_members() {
    local group=$1
    [ "$(_node_classify "$group")" = group ] || {
        _failcat "策略组 [$group] 不存在"
        return 1
    }

    local now members=() name
    now=$(_node_now "$group")
    while IFS= read -r name; do
        [ -n "$name" ] && members+=("$name")
    done < <(_node_members "$group")

    [ ${#members[@]} -eq 0 ] && {
        _failcat "策略组 [$group] 无可用节点"
        return 1
    }

    declare -A member_types=()
    local type
    while IFS=$'\t' read -r name type; do
        [ -n "$name" ] && member_types["$name"]=$type
    done < <(_node_proxies)

    local i w namew=0
    for i in "${!members[@]}"; do
        w=$(_dispwidth "${members[$i]}")
        ((w > namew)) && namew=$w
    done

    local marker
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

_node_has_fzf() {
    command -v fzf >&/dev/null && [ -t 0 ]
}

_node_hint_fzf() {
    [ "${_NODE_FZF_HINT_SHOWN:-false}" = true ] && return 0
    [ -t 0 ] || return 0
    command -v fzf >&/dev/null && return 0

    _NODE_FZF_HINT_SHOWN=true
    _ui_info '未检测到 fzf，已使用编号选择；安装 fzf 可启用搜索式选择界面。'
}

_node_fzf_preview_dir() {
    mktemp -d "${TMPDIR:-/tmp}/clashnode-preview.XXXXXX" 2>/dev/null
}

_node_fzf_preview_cmd() {
    printf '%s' "cat \"\$NODE_FZF_PREVIEW_DIR\"/{1}"
}

_node_selected_name() {
    local selected=$1
    selected=${selected#*$'\t'}
    printf '%s\n' "${selected%%$'\t'*}"
}

# 交互选组，选中的组名输出到 stdout，菜单打到 stderr
# $1: 提示语  $2: 过滤（selector=仅可切换组 / all=全部，默认 all）
_node_pick_group() {
    local prompt=$1 filter=${2:-all}
    local names=() types=() nows=() name type now i
    while IFS=$'\t' read -r name type now; do
        [ "$filter" = selector ] && [ "$type" != Selector ] && continue
        names+=("$name")
        types+=("$type")
        nows+=("$now")
    done < <(_node_groups)

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

    local w namew=0 noww=0
    for i in "${!names[@]}"; do
        w=$(_dispwidth "${names[$i]}")
        ((w > namew)) && namew=$w
        w=$(_dispwidth "${nows[$i]:-—}")
        ((w > noww)) && noww=$w
    done

    if _node_has_fzf; then
        local selected status preview_dir preview_args=()
        preview_dir=$(_node_fzf_preview_dir)
        if [ -n "$preview_dir" ]; then
            preview_args=(--preview "$(_node_fzf_preview_cmd)" --preview-window='right:45%:wrap')
            for i in "${!names[@]}"; do
                {
                    printf '策略组\n'
                    printf '  名称：%s\n' "${names[$i]}"
                    printf '  类型：%s\n' "${types[$i]}"
                    printf '  当前：%s\n' "${nows[$i]:-—}"
                    printf '\n节点\n'
                    local member count=0
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
        selected=$(
            for i in "${!names[@]}"; do
                printf '%s\t%s\t%s → %s  [%s]\n' \
                    "$((i + 1))" \
                    "${names[$i]}" \
                    "$(_pad "${names[$i]}" "$namew")" \
                    "$(_pad "${nows[$i]:-—}" "$noww")" \
                    "${types[$i]}"
            done | NODE_FZF_PREVIEW_DIR=$preview_dir fzf \
                --height=80% \
                --layout=reverse \
                --border \
                --delimiter=$'\t' \
                --with-nth=3 \
                --prompt="$prompt" \
                --header='选择策略组，Enter 确认，Esc 退出' \
                "${preview_args[@]}"
        )
        status=$?
        [ -n "$preview_dir" ] && rm -rf -- "$preview_dir"
        [ "$status" -eq 0 ] || return 1
        [ -n "$selected" ] || return 1
        _node_selected_name "$selected"
        return 0
    fi

    _node_hint_fzf

    # 与 ls 一致：[序号] 名字 → 当前节点 [type]，按显示宽度对齐
    local tok idxw=${#names[@]}
    idxw=${#idxw} # 序号位数；[n] 整体左对齐补齐到 idxw+2
    for i in "${!names[@]}"; do
        tok="[$((i + 1))]"
        printf '  %-*s %s → %s  [%s]\n' \
            $((idxw + 2)) "$tok" \
            "$(_pad "${names[$i]}" "$namew")" \
            "$(_pad "${nows[$i]:-—}" "$noww")" \
            "${types[$i]}" >&2
    done
    local choice
    printf '%s' "$prompt" >&2
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#names[@]} ] && {
        printf '%s\n' "${names[$((choice - 1))]}"
        return 0
    }
    _errorcat "无效选择：$choice"
    return 1
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

    local w namew=0
    for i in "${!names[@]}"; do
        w=$(_dispwidth "${names[$i]}")
        ((w > namew)) && namew=$w
    done

    if _node_has_fzf; then
        local selected status preview_dir preview_args=()
        preview_dir=$(_node_fzf_preview_dir)
        if [ -n "$preview_dir" ]; then
            preview_args=(--preview "$(_node_fzf_preview_cmd)" --preview-window='right:45%:wrap')
            for i in "${!names[@]}"; do
                {
                    printf '节点\n'
                    printf '  名称：%s\n' "${names[$i]}"
                    printf '  类型：%s\n' "${types[$i]}"
                } >"$preview_dir/$((i + 1))"
            done
        fi
        selected=$(
            for i in "${!names[@]}"; do
                printf '%s\t%s\t%s  [%s]\n' \
                    "$((i + 1))" \
                    "${names[$i]}" \
                    "$(_pad "${names[$i]}" "$namew")" \
                    "${types[$i]}"
            done | NODE_FZF_PREVIEW_DIR=$preview_dir fzf \
                --height=80% \
                --layout=reverse \
                --border \
                --delimiter=$'\t' \
                --with-nth=3 \
                --prompt="$prompt" \
                --header='选择节点，Enter 确认，Esc 退出' \
                "${preview_args[@]}"
        )
        status=$?
        [ -n "$preview_dir" ] && rm -rf -- "$preview_dir"
        [ "$status" -eq 0 ] || return 1
        [ -n "$selected" ] || return 1
        _node_selected_name "$selected"
        return 0
    fi

    _node_hint_fzf

    local tok idxw=${#names[@]}
    idxw=${#idxw}
    for i in "${!names[@]}"; do
        tok="[$((i + 1))]"
        printf '  %-*s %s  [%s]\n' $((idxw + 2)) "$tok" "${names[$i]}" "${types[$i]}" >&2
    done

    local choice
    printf '%s' "$prompt" >&2
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#names[@]} ] && {
        printf '%s\n' "${names[$((choice - 1))]}"
        return 0
    }
    _errorcat "无效选择：$choice"
    return 1
}

# 交互选组内节点，选中的节点名输出到 stdout，菜单打到 stderr（* 标记当前）
_node_pick_member() {
    local group=$1
    local with_delay=${2:-false}
    local url=${3:-}
    local timeout=${4:-}
    local now members=() name delay i marker delay_label
    local group_json
    group_json=$(_node_group_json "$group") # 一次拉取，本地抽取 now 与 members
    now=$("$BIN_YQ" -p json '.now // ""' <<<"$group_json" 2>/dev/null)
    while IFS= read -r name; do
        [ -n "$name" ] && members+=("$name")
    done < <("$BIN_YQ" -p json '.all // [] | .[]' <<<"$group_json" 2>/dev/null)

    [ ${#members[@]} -eq 0 ] && {
        _errorcat "策略组 [$group] 无可用节点"
        return 1
    }

    declare -A delays=()
    if [ "$with_delay" = true ]; then
        _ui_step "正在测速 [$group]（可能需要数秒）..."
        [ -n "$url" ] || url=$(_node_default_delay_url)
        [ -n "$timeout" ] || timeout=$(_node_default_delay_timeout)
        while IFS=$'\t' read -r name delay; do
            [ -n "$name" ] && delays["$name"]=$delay
        done < <(_node_delay_rows "$group" "$url" "$timeout" "${members[@]}")
    fi

    local delayw=0 namew=0 w pad
    if [ "$with_delay" = true ]; then
        for i in "${!members[@]}"; do
            w=$(_dispwidth "${members[$i]}")
            ((w > namew)) && namew=$w
            delay_label=$(_node_delay_label "${delays[${members[$i]}]:-}")
            w=$(_dispwidth "$delay_label")
            ((w > delayw)) && delayw=$w
        done
    fi

    if _node_has_fzf; then
        local selected fzf_header='* 表示当前节点；Enter 切换，Esc 退出'
        [ "$with_delay" = true ] && {
            fzf_header='* 表示当前节点；Enter 切换，Esc 退出'
        }
        declare -A proxy_types=()
        while IFS=$'\t' read -r name type; do
            [ -n "$name" ] && proxy_types["$name"]=$type
        done < <(_node_proxies)

        local status preview_dir preview_args=()
        preview_dir=$(_node_fzf_preview_dir)
        if [ -n "$preview_dir" ]; then
            preview_args=(--preview "$(_node_fzf_preview_cmd)" --preview-window='right:45%:wrap')
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
                        delay_label=$(_node_delay_label "${delays[${members[$i]}]:-}")
                        printf '  延迟：%s\n' "$delay_label"
                    fi
                } >"$preview_dir/$((i + 1))"
            done
        fi

        selected=$(
            for i in "${!members[@]}"; do
                marker=' '
                [ "${members[$i]}" = "$now" ] && marker='*'
                if [ "$with_delay" = true ]; then
                    delay_label=$(_node_delay_label "${delays[${members[$i]}]:-}")
                    pad=$((delayw - $(_dispwidth "$delay_label")))
                    printf '%s\t%s\t%s %s  %s\n' \
                        "$((i + 1))" \
                        "${members[$i]}" \
                        "$marker" \
                        "$(_pad "${members[$i]}" "$namew")" \
                        "$(_node_spaces "$pad")$(_node_delay_color "$delay_label")"
                else
                    printf '%s\t%s\t%s %s\n' "$((i + 1))" "${members[$i]}" "$marker" "${members[$i]}"
                fi
            done | NODE_FZF_PREVIEW_DIR=$preview_dir fzf \
                --height=80% \
                --layout=reverse \
                --border \
                --ansi \
                --delimiter=$'\t' \
                --with-nth=3 \
                --prompt="${group} > " \
                --header="$fzf_header" \
                "${preview_args[@]}"
        )
        status=$?
        [ -n "$preview_dir" ] && rm -rf -- "$preview_dir"
        [ "$status" -eq 0 ] || return 1
        [ -n "$selected" ] || return 1
        _node_selected_name "$selected"
        return 0
    fi

    _node_hint_fzf

    local marker tok idxw=${#members[@]}
    idxw=${#idxw} # 序号位数；[n] 整体左对齐补齐到 idxw+2，使括号紧凑且名字列对齐
    for i in "${!members[@]}"; do
        marker=' '
        [ "${members[$i]}" = "$now" ] && marker='*'
        tok="[$((i + 1))]"
        if [ "$with_delay" = true ]; then
            delay_label=$(_node_delay_label "${delays[${members[$i]}]:-}")
            pad=$((delayw - $(_dispwidth "$delay_label")))
            printf '%s %-*s %s  %s\n' \
                "$marker" $((idxw + 2)) "$tok" \
                "$(_pad "${members[$i]}" "$namew")" \
                "$(_node_spaces "$pad")$(_node_delay_color "$delay_label")" >&2
        else
            printf '%s %-*s %s\n' "$marker" $((idxw + 2)) "$tok" "${members[$i]}" >&2
        fi
    done
    local choice
    printf '%s' '请选择要切换到的节点（* 为当前）：' >&2
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#members[@]} ] && {
        printf '%s\n' "${members[$((choice - 1))]}"
        return 0
    }
    _errorcat "无效选择：$choice"
    return 1
}

########################################
#            延迟测速
########################################

# 读取 stdin 的 "name<TAB>delay" 行，按延迟升序着色输出（超时排末尾）
_node_print_delays() {
    local name delay
    while IFS=$'\t' read -r name delay; do
        if [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ]; then
            printf '%010d\t%s\t%s\n' "$delay" "$name" "$delay"
        else
            printf '%010d\t%s\t%s\n' 9999999999 "$name" "timeout"
        fi
    done | sort -n | {
        local disp color text
        while IFS=$'\t' read -r _ name disp; do
            if [ "$disp" = timeout ]; then
                color=#f92f60
                text=$(printf '  ✗ %-26s 超时' "$name")
            elif [ "$disp" -lt 200 ]; then
                color=#26de81
                text=$(printf '  ● %-26s %sms' "$name" "$disp")
            elif [ "$disp" -lt 500 ]; then
                color=#fed330
                text=$(printf '  ● %-26s %sms' "$name" "$disp")
            else
                color=#fd79a8
                text=$(printf '  ● %-26s %sms' "$name" "$disp")
            fi
            _color_log "$color" "$text"
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
    local label=$1 color
    case $label in
    timeout)
        color=#f92f60
        ;;
    *ms)
        local delay=${label%ms}
        if [ "$delay" -lt 200 ]; then
            color=#26de81
        elif [ "$delay" -lt 500 ]; then
            color=#fed330
        else
            color=#fd79a8
        fi
        ;;
    *)
        color=#f92f60
        ;;
    esac
    _node_color_text "$color" "$label"
}

_node_color_text() {
    local color=$1 text=$2 hex r g b
    hex=${color#\#}
    r=$((16#${hex:0:2}))
    g=$((16#${hex:2:2}))
    b=$((16#${hex:4:2}))
    printf '\033[38;2;%s;%s;%sm%s\033[0m' "$r" "$g" "$b" "$text"
}

_node_spaces() {
    local count=$1
    ((count < 1)) && return 0
    printf '%*s' "$count" ''
}

# 主路径：GET /group/:name/delay 返回 {name:ms}；按组成员补全超时项
_node_delay_primary() {
    local group=$1 body=$2
    local name delay
    declare -A delays=()
    while IFS=$'\t' read -r name delay; do
        delays["$name"]=$delay
    done < <("$BIN_YQ" -p json 'to_entries | .[] | [.key, .value] | @tsv' <<<"$body" 2>/dev/null)

    {
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            printf '%s\t%s\n' "$name" "${delays[$name]:-}"
        done < <(_node_members "$group")
    } | _node_print_delays
}

_node_delay_one() {
    local name=$1 qs=$2 enc resp delay
    enc=$(_node_urlencode "$name")
    resp=$(_node_curl GET "/proxies/$enc/delay?$qs")
    delay=$("$BIN_YQ" -p json '.delay // ""' <<<"$resp" 2>/dev/null)
    printf '%s\t%s\n' "$name" "$delay"
}

_node_delay_member_rows() {
    local url=$1 timeout=$2
    shift 2
    local members=("$@") name
    local qs concurrency active=0
    qs="timeout=${timeout}&url=$(_node_urlencode "$url")"
    concurrency=${CLASHCTL_NODE_DELAY_CONCURRENCY:-8}
    [[ "$concurrency" =~ ^[0-9]+$ ]] || concurrency=8
    ((concurrency < 1)) && concurrency=1

    {
        for name in "${members[@]}"; do
            _node_delay_one "$name" "$qs" &
            ((active += 1))
            if ((active >= concurrency)); then
                wait
                active=0
            fi
        done
        wait
    }
}

_node_delay_rows() {
    local group=$1 url=$2 timeout=$3
    shift 3
    local members=("$@")
    local enc qs resp code body name delay
    enc=$(_node_urlencode "$group")
    qs="timeout=${timeout}&url=$(_node_urlencode "$url")"
    resp=$(_node_curl GET "/group/$enc/delay?$qs" -w $'\n%{http_code}')
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}

    if [ "$code" = 200 ]; then
        declare -A delays=()
        while IFS=$'\t' read -r name delay; do
            [ -n "$name" ] && delays["$name"]=$delay
        done < <("$BIN_YQ" -p json 'to_entries | .[] | [.key, .value] | @tsv' <<<"$body" 2>/dev/null)

        for name in "${members[@]}"; do
            printf '%s\t%s\n' "$name" "${delays[$name]:-}"
        done
        return 0
    fi

    _node_delay_member_rows "$url" "$timeout" "${members[@]}"
}

# 回退路径：并发 GET /proxies/:proxy/delay（旧内核无 /group 端点时）
_node_delay_fallback() {
    local group=$1 url=$2 timeout=$3
    local members=() name
    while IFS= read -r name; do
        [ -n "$name" ] && members+=("$name")
    done < <(_node_members "$group")

    [ ${#members[@]} -eq 0 ] && {
        _failcat "策略组 [$group] 无节点或不存在"
        return 1
    }

    _node_delay_member_rows "$url" "$timeout" "${members[@]}" | _node_print_delays
}

_node_delay_group() {
    local group=$1 url=$2 timeout=$3
    local enc qs resp code body
    enc=$(_node_urlencode "$group")
    qs="timeout=${timeout}&url=$(_node_urlencode "$url")"

    _ui_emit_fd 1 step "正在测速策略组 [$group]（可能需要数秒）..."
    resp=$(_node_curl GET "/group/$enc/delay?$qs" -w $'\n%{http_code}')
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}

    case "$code" in
    200) _node_delay_primary "$group" "$body" ;;
    *) _node_delay_fallback "$group" "$url" "$timeout" ;; # 旧内核无 /group 端点：回退逐节点
    esac
}

_node_delay_proxy() {
    local proxy=$1 url=$2 timeout=$3
    _ui_emit_fd 1 step "正在测速节点 [$proxy]..."
    _node_delay_member_rows "$url" "$timeout" "$proxy" | _node_print_delays
}

_node_delay() {
    local url timeout mode=auto
    local args=()
    url=$(_node_default_delay_url)
    timeout=$(_node_default_delay_timeout)

    while [ $# -gt 0 ]; do
        case "$1" in
        -h | --help)
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

    _node_validate_delay_url "$url" || return 1
    _node_validate_delay_timeout "$timeout" || return 1

    set -- "${args[@]}"
    local target=${1:-}
    [ $# -gt 1 ] && {
        _errorcat "用法：clashctl node delay [-g|-p] [-u URL] [-t 毫秒] [名称]"
        return 1
    }

    case $mode in
    group)
        [ -z "$target" ] && { target=$(_node_pick_group "请选择要测速的策略组：" all) || return 1; }
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
        if [ -z "$target" ]; then
            target=$(_node_pick_group "请选择要测速的策略组：" all) || return 1
            _node_delay_group "$target" "$url" "$timeout"
            return
        fi
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
操作当前启用订阅的策略组和节点，要求内核正在运行。
也可在 clashctl tui 的订阅菜单选择节点。
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
