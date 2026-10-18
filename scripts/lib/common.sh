#!/usr/bin/env bash

# shellcheck disable=SC2034
# 下载默认值（.env 物化前或环境变量未设时兜底）；GH_PROXY 默认不设 = 直连，
# 需要加速时经 --gh-proxy 旗标 / 环境变量 / .env 显式指定
[ -n "${SUBCONVERTER_REPO:-}" ] || SUBCONVERTER_REPO=asdlokj1qpi233/subconverter
[ "${CLASHCTL_DOWNLOAD_TIMEOUT+x}" = x ] || CLASHCTL_DOWNLOAD_TIMEOUT=0

# 用户态全部在 data/（gitignore 目录），resources/ 只保留跟踪的资源文件
CLASH_DATA_DIR="${CLASHCTL_HOME}/data"
CLASH_CONFIG_BASE="${CLASH_DATA_DIR}/config.yaml"
CLASH_CONFIG_MIXIN="${CLASH_DATA_DIR}/mixin.yaml"
CLASH_CONFIG_RUNTIME="${CLASH_DATA_DIR}/runtime.yaml"
# 订阅下载/校验失败时保留的调试产物（稳定路径，便于排障）
CLASH_CONFIG_DEBUG="${CLASH_DATA_DIR}/last-failed.yaml"
CLASH_CONFIG_DEBUG_RAW="${CLASH_DATA_DIR}/last-failed.raw"

CLASH_RESOURCES_DIR="${CLASHCTL_HOME}/resources"

BIN_BASE_DIR="${CLASHCTL_HOME}/bin"
# fish 托管块首行标记：写入/识别/清理共用（preflight.sh 的 revoke 同引此量）
CLASHCTL_FISH_MANAGED_MARKER='# clashctl shell-rc (managed by install.sh, do not edit)'
# 内核只使用单层布局。
bin_kernel_path() {
    printf '%s/mihomo\n' "$BIN_BASE_DIR"
}
BIN_KERNEL=$(bin_kernel_path)
BIN_YQ="${BIN_BASE_DIR}/yq"

# 兼容性判定：仅 mikefarah yq v4（发行版打包的 Python yq 是 jq 语法，不兼容）。
# 成功输出系统 yq 路径，不兼容/未安装时返回非零。
_get_system_yq() {
    local yq_path
    command -v yq >/dev/null 2>&1 || return 1
    case $(yq --version 2>&1) in
    *mikefarah*v4.*) ;;
    *) return 1 ;;
    esac
    yq_path=$(command -v yq) || return 1
    printf '%s\n' "$yq_path"
}

# 本地未下载 yq 时复用系统兼容副本；bin/yq 一旦存在即优先——
# 系统 yq 日后被移除，重跑安装会重新下载（自愈）
if [ ! -x "$BIN_YQ" ] && _system_yq=$(_get_system_yq); then
    BIN_YQ=$_system_yq
fi
unset -v _system_yq
BIN_SUBCONVERTER_DIR="${BIN_BASE_DIR}/subconverter"
BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

CLASH_PROFILES_DIR="${CLASH_DATA_DIR}/profiles"

CLASH_PROFILES_META="${CLASH_DATA_DIR}/profiles.yaml"
CLASH_PROFILES_LOG="${CLASH_DATA_DIR}/profiles.log"
CLASH_PROFILES_LOCK="${CLASH_DATA_DIR}/profiles.lock"

CLASHCTL_CMD_DIR="${CLASHCTL_HOME}/scripts/cmd"

# GH_PROXY 加速前缀拼接的唯一入口：设置代理时输出 "<代理>/<url>"，未设置时
# 原样返回。勿在别处手写 ${GH_PROXY%/}/ 前缀（install.sh 根脚本 pre-source
# 阶段除外——它用 --gh-proxy 旗标值，且尚无本文件可加载）
gh_proxy_url() {
    local url=$1
    if [ -n "${GH_PROXY:-}" ]; then
        printf '%s/%s\n' "${GH_PROXY%/}" "$url"
    else
        printf '%s\n' "$url"
    fi
}

