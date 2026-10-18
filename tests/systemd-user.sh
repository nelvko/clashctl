#!/usr/bin/env bash
# 只在临时目录读写，所有服务、日志和提权命令均由替身接管。
# service_log_path、service_pid_path 由被测 detect_service_manager 初始化。
# 各测试使用子 Shell 隔离服务管理器变量。
# shellcheck disable=SC2317,SC2154,SC2030
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

export HOME="$WORK_DIR/user" XDG_CONFIG_HOME="$WORK_DIR/config"
export CLASHCTL_HOME="$WORK_DIR/install" CLASHCTL_SRC="$REPO_DIR" CLASHCTL_KERNEL=mihomo
export INIT_TYPE=systemd-user
mkdir -p -- "$HOME" "$CLASHCTL_HOME/data"
. "$REPO_DIR/scripts/lib/common.sh"
. "$REPO_DIR/scripts/lib/config.sh"
. "$REPO_DIR/scripts/lib/operation-lock.sh"
. "$REPO_DIR/scripts/lib/service-process.sh"
. "$REPO_DIR/scripts/lib/service.sh"

CALLS="$WORK_DIR/calls"
NATIVE_STATE="$WORK_DIR/native-state"
PRIVILEGED_MARKER="$WORK_DIR/privileged.process"
MANAGER_AVAILABLE=1
MANAGER_VERSION='252 (252.39-1)'
VERSION_QUERY_RC=0
FRAGMENT_PATH=''
MAIN_PID=4242
HELPER_FAIL=0
ENABLE_RC=0
: >"$CALLS"
printf 'inactive\n' >"$NATIVE_STATE"

_is_root() { return 1; }
id() {
    [ "$*" = -u ] || fail "unexpected identity query: $*"
    printf '1000\n'
}
_require_base_config() { :; }
_valid_config() { :; }
_stub_yq() {
    case "$*" in
    '-i .tun.enable = false '*) printf 'tun-disabled\n' >"${@: -1}" ;;
    *'.tun.enable == true'*) command grep -qx tun-enabled "${@: -1}" ;;
    *'.tun.enable'*)
        if command grep -qx tun-enabled "${@: -1}"; then printf 'true\n'; else printf 'false\n'; fi
        ;;
    *) fail "unexpected configuration query: $*" ;;
    esac
}
export BIN_YQ=_stub_yq
printf 'tun-disabled\n' >"$CLASH_CONFIG_RUNTIME"

# 缺少 --user 立即失败，避免测试意外操作系统管理器。
systemctl() {
    [ "${1:-}" = --user ] || fail "system manager invoked: systemctl $*"
    printf 'systemctl %s\n' "$*" >>"$CALLS"
    shift
    case "${1:-}" in
    show-environment) [ "$MANAGER_AVAILABLE" -eq 1 ] ;;
    is-active)
        command cat "$NATIVE_STATE"
        [ "$(command cat "$NATIVE_STATE")" = active ] || return 3
        ;;
    show)
        case "$*" in
        'show -p Version --value') printf '%s\n' "$MANAGER_VERSION"; return "$VERSION_QUERY_RC" ;;
        *MainPID*) printf '%s\n' "$MAIN_PID" ;;
        *FragmentPath*) printf '%s\n' "$FRAGMENT_PATH" ;;
        *) fail "unexpected user manager query: $*" ;;
        esac
        ;;
    start) printf 'active\n' >"$NATIVE_STATE" ;;
    stop) printf 'inactive\n' >"$NATIVE_STATE" ;;
    enable)
        if [ "$ENABLE_RC" -ne 0 ]; then
            printf 'user enable command failed\n' >&2
            return "$ENABLE_RC"
        fi
        ;;
    disable | daemon-reload) : ;;
    *) fail "unexpected user manager operation: $*" ;;
    esac
}
journalctl() {
    [ "${1:-}" = --user ] || fail "system journal invoked: journalctl $*"
    printf 'journalctl %s\n' "$*" >>"$CALLS"
    printf 'user journal\n'
}
sudo() {
    if [ "${1:-}" != bash ] || [ "${2:-}" != "$_SERVICE_PROCESS_HELPER_FILE" ]; then
        fail "unexpected privilege request: $*"
    fi
    printf 'sudo %s\n' "$3" >>"$CALLS"
    [ "$HELPER_FAIL" -eq 0 ] || return 1
    case "${3:-}" in
    privileged-start) : >"$PRIVILEGED_MARKER" ;;
    privileged-stop) command rm -f -- "$PRIVILEGED_MARKER" ;;
    *) fail "unexpected privileged helper action: $3" ;;
    esac
}
stty() { :; }
tail() {
    printf 'tail %s\n' "$*" >>"$CALLS"
    case " $* " in *' -f '*) printf 'following helper log\n' ;; *) command tail "$@" ;; esac
}
less() {
    printf 'less %s\n' "$*" >>"$CALLS"
    command cat "$@"
}

