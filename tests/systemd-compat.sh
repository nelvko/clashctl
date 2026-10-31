#!/usr/bin/env bash
# 模拟不支持 --value 的 systemctl；服务文件和调用记录均限制在临时目录。
# shellcheck disable=SC2317  # 服务库间接调用测试替身。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export CLASHCTL_HOME="$WORK_DIR/home" CLASHCTL_SRC="$REPO_DIR" CLASHCTL_KERNEL=mihomo
. "$REPO_DIR/scripts/lib/common.sh"
. "$REPO_DIR/scripts/lib/service.sh"
_service_target() { printf '%s/%s.service\n' "$WORK_DIR" "$service_manager"; }
_service_privileged_marker_exists() { return 1; }
_service_process_snapshot() { [ "$1" = 4242 ] && [ "$2" = "$BIN_KERNEL" ] && [ -n "$3" ]; }
CALLS="$WORK_DIR/calls"
QUERY_RC=0
FRAGMENT_OUTPUT='FragmentPath='
PID_OUTPUT='MainPID=4242'

systemctl() {
    local argument
    printf '%s\n' "$*" >>"$CALLS"
    for argument in "$@"; do
        if [ "$argument" = --value ]; then
            printf "systemctl: unrecognized option '--value'\n" >&2
            return 64
        fi
    done
    if [ "$service_manager" = systemd-user ]; then
        [ "${1:-}" = --user ] || fail 'user query reached the system manager'
        shift
    fi
    case "$*" in
    'show mihomo.service -p FragmentPath') printf '%s\n' "$FRAGMENT_OUTPUT"; return "$QUERY_RC" ;;
    'show mihomo -p MainPID') printf '%s\n' "$PID_OUTPUT"; return "$QUERY_RC" ;;
    daemon-reload) : ;;
    *) fail "unexpected systemctl invocation: $*" ;;
    esac
}

for service_manager in systemd systemd-user; do
    target=$(_service_target)
    : >"$CALLS"
    FRAGMENT_OUTPUT='FragmentPath=/usr/lib/systemd/system/mihomo.service'
    if install_service >"$WORK_DIR/output" 2>&1; then fail "$service_manager replaced a foreign loaded unit"; fi
    grep -Fq '/usr/lib/systemd/system/mihomo.service' "$WORK_DIR/output" || {
        cat "$WORK_DIR/output" >&2
        fail "$service_manager did not identify the loaded foreign unit"
    }
    [ ! -e "$target" ] || fail "$service_manager wrote a unit despite a conflict"

    # 查询失败时不能把空输出当作没有同名服务，也不能用输出中的 PID。
    FRAGMENT_OUTPUT='FragmentPath=' QUERY_RC=1
    if install_service >"$WORK_DIR/output" 2>&1; then fail "$service_manager ignored a failed conflict query"; fi
    [ ! -e "$target" ] || fail "$service_manager wrote a unit after a failed query"
    if service_main_pid >/dev/null; then fail "$service_manager accepted a PID from a failed query"; fi
    QUERY_RC=0
    for FRAGMENT_OUTPUT in '' 'Unknown='; do
        if install_service >"$WORK_DIR/output" 2>&1; then fail "$service_manager accepted a missing property"; fi
        [ ! -e "$target" ] || fail "$service_manager wrote a unit with a missing property"
    done
    if grep -q daemon-reload "$CALLS"; then fail "$service_manager reloaded after a rejected query"; fi

    FRAGMENT_OUTPUT='FragmentPath='
    install_service || fail "$service_manager failed to install with an older systemctl"
    grep -Fqx "ExecStart=$BIN_KERNEL -d $CLASH_RESOURCES_DIR -f $CLASH_CONFIG_RUNTIME" "$target" ||
        fail "$service_manager rendered the wrong service command"
    grep -q daemon-reload "$CALLS" || fail "$service_manager did not reload after installation"
    [ "$(service_main_pid)" = 4242 ] || fail "$service_manager did not parse and validate MainPID"
    for PID_OUTPUT in 'MainPID=' 'MainPID=0' 'MainPID=1' 'MainPID=invalid' 'Unknown=4242'; do
        if service_main_pid >/dev/null; then fail "$service_manager accepted an invalid PID: $PID_OUTPUT"; fi
    done
    PID_OUTPUT='MainPID=4242'
    rm -- "$target"
done
printf 'systemd-compat: ok\n'