# 订阅入口在 Bash 中执行；终端启用行编辑，管道保留普通读取方式。
_read_subscription_url() {
    local _subscription_input=''
    if [ -t 0 ]; then
        IFS= read -e -r -p "${2:-}" _subscription_input || return
    else
        printf '%s' "${2:-}" >&2
        IFS= read -r _subscription_input || [ -n "$_subscription_input" ] || return 1
    fi
    # 普通读取或终端未处理粘贴标记时，只移除 URL 首尾的边界。
    _subscription_input=${_subscription_input#$'\033[200~'}
    _subscription_input=${_subscription_input%$'\033[201~'}
    printf -v "$1" '%s' "$_subscription_input"
}

_is_port_used() {
    local port=${1:-} sockets field
    [[ $port =~ ^[0-9]+$ ]] && [ "${#port}" -le 5 ] &&
        ((10#$port >= 1 && 10#$port <= 65535)) || return 1
    port=$((10#$port))

    # 本地地址在 ss 输出的第 5 列、netstat 输出的第 4 列。
    if command -v ss >/dev/null 2>&1 &&
        sockets=$(ss -H -lntu "sport = :$port" 2>/dev/null); then
        field=5
    else
        command -v netstat >/dev/null 2>&1 || return 1
        sockets=$(netstat -lntu 2>/dev/null) || return 1
        field=4
    fi
    awk -v expected="$port" -v field="$field" '
        {
            local_addr = $field
            sub(/^.*:/, "", local_addr)
            if (local_addr == expected) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' <<<"$sockets"
}

_is_root() {
    [ "$(id -u)" -eq 0 ]
}

_get_random_port() {
    local fail_count=0
    while [ "$fail_count" -lt 100 ]; do
        local random_port
        random_port=$(shuf -i 1024-65535 -n 1)
        ! _is_port_used "$random_port" && {
            printf '%s\n' "$random_port"
            return 0
        }
        fail_count=$((fail_count + 1))
    done
    _errorcat "未找到可用的代理端口"
}

# 端口被占用时提示并输出一个随机空闲端口；端口空闲返回 1，找不到空闲端口返回 2。
_replacement_port() {
    local label=$1 port=$2 new_port
    _is_port_used "$port" || return 1
    new_port=$(_get_random_port) || return 2
    _ui_warn "端口冲突：[$label] $port，随机分配 $new_port"
    printf '%s\n' "$new_port"
}

_get_local_ip() {
    local local_ip iface
    # 取主路由表默认出口网卡的地址：不探测公网 IP（Tun 下 ip route get
    # 会命中策略路由返回 fake-ip 段地址），主表 default 不受 Tun 影响。
    iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [ -n "$iface" ] && local_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    [ -z "$local_ip" ] && local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s\n' "$local_ip"
}

_get_random_val() {
    local value
    value=$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
    [ ${#value} -eq 48 ] || return 1
    printf '%s\n' "$value"
}

# UI 颜色策略：NO_COLOR 优先；always/never 显式覆盖自动检测。
# auto 仅在非 CI、终端能力正常且目标 fd 为 TTY 时启用颜色。
_ui_color_enabled() {
    local fd=${1:-2}

    [ "${NO_COLOR+x}" != x ] || return 1
    case ${CLASHCTL_COLOR:-auto} in
    always) return 0 ;;
    never) return 1 ;;
    esac
    [ "${CI+x}" != x ] || return 1
    [ "${TERM:-dumb}" != dumb ] || return 1
    [ -t "$fd" ]
}

# 两套前缀共用颜色与输出流规则。
_ui_print_fd() {
    local fd=$1 level=$2 prefix=$3 msg=$4 color
    case $level in
    step) color=36 ;;
    ok) color=32 ;;
    warn) color=33 ;;
    error | fail) color=31 ;;
    info | *) color=36 ;;
    esac
    if _ui_color_enabled "$fd"; then
        if [ "$level" = step ]; then
            printf '\033[1;%sm%s %s\033[0m\n' "$color" "$prefix" "$msg" >&"$fd"
        else
            printf '\033[1;%sm%s\033[0m %s\n' "$color" "$prefix" "$msg" >&"$fd"
        fi
    else
        printf '%s %s\n' "$prefix" "$msg" >&"$fd"
    fi
    return 0
}

# 日常命令保留旧版 emoji；安装、卸载使用结构化前缀。
_ui_emoji_emit_fd() {
    local fd=${1:-2} level=${2:-info} msg=${3:-} override=${4:-} prefix
    case $level in
    step) prefix='⏳' ;;
    ok) prefix='😼' ;;
    warn) prefix='⚠️' ;;
    error) prefix='📢' ;;
    fail) prefix='😾' ;;
    info | *) prefix='ℹ️' ;;
    esac
    [ -z "$override" ] || prefix=$override
    _ui_print_fd "$fd" "$level" "$prefix" "$msg"
}