# 模拟 root 私有记录的可见性，不创建 /run/clashctl，也不读取宿主记录。
_service_privileged_record_path() { printf '%s\n' "$PRIVILEGED_MARKER"; }
_service_privileged_runtime_is_secure() { [ "$1" = /run/clashctl ]; }
_service_privileged_record_is_secure() { [ "$1" = "$PRIVILEGED_MARKER" ] && [ -e "$1" ]; }
_service_state_path_absent() {
    case "$1" in
    /run/clashctl | "$PRIVILEGED_MARKER") [ ! -e "$PRIVILEGED_MARKER" ] ;;
    *) [ ! -e "$1" ] && [ ! -L "$1" ] ;;
    esac
}

expect_call() {
    command grep -Fqx -- "$1" "$CALLS" || fail "missing call: $1"
}
expect_no_call() {
    if command grep -Fq -- "$1" "$CALLS"; then fail "unexpected call: $1"; fi
}

test_detection_and_paths() (
    # 已保存的选择不依赖当前用户管理器是否可连接，也不受容器识别影响。
    MANAGER_AVAILABLE=0
    service_manager=''
    detect_service_manager || fail 'could not detect the saved user backend'
    [ "$service_manager" = systemd-user ] || fail 'saved user backend was silently downgraded'
    [ "$service_log_path" = "$CLASH_DATA_DIR/mihomo.log" ] || fail 'user helper log is not writable data path'
    [ "$service_pid_path" = "$CLASH_DATA_DIR/mihomo.pid" ] || fail 'user helper PID path is not in data'
    [ "$(_service_target)" = "$XDG_CONFIG_HOME/systemd/user/mihomo.service" ] || fail 'XDG user unit path is wrong'
    unset XDG_CONFIG_HOME
    [ "$(_service_target)" = "$HOME/.config/systemd/user/mihomo.service" ] || fail 'default user unit path is wrong'
    XDG_CONFIG_HOME=''
    [ "$(_service_target)" = "$HOME/.config/systemd/user/mihomo.service" ] || fail 'empty XDG path did not use HOME'

    # 遗留配置中的 systemd 表示系统服务，不能因此接管用户同名服务。
    INIT_TYPE=systemd service_manager=''
    detect_service_manager || fail 'could not detect legacy non-root installation'
    [ "$service_manager" = nohup ] || fail 'legacy non-root backend did not remain nohup'
)

test_availability() (
    : >"$CALLS"
    MANAGER_AVAILABLE=1 service_user_available || fail 'available user manager was rejected'
    MANAGER_VERSION=243 service_user_available || fail 'minimum supported manager version was rejected'
    MANAGER_VERSION='257.4-1' service_user_available || fail 'dotted manager version was rejected'
    # show-environment/show 不依赖 is-system-running 的退出码，degraded 也能用。
    MANAGER_VERSION='252 (252.39-1)' service_user_available || fail 'connected degraded manager was rejected'
    for MANAGER_VERSION in 242 '' unknown; do
        if service_user_available; then fail "unsupported manager version was accepted: $MANAGER_VERSION"; fi
    done
    MANAGER_VERSION=252 VERSION_QUERY_RC=1
    if service_user_available; then fail 'failed version query was accepted'; fi
    VERSION_QUERY_RC=0
    MANAGER_AVAILABLE=0
    if service_user_available; then fail 'unavailable user manager was accepted'; fi
    expect_call 'systemctl --user show-environment'
    expect_call 'systemctl --user show -p Version --value'
    expect_no_call is-system-running
)

