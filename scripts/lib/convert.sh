#!/usr/bin/env bash

# allow_convert=false（raw 策略）时，校验失败即失败，不回退 subconverter。
_download_config() {
    local dest=$1
    local url=$2
    local allow_convert=${3:-true}
    [ "${url:0:4}" = 'file' ] || _ui_emit_fd 1 step '下载订阅'
    _download_raw_config "$dest" "$url" || return 1
    _normalize_sub_config "$dest" || return 1

    _is_html_response "$dest" && {
        _errorcat "订阅响应疑似 HTML 页面，请检查订阅链接或 User-Agent"
        return 1
    }

    _is_native_yaml_config "$dest" && {
        if [ "${CLASHCTL_INSTALL_RUNNING:-}" != 1 ] || [ "${_INSTALL_VERBOSE:-}" = 1 ]; then
            _ui_emit_fd 1 info '检测到原生 Clash/Mihomo 配置'
        fi
        _valid_config "$dest" && _valid_sub_nodes "$dest" && return
        [ "$allow_convert" = true ] || {
            _errorcat "raw 模式下原生配置校验失败（未尝试转换），可改用默认策略或 --convert"
            return 1
        }
        _ui_warn "原生配置验证失败：尝试订阅转换..."
        cat "$dest" >"${dest}.raw"
        _download_convert_config "$dest" "$url" || return
        _normalize_sub_config "$dest" || return
        _valid_config "$dest" && _valid_sub_nodes "$dest"
        return
    }

    _ui_emit_fd 1 step '验证订阅配置...'
    _valid_config "$dest" && _valid_sub_nodes "$dest" && return

    [ "$allow_convert" = true ] || {
        _errorcat "raw 模式下配置校验失败（未尝试转换），可改用默认策略或 --convert"
        return 1
    }
    _ui_warn "验证失败：尝试订阅转换..."
    cat "$dest" >"${dest}.raw"
    _download_convert_config "$dest" "$url" || return
    _normalize_sub_config "$dest" || return
    _valid_config "$dest" && _valid_sub_nodes "$dest"
}

_normalize_sub_config() {
    local dest=$1

    [ -s "$dest" ] || {
        _errorcat "订阅响应为空，请检查订阅链接"
        return 1
    }

    LC_ALL=C sed -i '1s/^\xEF\xBB\xBF//' "$dest" 2>/dev/null || true
    sed -i 's/\r$//' "$dest" 2>/dev/null || true

    command -v iconv >/dev/null || return 0
    iconv -f UTF-8 -t UTF-8 "$dest" >/dev/null 2>&1 && return 0

    local charset
    for charset in GB18030 GBK BIG5; do
        iconv -f "$charset" -t UTF-8 "$dest" -o "${dest}.utf8" 2>/dev/null && {
            /bin/mv -f "${dest}.utf8" "$dest"
            _okcat '🔤' "订阅已从 $charset 转为 UTF-8"
            return 0
        }
    done

    /usr/bin/rm -f "${dest}.utf8" 2>/dev/null
    return 0
}

_is_html_response() {
    # 优先识别原生配置，避免HTML标签触发误判
    _is_native_yaml_config "$1" && return 1
    LC_ALL=C grep -qiE '<[[:space:]]*(!doctype|html|head|body|title)([[:space:]>]|$)' "$1"
}