_install_ui_emit_fd() {
    local fd=${1:-2} level=${2:-info} msg=${3:-} prefix
    case $level in
    step) prefix='[STEP]' ;;
    ok) prefix='[ OK ]' ;;
    warn) prefix='[WARN]' ;;
    error | fail) prefix='[FAIL]' ;;
    info | *) prefix='[INFO]' ;;
    esac
    # 前缀均为六列，正文从第 8 列开始。
    [ "$level" != step ] || printf '\n' >&"$fd"
    _ui_print_fd "$fd" "$level" "$prefix" "$msg"
}

# 共用库由日常命令调用时用 emoji；安装/卸载在其子 Shell 中提供输出函数。
_ui_emit_fd() {
    if typeset -f _install_ui_output >/dev/null 2>&1; then
        _install_ui_output "$@"
    else
        _ui_emoji_emit_fd "$@"
    fi
}

_install_ui_step() { _install_ui_emit_fd 2 step "$*"; }
_install_ui_info() { _install_ui_emit_fd 2 info "$*"; }
_install_ui_ok() { _install_ui_emit_fd 2 ok "$*"; }
_install_ui_warn() { _install_ui_emit_fd 2 warn "$*"; }
_install_ui_error() { _install_ui_emit_fd 2 error "$*"; }

_ui_step() { _ui_emit_fd 2 step "$*"; }
_ui_info() { _ui_emit_fd 2 info "$*"; }
_ui_ok() { _ui_emit_fd 2 ok "$*"; }
_ui_warn() { _ui_emit_fd 2 warn "$*"; }
_ui_error() { _ui_emit_fd 2 error "$*"; }

_ui_ok_out() {
    _ui_emit_fd 1 ok "$*"
}

_ui_fail() {
    _ui_emit_fd 2 fail "$*"
    return 1
}