test_root_cannot_start_user_backend() (
    detect_service_manager
    : >"$CALLS"
    _is_root() { return 0; }
    _ui_error() { printf '%s\n' "$*" >&2; }
    printf 'tun-enabled\n' >"$CLASH_CONFIG_RUNTIME"
    if service_start >"$WORK_DIR/root-start" 2>&1; then fail 'root started the user backend'; fi
    if service_sudo_start >>"$WORK_DIR/root-start" 2>&1; then fail 'sudo start recursed into the user backend'; fi
    command grep -q '普通用户' "$WORK_DIR/root-start" || fail 'root rejection omitted the correct account'
    expect_no_call 'systemctl --user start'
    expect_no_call sudo
    printf 'tun-disabled\n' >"$CLASH_CONFIG_RUNTIME"
)

test_native_lifecycle_and_queries() (
    detect_service_manager
    : >"$CALLS"
    service_start || fail 'user service did not start'
    service_is_active || fail 'active user unit was not active'
    [ "$(service_state)" = running ] || fail 'active user unit state is wrong'
    service_enable || fail 'user service did not enable'
    service_disable || fail 'user service did not disable'
    _service_process_snapshot() {
        [ "$1" = 4242 ] && [ "$2" = "$BIN_KERNEL" ] && [ -n "$3" ]
    }
    [ "$(service_main_pid)" = 4242 ] || fail 'user service main PID was not validated'
    [ "$(service_log --no-pager -n 4)" = 'user journal' ] || fail 'user log did not use its journal'
    service_follow_log >/dev/null || fail 'user journal follow failed'
    service_stop || fail 'user service did not stop'
    if service_is_active; then fail 'stopped user unit was active'; fi
    [ "$(service_state)" = stopped ] || fail 'stopped user unit state is wrong'
    expect_call 'systemctl --user start mihomo'
    expect_call 'systemctl --user stop mihomo'
    expect_call 'systemctl --user enable --quiet mihomo'
    expect_call 'systemctl --user disable --quiet mihomo'
    expect_call 'systemctl --user show mihomo -p MainPID --value'
    expect_call 'journalctl --user -u mihomo --no-pager -n 4'
    expect_call 'journalctl --user -u mihomo -q -f -n 0'
    expect_no_call sudo
)

test_install_conflict_and_removal() (
    local target
    detect_service_manager
    target=$(_service_target)
    : >"$CALLS"
    FRAGMENT_PATH=/usr/lib/systemd/user/mihomo.service
    if install_service >/dev/null 2>&1; then fail 'installer took over a loaded foreign user unit'; fi
    [ ! -e "$target" ] || fail 'foreign loaded unit caused a local unit to be written'
    expect_call 'systemctl --user show mihomo.service -p FragmentPath --value'
    expect_no_call daemon-reload
    FRAGMENT_PATH=''
    mkdir -p -- "$(dirname -- "$target")"
    printf 'foreign user unit\n' >"$target"
    if install_service >/dev/null 2>&1; then fail 'installer replaced a foreign user unit'; fi
    if uninstall_service >/dev/null 2>&1; then fail 'uninstaller deleted a foreign user unit'; fi
    [ "$(command cat "$target")" = 'foreign user unit' ] || fail 'foreign user unit changed'
    command rm -- "$target"

    install_service || fail 'could not install user unit'
    [ "$(stat -c %a -- "$target")" = 644 ] || fail 'user unit mode is not 0644'
    command grep -Fqx 'WantedBy=default.target' "$target" || fail 'user unit does not use default.target'
    command grep -Fqx "ExecStart=$BIN_KERNEL -d $CLASH_RESOURCES_DIR -f $CLASH_CONFIG_RUNTIME" "$target" ||
        fail 'user unit has the wrong executable or configuration'
    if command grep -Eq '^(AmbientCapabilities|CapabilityBoundingSet|User|Group)=|multi-user.target|placeholder_' "$target"; then
        fail 'user template retained system-service directives or placeholders'
    fi
    expect_call 'systemctl --user daemon-reload'
    expect_no_call 'systemctl --user enable'
    service_start || fail 'installed user service could not start'
    service_enable
    uninstall_service || fail 'could not uninstall user unit'
    [ ! -e "$target" ] || fail 'uninstall left the user unit behind'
    [ "$(command cat "$NATIVE_STATE")" = inactive ] || fail 'uninstall did not stop the user unit'
    expect_call 'systemctl --user disable --quiet mihomo'
)