_is_native_yaml_config() {
    "$BIN_YQ" -e '
      ((.proxies // []) | (type == "!!seq" and length > 0)) or
      ((.proxy-providers // {}) | (type == "!!map" and length > 0))
    ' "$1" >/dev/null 2>&1
}

_valid_sub_nodes() {
    local config=$1 count
    count=$("$BIN_YQ" '
      ((.proxies // []) | length) +
      ((.proxy-providers // {}) | length)
    ' "$config" 2>/dev/null) || return 0

    [ "${count:-0}" -gt 0 ] || {
        _errorcat "订阅未解析出任何节点，请检查订阅内容或转换器版本"
        return 1
    }
}

_download_raw_config() {
    local dest=$1
    local url=$2

    # 抓取响应头以解析机场流量信息（subscription-userinfo）。curl 用 --dump-header；
    # wget 回退路径不抓头（流量信息为尽力而为，绝大多数走 curl）。
    local header hdr_opt=()
    header=$(mktemp "${CLASH_RESOURCES_DIR}/.header.XXXXXX" 2>/dev/null) && hdr_opt=(--dump-header "$header")

    # --connect-timeout 快速判定不可达；--max-time 为单次尝试总时长；
    # --retry + --retry-delay + --retry-connrefused 让海外/抖动订阅真正获得重试机会。
    curl \
        --silent \
        --show-error \
        --fail \
        --insecure \
        --location \
        --connect-timeout "${CLASHCTL_SUB_CONNECT_TIMEOUT:-5}" \
        --max-time "${CLASHCTL_SUB_TIMEOUT:-20}" \
        --retry "${CLASHCTL_SUB_RETRY:-2}" \
        --retry-delay 1 \
        --retry-connrefused \
        --user-agent "$CLASHCTL_SUB_UA" \
        "${hdr_opt[@]}" \
        --output "$dest" \
        "$url" ||
        wget \
            --no-verbose \
            --no-check-certificate \
            --connect-timeout "${CLASHCTL_SUB_CONNECT_TIMEOUT:-5}" \
            --timeout "${CLASHCTL_SUB_TIMEOUT:-20}" \
            --tries "$((${CLASHCTL_SUB_RETRY:-2} + 1))" \
            --user-agent "$CLASHCTL_SUB_UA" \
            --output-document "$dest" \
            "$url"
    local rc=$?

    [ -n "$header" ] && {
        [ "$rc" -eq 0 ] && {
            # shellcheck disable=SC2034  # 供 sub.sh 读取
            FETCH_USERINFO=$(_header_value "$header" 'subscription-userinfo')
            # shellcheck disable=SC2034
            FETCH_FILENAME=$(_attachment_filename "$header")
        }
        /usr/bin/rm -f "$header"
    }
    return "$rc"
}

# 取响应头某字段值（大小写不敏感；重定向时 curl 累积多段头，取最后一段）
_header_value() {
    local header_file=$1 key=$2
    grep -i "^[[:space:]]*${key}:" "$header_file" 2>/dev/null |
        tail -1 | cut -d: -f2- | tr -d '\r' |
        sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//'
}

# 从 content-disposition 提取文件名；优先 RFC 5987 的 filename*=（百分号编码解回 UTF-8）
_attachment_filename() {
    local header_file=$1 disposition filename
    disposition=$(_header_value "$header_file" 'content-disposition')
    [ -z "$disposition" ] && return 0

    filename=$(grep -oE "filename\*=[^;]*" <<<"$disposition" | head -1)
    if [ -n "$filename" ]; then
        filename=${filename#filename\*=}
        filename=${filename#*\'\'} # 去掉 charset''lang 前缀，如 UTF-8''
        filename=$(printf '%b' "${filename//%/\\x}")
    else
        filename=$(grep -oE 'filename="?[^";]*' <<<"$disposition" | head -1)
        filename=${filename#filename=}
        filename=${filename#\"}
    fi
    printf '%s\n' "$filename"
}

_download_convert_config() {
    local dest=$1
    local url=$2

    [ "${url:0:4}" = 'file' ] && return 0

    # 子 shell + trap 确保任何退出路径（含 Ctrl-C）都回收自己拉起的 subconverter；
    # 一次请求完成转换并落盘：--data-urlencode 负责参数编码，避免“先取 url_effective
    # 再取内容”导致 subconverter 转换两遍。
    (
        trap '_stop_convert' EXIT
        _start_convert || exit 1
        curl \
            --get \
            --silent \
            --show-error \
            --fail \
            --location \
            --max-time "${CLASHCTL_SUB_TIMEOUT:-20}" \
            --user-agent "$CLASHCTL_SUB_UA" \
            --data-urlencode "target=clash" \
            --data-urlencode "url=$url" \
            --output "$dest" \
            "http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
    )
}

_detect_subconverter_port() {
    BIN_SUBCONVERTER_PORT=$("$BIN_YQ" '.server.port' "$BIN_SUBCONVERTER_CONFIG")
    _is_port_used "$BIN_SUBCONVERTER_PORT" && {
        local new_port
        new_port=$(_get_random_port) || return
        _ui_warn "端口冲突：[subconverter] ${BIN_SUBCONVERTER_PORT}，随机分配：$new_port"
        BIN_SUBCONVERTER_PORT=$new_port
        "$BIN_YQ" -i ".server.port = $new_port" "$BIN_SUBCONVERTER_CONFIG" 2>/dev/null
    }
}

_start_convert() {
    [ -x "$BIN_SUBCONVERTER" ] || _ci_provision subconverter || return 1
    [ -x "$BIN_SUBCONVERTER" ] || {
        _errorcat "subconverter 未找到或不可执行：$BIN_SUBCONVERTER"
        return 1
    }

    # 先在配置端口上探活：已有可用实例则直接复用（不记录 PID，_stop_convert 不误杀他人实例）
    BIN_SUBCONVERTER_PORT=$("$BIN_YQ" '.server.port' "$BIN_SUBCONVERTER_CONFIG")
    local check_url="http://localhost:${BIN_SUBCONVERTER_PORT}/version"
    curl --silent --fail "$check_url" >/dev/null 2>&1 && return 0

    # 端口被其他进程占用时换端口，再拉起自己的实例并记录 PID
    _detect_subconverter_port
    check_url="http://localhost:${BIN_SUBCONVERTER_PORT}/version"
    BIN_SUBCONVERTER_PID=$(
        (
            trap - INT TERM HUP
            if typeset -f operation_lock_release >/dev/null 2>&1; then
                operation_lock_release || exit 1
            fi
            exec "$BIN_SUBCONVERTER"
        ) </dev/null >"$BIN_SUBCONVERTER_LOG" 2>&1 9>&- &
        echo $!
    )

    local start now
    start=$(date +%s)
    while ! curl --silent --fail "$check_url" >/dev/null 2>&1; do
        sleep 0.2
        now=$(date +%s)
        [ $((now - start)) -gt 10 ] && { _errorcat "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"; return 1; }
    done
    return 0
}

_stop_convert() {
    # 仅回收自己拉起的实例，避免误杀其他并发操作正在使用的 subconverter
    [ -n "${BIN_SUBCONVERTER_PID:-}" ] || return 0
    kill -TERM "$BIN_SUBCONVERTER_PID" 2>/dev/null
    sleep 0.2
    kill -KILL "$BIN_SUBCONVERTER_PID" 2>/dev/null
    BIN_SUBCONVERTER_PID=
    return 0
}