_ui_detail() {
    local label=${1:-} indent='   '
    if typeset -f _install_ui_output >/dev/null 2>&1; then
        indent='       '
    fi
    [ $# -gt 0 ] && shift

    if [ $# -gt 0 ]; then
        printf '%s%s: %s\n' "$indent" "$label" "$*" >&2
    else
        printf '%s%s\n' "$indent" "$label" >&2
    fi
    return 0
}

_okcat() {
    local emoji=''
    if [ $# -gt 1 ]; then emoji=$1; shift; fi
    _ui_emit_fd 1 ok "$1" "$emoji"
    return 0
}

_failcat() {
    local emoji=''
    if [ $# -gt 1 ]; then emoji=$1; shift; fi
    _ui_emit_fd 2 fail "$1" "$emoji"
    return 1
}

_errorcat() {
    [ $# -gt 0 ] && {
        local emoji=''
        if [ $# -gt 1 ]; then emoji=$1; shift; fi
        _ui_emit_fd 2 error "$*" "$emoji"
    }
    return 1
}

# 估算字符串终端显示宽度：CJK/emoji 计 2 列，旗帜按对各计 1（合 2），
# VS16(FE0F) 把前一字符提升为宽。依赖 UTF-8 locale 下的逐字符索引。
_dispwidth() {
    local s=$1 w=0 i c cp
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        printf -v cp '%d' "'$c"
        if ((cp == 0xFE0F)); then
            ((w += 1)) # 变体选择符：补足前一字符到宽
        elif ((cp >= 0x1100 && cp <= 0x115F)) ||
            ((cp >= 0x2E80 && cp <= 0xA4CF)) ||
            ((cp >= 0xAC00 && cp <= 0xD7A3)) ||
            ((cp >= 0xF900 && cp <= 0xFAFF)) ||
            ((cp >= 0xFE30 && cp <= 0xFE4F)) ||
            ((cp >= 0xFF00 && cp <= 0xFF60)) ||
            ((cp >= 0xFFE0 && cp <= 0xFFE6)) ||
            ((cp >= 0x1F300 && cp <= 0x1FAFF)) ||
            ((cp >= 0x20000 && cp <= 0x3FFFD)); then
            ((w += 2))
        else
            ((w += 1))
        fi
    done
    printf '%d' "$w"
}

# 按显示宽度右侧补空格，使字符串占满 target 列
_pad() {
    local s=$1 target=$2 w pad
    w=$(_dispwidth "$s")
    pad=$((target - w))
    ((pad < 0)) && pad=0
    printf '%s%*s' "$s" "$pad" ''
}

# URL 编码（组名、节点名、认证信息常含空格、中文、emoji）；LC_ALL=C 按字节百分号编码。
_urlencode() {
    local LC_ALL=C value=$1 encoded='' character code index
    for ((index = 0; index < ${#value}; index++)); do
        character=${value:index:1}
        case $character in
        [a-zA-Z0-9._~-]) encoded+=$character ;;
        *)
            printf -v code '%%%02X' "'$character"
            encoded+=$code
            ;;
        esac
    done
    printf '%s' "$encoded"
}

_has_fzf() {
    command -v fzf >&/dev/null && [ -t 0 ]
}

# 选择菜单都在命令替换里执行，提示无法跨调用去重。
_hint_fzf() {
    [ -t 0 ] || return 0
    command -v fzf >&/dev/null && return 0
    _ui_info '未检测到 fzf，已使用编号选择；安装 fzf 可启用搜索式选择界面。'
}

# 多个字符串中最大的显示宽度
_max_width() {
    local s w max=0
    for s; do
        w=$(_dispwidth "$s")
        ((w > max)) && max=$w
    done
    printf '%d' "$max"
}

# 交互选择的公共部分；各菜单的显示格式由调用方拼好。
# 预览文件放在临时目录里，按从 1 开始的序号命名。
_pick_preview_dir() {
    mktemp -d "${TMPDIR:-/tmp}/clashctl-pick.XXXXXX" 2>/dev/null
}

# fzf 选择：stdin 每行 "序号<TAB>名称<TAB>显示文本"，选中的名称输出到 stdout。
# 用法：_pick_fzf <提示> <标题> <预览目录或空> [额外 fzf 参数…]；结束后删除预览目录。
_pick_fzf() {
    local prompt=$1 header=$2 preview_dir=$3 selected status preview_args=()
    shift 3
    # fzf 在其子 shell 中展开 {1} 与 $CLASHCTL_PICK_PREVIEW_DIR，故此处刻意用单引号
    # shellcheck disable=SC2016
    [ -n "$preview_dir" ] && preview_args=(--preview 'cat "$CLASHCTL_PICK_PREVIEW_DIR"/{1}' --preview-window='right:45%:wrap')
    selected=$(CLASHCTL_PICK_PREVIEW_DIR=$preview_dir fzf \
        --height=80% \
        --layout=reverse \
        --border \
        --delimiter=$'\t' \
        --with-nth=3 \
        --prompt="$prompt" \
        --header="$header" \
        "${preview_args[@]}" "$@")
    status=$?
    [ -n "$preview_dir" ] && rm -rf -- "$preview_dir"
    [ "$status" -eq 0 ] && [ -n "$selected" ] || return 1
    selected=${selected#*$'\t'}
    printf '%s\n' "${selected%%$'\t'*}"
}

# 编号选择：菜单由调用方先打到 stderr，这里读入序号并输出对应的名称。
# 用法：_pick_read <提示> <名称…>
_pick_read() {
    local prompt=$1 choice
    shift
    printf '%s' "$prompt" >&2
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $# ] && {
        printf '%s\n' "${@:choice:1}"
        return 0
    }
    _errorcat "无效选择：$choice"
    return 1
}

_set_env() {
    local key=$1
    local value=$2
    local env_path="${CLASHCTL_ENV_PATH:-${CLASHCTL_HOME}/.env}"
    local quoted tmp line content='' found=0

    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    printf -v quoted '%q' "$value"
    if [ -f "$env_path" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
            "$key="*) content+="$key=$quoted"$'\n' found=1 ;;
            *) content+="$line"$'\n' ;;
            esac
        done <"$env_path" || return 1
    fi
    [ "$found" -eq 1 ] || content+="$key=$quoted"$'\n'
    # 整份内容一次写入临时文件，失败时只需回滚一次。
    tmp=$(mktemp "${env_path}.tmp.XXXXXX") || return 1
    if ! chmod 0600 "$tmp" || ! printf '%s' "$content" >"$tmp"; then
        command rm -f -- "$tmp"
        return 1
    fi
    /bin/mv -f -- "$tmp" "$env_path"
}

detect_rc() {
    # 卸载依据已有文件清理，不要求用户仍安装着对应的 Shell。
    if [ "${1:-}" = --installed ]; then
        SHELL_RC_BASH="${HOME}/.bashrc"
        SHELL_RC_ZSH="${HOME}/.zshrc"
        SHELL_RC_FISH="${HOME}/.config/fish/conf.d/clashctl.fish"
        return 0
    fi
    SHELL_RC_BASH=
    SHELL_RC_ZSH=
    SHELL_RC_FISH=
    command -v bash >&/dev/null && {
        SHELL_RC_BASH="${HOME}/.bashrc"
    }
    command -v zsh >&/dev/null && {
        SHELL_RC_ZSH="${HOME}/.zshrc"
    }
    command -v fish >&/dev/null && [ -d "${HOME}/.config/fish" ] && {
        SHELL_RC_FISH="${HOME}/.config/fish/conf.d/clashctl.fish"
    }
}

# 幂等写入 bash/zsh 的 clashctl 引导块。返回 2 表示现有托管标记不完整，
# 调用方必须保留原文件并提示人工处理。
_append_source_block() {
    local rc=$1
    local tmp quoted mode

    [ -f "$rc" ] || return 0
    rc=$(readlink -f -- "$rc" 2>/dev/null) || return 1
    awk '
        $0 == "# >>> clashctl >>>" {
            if (managed) exit 1
            managed = 1
            next
        }
        $0 == "# <<< clashctl <<<" {
            if (!managed) exit 1
            managed = 0
        }
        END { if (managed) exit 1 }
    ' "$rc" >/dev/null || return 2
    tmp=$(mktemp "${rc}.clashctl.XXXXXX") || return 1
    mode=$(stat -c %a -- "$rc" 2>/dev/null) || mode=0600
    printf -v quoted '%q' "$CLASHCTL_HOME"
    # 去掉旧块后补齐末尾换行再追加新块；任一步失败都清理临时文件。
    # shellcheck disable=SC2016 # 变量应在新 shell 加载 rc 时展开
    if ! {
        awk '
            /^# >>> clashctl >>>$/ { managed=1; next }
            /^# <<< clashctl <<<$/{ managed=0; next }
            managed { next }
           { print }
        ' "$rc" >"$tmp" &&
            { [ ! -s "$tmp" ] || [ "$(tail -c 1 -- "$tmp" | wc -l)" -ne 0 ] || printf '\n' >>"$tmp"; } &&
            printf '%s\n' '# >>> clashctl >>>' "export CLASHCTL_HOME=$quoted" \
                '[ -s "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ] && . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"' \
                '# <<< clashctl <<<' >>"$tmp" &&
            chmod "$mode" "$tmp" && /bin/mv -f -- "$tmp" "$rc"
    }; then
        command rm -f -- "$tmp"
        return 1
    fi
}

# 只删除指向当前安装的完整托管块。
_remove_source_block() {
    local rc=$1 tmp mode quoted parse_rc=0

    [ -f "$rc" ] || return 0
    rc=$(readlink -f -- "$rc" 2>/dev/null) || return 1
    tmp=$(mktemp "${rc}.clashctl.XXXXXX") || return 1
    mode=$(stat -c %a -- "$rc" 2>/dev/null) || mode=0600
    printf -v quoted '%q' "$CLASHCTL_HOME"

    CLASHCTL_RC_EXPORT="export CLASHCTL_HOME=$quoted" awk '
        BEGIN { expected = ENVIRON["CLASHCTL_RC_EXPORT"] }
        !managed && $0 == "# >>> clashctl >>>" {
            managed = 1; owned = 0; foreign = 0
            buffered = $0 ORS
            next
        }
        managed {
            buffered = buffered $0 ORS
            if ($0 == expected) owned = 1
            else if ($0 ~ /^export CLASHCTL_HOME=/ || $0 == "# >>> clashctl >>>") foreign = 1
            if ($0 == "# <<< clashctl <<<") {
                if (owned && !foreign) removed = 1
                else printf "%s", buffered
                managed = 0; buffered = ""
            }
            next
        }
        { print }
        END {
            if (managed) printf "%s", buffered
            if (!removed) exit 2
        }
    ' "$rc" >"$tmp" || parse_rc=$?
    # 无匹配时保留原文件及其时间戳，包括没有末尾换行的情况。
    if [ "$parse_rc" -eq 2 ]; then
        command rm -f -- "$tmp"
        return 0
    fi
    if [ "$parse_rc" -ne 0 ] || ! chmod "$mode" "$tmp" || ! /bin/mv -f -- "$tmp" "$rc"; then
        command rm -f -- "$tmp"
        return 1
    fi
}

# 输出 fish 单引号字符串字面量。
_fish_quote() {
    local value=${1//\\/\\\\}
    value=${value//\'/\\\'}
    printf "'%s'" "$value"
}

_fish_home_export() {
    printf 'set -gx CLASHCTL_HOME %s\n' "$(_fish_quote "$CLASHCTL_HOME")"
}

# 将 clashctl.fish 以内容快照方式写入 fish 配置；内容无变化时也视为成功。
_write_fish_rc() {
    [ -n "$SHELL_RC_FISH" ] || return 2

    if [ -e "$SHELL_RC_FISH" ] || [ -L "$SHELL_RC_FISH" ]; then
        [ ! -L "$SHELL_RC_FISH" ] &&
            head -n 1 -- "$SHELL_RC_FISH" 2>/dev/null |
            grep -Fqx "$CLASHCTL_FISH_MANAGED_MARKER" || return 3
    fi

    local fish_dir
    fish_dir=$(dirname -- "$SHELL_RC_FISH")
    mkdir -p -- "$fish_dir" || return 1
    local tmp
    tmp=$(mktemp "${fish_dir}/.clashctl.fish.XXXXXX") || return 1
    {
        printf '%s\n' "$CLASHCTL_FISH_MANAGED_MARKER"
        _fish_home_export
        printf '\n'
        cat -- "$CLASHCTL_CMD_DIR/clashctl.fish"
    } >"$tmp" || {
        command rm -f -- "$tmp"
        return 1
    }
    if cmp -s -- "$tmp" "$SHELL_RC_FISH"; then
        command rm -f -- "$tmp"
        return 0
    fi
    if ! chmod 0644 -- "$tmp" || ! /bin/mv -f -- "$tmp" "$SHELL_RC_FISH"; then
        command rm -f -- "$tmp"
        return 1
    fi
}

# UI 和订阅转换器沿用按需下载。
_ci_provision() (
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    trap 'rc=$?; trap - EXIT; trap "" INT TERM HUP; operation_lock_release || true; exit "$rc"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    operation_lock_acquire || return 1
    . "$CLASHCTL_SRC/scripts/preflight.sh" || return 1
    prepare_zip "$1"
)