test_enable_failure_reporting() (
    local rc=0
    detect_service_manager
    ENABLE_RC=42
    service_enable >"$WORK_DIR/enable-stdout" 2>"$WORK_DIR/enable-stderr" || rc=$?
    [ "$rc" -eq 42 ] || fail 'user enable failure lost its original exit status'
    [ ! -s "$WORK_DIR/enable-stdout" ] || fail 'failed enable emitted a success message'
    command grep -Fq 'user enable command failed' "$WORK_DIR/enable-stderr" || fail 'enable failure hid the command error'
    command grep -Fq '登录自启设置失败' "$WORK_DIR/enable-stderr" || fail 'user enable failure omitted login startup context'

    service_manager=systemd
    systemctl() {
        [ "$*" = 'enable --quiet mihomo' ] || fail "unexpected system enable operation: $*"
        printf 'system enable command failed\n' >&2
        return 43
    }
    rc=0
    service_enable >"$WORK_DIR/enable-stdout" 2>"$WORK_DIR/enable-stderr" || rc=$?
    [ "$rc" -eq 43 ] || fail 'system enable failure lost its original exit status'
    [ ! -s "$WORK_DIR/enable-stdout" ] || fail 'failed system enable emitted a success message'
    command grep -Fq 'system enable command failed' "$WORK_DIR/enable-stderr" || fail 'system enable failure hid the command error'
    command grep -Fq '开机自启设置失败' "$WORK_DIR/enable-stderr" || fail 'system enable failure omitted boot startup context'

    service_manager=runit
    _service_target() { printf '%s/runit-service/run\n' "$WORK_DIR"; }
    _service_runit_enable_link() { printf '%s/runit-conflict\n' "$WORK_DIR"; }
    mkdir -- "$WORK_DIR/runit-conflict"
    rc=0
    service_start >"$WORK_DIR/enable-stdout" 2>"$WORK_DIR/enable-stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail 'runit startup ignored a conflicting enable path'
    command grep -Fq '开机自启设置失败' "$WORK_DIR/enable-stderr" || fail 'runit early enable failure omitted boot startup context'
    [ -d "$WORK_DIR/runit-conflict" ] || fail 'runit enable failure changed the conflicting path'
)

test_privileged_tun_lifecycle() (
    detect_service_manager
    : >"$CALLS"
    printf 'tun-enabled\n' >"$CLASH_CONFIG_RUNTIME"
    service_start || fail 'TUN start did not use the privileged helper'
    [ -e "$PRIVILEGED_MARKER" ] || fail 'TUN helper was not started'
    [ "$(command cat "$NATIVE_STATE")" = inactive ] || fail 'TUN helper competed with a running user unit'
    expect_call 'systemctl --user stop mihomo'
    expect_call 'sudo privileged-start'
    expect_no_call 'systemctl --user start'

    : >"$CALLS"
    service_start || fail 'repeated TUN start was not idempotent'
    service_is_active || fail 'TUN helper was not reported active'
    [ "$(service_state)" = running ] || fail 'TUN helper was reported stopped with inactive user unit'
    # 私有记录不可读时，不能冒认用户 unit 的旧 PID 为 TUN 内核 PID。
    _service_process_snapshot() { return 0; }
    if service_main_pid >/dev/null; then fail 'TUN helper exposed an unverified user unit PID'; fi
    expect_no_call sudo
    expect_no_call 'systemctl --user start'
    expect_no_call MainPID

    printf 'privileged kernel log\n' >"$service_log_path"
    [ "$(service_log)" = 'privileged kernel log' ] || fail 'TUN log did not read the helper log'
    service_follow_log >/dev/null || fail 'TUN log follow failed'
    expect_call "less $service_log_path"
    expect_call "tail -f -n 0 $service_log_path"
    expect_no_call journalctl

    : >"$CALLS"
    HELPER_FAIL=1
    if service_stop_checked >/dev/null 2>&1; then fail 'failed TUN helper stop was reported successful'; fi
    [ -e "$PRIVILEGED_MARKER" ] || fail 'failed stop removed the privileged marker'
    HELPER_FAIL=0
    service_stop_checked || fail 'could not stop the privileged TUN helper'
    [ ! -e "$PRIVILEGED_MARKER" ] || fail 'stop left the privileged TUN helper running'
    expect_call 'systemctl --user stop mihomo'
    expect_call 'sudo privileged-stop'
    [ "$(service_state)" = stopped ] || fail 'stopped TUN helper still reported running'
    expect_no_call privileged-start
)

test_disable_tun_after_helper_exit() (
    . "$REPO_DIR/scripts/cmd/tun.sh"
    detect_service_manager
    : >"$CALLS"
    command rm -f -- "$PRIVILEGED_MARKER"
    printf 'inactive\n' >"$NATIVE_STATE"
    printf 'tun-enabled\n' >"$CLASH_CONFIG_RUNTIME"
    printf 'tun-enabled\n' >"$CLASH_CONFIG_MIXIN"
    tunstatus() { return 1; }
    _merge_config() { command cp -- "$CLASH_CONFIG_MIXIN" "$CLASH_CONFIG_RUNTIME"; }
    _okcat() { printf '%s\n' "$*"; }
    tunoff >"$WORK_DIR/tunoff-output" || fail 'could not disable TUN after helper exit'
    command grep -qx tun-disabled "$CLASH_CONFIG_MIXIN" || fail 'tunoff left TUN enabled in mixin'
    command grep -qx tun-disabled "$CLASH_CONFIG_RUNTIME" || fail 'tunoff left TUN enabled in runtime'
    [ "$(command cat "$NATIVE_STATE")" = active ] || fail 'tunoff did not start the ordinary user unit'
    expect_call 'systemctl --user start mihomo'
    expect_no_call privileged-start
    expect_no_call sudo
)

test_nohup_preserves_tun_on_restart() (
    service_manager='nohup'
    service_log_path="$CLASH_DATA_DIR/mihomo.log"
    service_pid_path="$CLASH_DATA_DIR/mihomo.pid"
    : >"$CALLS"
    printf 'tun-enabled\n' >"$CLASH_CONFIG_RUNTIME"
    command rm -f -- "$PRIVILEGED_MARKER"
    service_start || fail 'nohup did not restore TUN after switching from user service'
    [ -e "$PRIVILEGED_MARKER" ] || fail 'nohup started without a privileged TUN helper'
    expect_call 'sudo privileged-start'
    expect_no_call systemctl
    : >"$CALLS"
    service_start || fail 'repeated nohup TUN start failed'
    expect_no_call sudo
    service_stop_checked || fail 'could not stop the nohup TUN helper'
    [ ! -e "$PRIVILEGED_MARKER" ] || fail 'nohup stop left the TUN helper behind'
    service_start || fail 'nohup TUN did not restart after stop'
    [ -e "$PRIVILEGED_MARKER" ] || fail 'nohup restart lost privileged mode'
    service_stop_checked || fail 'could not clean up restarted nohup helper'
    expect_no_call systemctl
    printf 'tun-disabled\n' >"$CLASH_CONFIG_RUNTIME"
)

test_detection_and_paths
test_availability
test_root_cannot_start_user_backend
test_native_lifecycle_and_queries
test_install_conflict_and_removal
test_enable_failure_reporting
test_privileged_tun_lifecycle
test_disable_tun_after_helper_exit
test_nohup_preserves_tun_on_restart
printf 'systemd-user: ok\n'
