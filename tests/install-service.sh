#!/usr/bin/env bash
# 服务方式选择只做能力探测；安装入口必须保留显式参数供初始化使用。
# shellcheck disable=SC2317  # 安装器间接调用测试替身。
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"
export CI=1
ROOT_USER=0 USER_MANAGER_AVAILABLE=1
_is_root() { [ "$ROOT_USER" -eq 1 ]; }
service_user_available() { [ "$USER_MANAGER_AVAILABLE" -eq 1 ]; }
_is_tun_enabled() { return 1; }
_install_ui_error() { printf '%s\n' "$*" >&2; }
_install_ui_info() { printf '%s\n' "$*" >&2; }
_install_ui_warn() { printf '%s\n' "$*" >&2; }
_ui_detail() { printf '%s\n' "$*" >&2; }

# 选择阶段不应注册服务、启动进程或开启 linger。
systemctl() { fail "selection invoked systemctl: $*"; }
loginctl() { fail "selection invoked loginctl: $*"; }
sudo() { fail 'selection requested sudo'; }
install_service() { fail 'selection registered a service'; }
uninstall_service() { fail 'selection removed a service'; }
service_start() { fail 'selection started a process'; }
service_stop() { fail 'selection stopped a process'; }

assert_selection() {
    local requested=$1 saved=$2 detected=$3 expected=$4 label=$5
    INIT_TYPE=$saved service_manager=$detected _INSTALL_SELECTED_SERVICE=''
    _install_select_service "$requested" "$saved" >"$WORK_DIR/selection.out" 2>&1 || {
        cat "$WORK_DIR/selection.out" >&2
        fail "$label: selection failed"
    }
    [ "$_INSTALL_SELECTED_SERVICE" = "$expected" ] ||
        fail "$label: expected $expected, got $_INSTALL_SELECTED_SERVICE"
    [ "$service_manager" = "$detected" ] || fail "$label: selection changed the running backend"
    [ "$INIT_TYPE" = "$saved" ] || fail "$label: selection changed the saved backend"
}

assert_selection auto '' nohup systemd-user 'new regular user with user manager'
USER_MANAGER_AVAILABLE=0 assert_selection auto '' nohup nohup 'new regular user without user manager'
assert_selection nohup '' nohup nohup 'explicit nohup with user manager'
assert_selection systemd-user '' nohup systemd-user 'explicit user service'
assert_selection auto nohup nohup nohup 'existing nohup is preserved'
assert_selection auto systemd-user systemd-user systemd-user 'existing user service is preserved'
USER_MANAGER_AVAILABLE=0 assert_selection auto systemd-user systemd-user systemd-user \
    'existing user service is retained while manager is unavailable'
assert_selection systemd-user nohup nohup systemd-user 'explicit switch to user service'
assert_selection nohup systemd-user systemd-user nohup 'explicit switch to nohup'
ROOT_USER=1 assert_selection auto '' systemd systemd 'root keeps detected system service'
ROOT_USER=1 assert_selection nohup '' systemd nohup 'root can explicitly select nohup'

for saved in '' nohup systemd-user; do
    (
        USER_MANAGER_AVAILABLE=0 INIT_TYPE=$saved service_manager=${saved:-nohup}
        if _install_select_service systemd-user >"$WORK_DIR/unavailable.out" 2>&1; then
            fail 'explicit unavailable user service was accepted'
        fi
        grep -q 'systemd' "$WORK_DIR/unavailable.out" || fail 'unavailable manager was not diagnosed'
    )
done
# root 约束由公开 main 校验，内部选择器只处理已验证的参数。
(
    id() { [ "$*" != -u ] || { printf '0\n'; return; }; command id "$@"; }
    if main --service systemd-user >"$WORK_DIR/root.out" 2>&1; then
        fail 'root was allowed to install a user service'
    fi
    grep -q '普通用户' "$WORK_DIR/root.out" || fail 'root error omitted user scope'
)

# 使用真正的控制终端验证 /dev/tty 输入；每个子进程最多等待 5 秒。
python3 -B - "$REPO_DIR/install.sh" "$TEST_DIR/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from terminal import run
script = '''set -eu
. "$1"
unset CI
service_manager=nohup INIT_TYPE=''
_is_root() { return 1; }
service_user_available() { return 0; }
_install_ui_warn() { printf '%s\\n' "$*" >&2; }
systemctl() { exit 95; }
loginctl() { exit 95; }
sudo() { exit 95; }
_install_select_service auto ''
printf '\\nSELECTED:%s\\n' "$_INSTALL_SELECTED_SERVICE"
'''
for replies, expected in ((b"2\n", b"nohup"), (b"invalid\n\n", b"systemd-user")):
    rc, output = run(["bash", "-c", script, "_", sys.argv[1]],
                     replies=[(b"[1/2", replies)], timeout=5)
    assert rc == 0 and b"SELECTED:" + expected in output, (rc, output)
    if replies.startswith(b"invalid"):
        assert "请输入 1 或 2".encode() in output, output
PY

# 对入口使用未完成的本地安装替身；不下载、不操作宿主服务与 Shell 配置。
(
    id() { [ "$*" != -u ] || { printf '1000\n'; return 0; }; command id "$@"; }
    installed="$WORK_DIR/installed"
    mkdir -p "$installed/scripts/lib"
    cp "$REPO_DIR/scripts/lib/operation-lock.sh" "$installed/scripts/lib/"
    printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\n' >"$installed/.env"
    _install_existing_kind() { printf 'current\n'; }
    _install_lock() { :; }
    _install_method() { printf 'archive\n'; }
    _install_intro() { :; }
    _install_refresh_current() { :; }
    _install_complete() { :; }
    _install_main_cleanup() { :; }
    _install_initialize() { printf '%s\n' "${7-}" >"$WORK_DIR/parameter-result"; }

    for value in auto systemd-user nohup; do
        for form in separate equals; do
            : >"$installed/.clashctl-incomplete"
            args=("--service=$value")
            [ "$form" != separate ] || args=(--service "$value")
            main --home "$installed" "${args[@]}" >"$WORK_DIR/parameter.out" 2>&1 || {
                cat "$WORK_DIR/parameter.out" >&2
                fail "service parameter rejected: $value ($form)"
            }
            [ "$(cat "$WORK_DIR/parameter-result")" = "$value" ] ||
                fail "service parameter was not forwarded: $value ($form)"
        done
    done
    : >"$installed/.clashctl-incomplete"
    main --home "$installed" >"$WORK_DIR/default.out" 2>&1 || fail 'default service parameter failed'
    [ "$(cat "$WORK_DIR/parameter-result")" = auto ] || fail 'default service request is not auto'

    for invalid_option in '--service' '--service=' '--service=invalid' '--service systemd'; do
        rm -f "$WORK_DIR/parameter-result"
        # shellcheck disable=SC2086  # 故意验证缺失值与分离值参数。
        if main --home "$installed" $invalid_option >"$WORK_DIR/invalid.out" 2>&1; then
            fail "invalid service parameter was accepted: $invalid_option"
        fi
        [ ! -e "$WORK_DIR/parameter-result" ] || fail 'invalid parameter reached initialization'
        grep -q -- '--service' "$WORK_DIR/invalid.out" || fail 'invalid parameter omitted option name'
    done
    main --help >"$WORK_DIR/help.out" 2>&1
    grep -q -- '--service' "$WORK_DIR/help.out" || fail 'install help omitted service selection'
)

# 后端切换失败后，实际 EXIT 清理必须恢复配置、进程和原有自启状态。
run_failed_switch() {
    local old=$1 selected=$2 active=$3 enabled=$4 privileged=$5
    # shellcheck disable=SC2034  # 安装器及 EXIT 清理通过 Bash 动态作用域读取这些状态。
    local service_manager=$old INIT_TYPE=$old CLASHCTL_KERNEL=mihomo
    # shellcheck disable=SC2034
    local service_switch_pending=false service_previous_manager='' service_previous_init='' service_selected_manager=''
    # shellcheck disable=SC2034
    local service_previous_active=false service_previous_enabled=false service_previous_privileged=false
    # shellcheck disable=SC2034
    local stage=''
    _install_use_service() { INIT_TYPE=$1; service_manager=$1; }
    _service_target() { printf '%s/%s.unit\n' "$CASE_DIR" "$service_manager"; }
    _service_check_conflict() { [ "${CONFLICT_TARGET:-0}" -eq 0 ] || [ "$service_manager" != "$selected" ]; }
    _service_privileged_marker_exists() { [ -e "$CASE_DIR/$service_manager.privileged" ]; }
    service_state() { [ ! -e "$CASE_DIR/$service_manager.active" ] || { printf 'running\n'; return 0; }; printf 'stopped\n'; }
    _set_env() { printf '%s=%s\n' "$1" "$2" >"$CASE_DIR/.env"; }
    install_service() {
        printf 'install:%s\n' "$service_manager" >>"$CASE_DIR/operations"
        if [ "$service_manager" = "$selected" ] && [ "${MISSING_TARGET:-0}" -eq 1 ]; then
            return 1
        fi
        touch "$CASE_DIR/$service_manager.unit"
        [ "$service_manager" != "$selected" ] || return 1
        touch "$CASE_DIR/$service_manager.installed"
    }
    uninstall_service() {
        printf 'remove:%s\n' "$service_manager" >>"$CASE_DIR/operations"
        if [ "$service_manager" = "$selected" ] && [ "${MISSING_TARGET:-0}" -eq 1 ] &&
            [ ! -e "$CASE_DIR/$service_manager.unit" ]; then
            return 81
        fi
        rm -f "$CASE_DIR/$service_manager."{installed,active,enabled,privileged,unit}
    }
    service_stop_checked() {
        printf 'stop-checked:%s\n' "$service_manager" >>"$CASE_DIR/operations"
        rm -f "$CASE_DIR/$service_manager.active"
    }
    service_start() { touch "$CASE_DIR/$service_manager.active"; }
    service_enable() { touch "$CASE_DIR/$service_manager.enabled"; }
    service_sudo_start() { touch "$CASE_DIR/$service_manager.active" "$CASE_DIR/$service_manager.privileged"; }
    systemctl() {
        if [ "$*" = '--user daemon-reload' ]; then
            printf 'daemon-reload\n' >>"$CASE_DIR/operations"
            return 0
        fi
        [ "$*" = '--user is-enabled --quiet mihomo' ] || fail "unexpected transaction systemctl: $*"
        [ -e "$CASE_DIR/systemd-user.enabled" ]
    }
    printf 'INIT_TYPE=%s\n' "$old" >"$CASE_DIR/.env"
    touch "$CASE_DIR/$old.installed" "$CASE_DIR/$old.unit"
    [ "$active" -ne 1 ] || touch "$CASE_DIR/$old.active"
    [ "$enabled" -ne 1 ] || touch "$CASE_DIR/$old.enabled"
    [ "$privileged" -ne 1 ] || touch "$CASE_DIR/$old.privileged"
    trap _install_main_cleanup EXIT
    if _install_apply_service "$selected" "$old"; then
        fail 'failed service registration was accepted'
    fi
    exit 17
}

for scenario in 'nohup systemd-user 1 0 0' 'systemd-user nohup 1 1 0' \
    'nohup systemd-user 0 0 0' 'systemd-user nohup 0 0 0' 'nohup systemd-user 1 0 1'; do
    read -r old selected active enabled privileged <<<"$scenario"
    CASE_DIR="$WORK_DIR/switch-$old-$active-$enabled-$privileged"
    mkdir "$CASE_DIR"
    rc=0
    (run_failed_switch "$old" "$selected" "$active" "$enabled" "$privileged") \
        >"$CASE_DIR/output" 2>&1 || rc=$?
    [ "$rc" -eq 17 ] || { cat "$CASE_DIR/output" >&2; fail 'cleanup changed the installation failure status'; }
    service_label=$selected
    [ "$service_label" != systemd-user ] || service_label='systemd --user'
    grep -Fq "$service_label 服务注册失败" "$CASE_DIR/output" || fail 'registration failure omitted its failed operation'
    grep -Fqx "INIT_TYPE=$old" "$CASE_DIR/.env" || fail 'cleanup did not restore saved service type'
    [ -e "$CASE_DIR/$old.installed" ] || fail 'cleanup did not restore the original service definition'
    [ ! -e "$CASE_DIR/$selected.installed" ] || fail 'cleanup retained the failed new service definition'
    for attribute in active enabled privileged; do
        expected=${!attribute}
        if [ "$expected" -eq 1 ]; then
            [ -e "$CASE_DIR/$old.$attribute" ] || fail "cleanup did not restore original $attribute state"
        else
            [ ! -e "$CASE_DIR/$old.$attribute" ] || fail "cleanup changed original $attribute state"
        fi
    done
done

# 新用户单元尚未写入时，disable 不存在单元的错误不能妨碍恢复旧 nohup。
CASE_DIR="$WORK_DIR/missing-unit"
mkdir "$CASE_DIR"
rc=0
(MISSING_TARGET=1 run_failed_switch nohup systemd-user 1 0 0) >"$CASE_DIR/output" 2>&1 || rc=$?
[ "$rc" -eq 17 ] || { cat "$CASE_DIR/output" >&2; fail 'missing new unit blocked rollback'; }
grep -Fq 'systemd --user 服务注册失败' "$CASE_DIR/output" || fail 'missing unit omitted registration failure'
[ -e "$CASE_DIR/nohup.active" ] || fail 'missing new unit prevented the old process from restarting'
grep -Fqx 'INIT_TYPE=nohup' "$CASE_DIR/.env" || fail 'missing new unit prevented saved backend recovery'
grep -Fqx 'stop-checked:systemd-user' "$CASE_DIR/operations" || fail 'missing unit skipped safe process cleanup'
grep -Fqx 'daemon-reload' "$CASE_DIR/operations" || fail 'missing unit skipped daemon reload'
! grep -Fqx 'remove:systemd-user' "$CASE_DIR/operations" || fail 'rollback tried to disable the nonexistent new unit'

# 冲突探测失败时，应在停掉旧进程和改写配置前退出。
CASE_DIR="$WORK_DIR/conflict"
mkdir "$CASE_DIR"
rc=0
(CONFLICT_TARGET=1 run_failed_switch nohup systemd-user 1 0 0) >"$CASE_DIR/output" 2>&1 || rc=$?
[ "$rc" -eq 17 ] || fail 'conflict failure did not reach clean exit'
[ -e "$CASE_DIR/nohup.active" ] || fail 'new service conflict stopped the original process'
grep -Fqx 'INIT_TYPE=nohup' "$CASE_DIR/.env" || fail 'new service conflict changed the saved backend'
[ ! -e "$CASE_DIR/operations" ] || fail 'new service conflict changed service registration'
! grep -q '服务注册失败' "$CASE_DIR/output" || fail 'service conflict was mislabeled as registration failure'

# 实际初始化读取预检与命令加载器，验证选择结果能跨重载持久化。
# 所有服务、下载和 Shell 写入仍由临时目录内的替身处理。
cat >"$WORK_DIR/preflight.fixture" <<'FIXTURE'
INIT_TYPE='' service_manager=''
[ ! -f "$CLASHCTL_HOME/.env" ] || . "$CLASHCTL_HOME/.env"
FIXTURE
cat "$TEST_DIR/lib/preflight.fixture" >>"$WORK_DIR/preflight.fixture"
cat >>"$WORK_DIR/preflight.fixture" <<'FIXTURE'
CLASH_CONFIG_RUNTIME="$CLASH_DATA_DIR/runtime.yaml"
CLASHCTL_DOWNLOAD_TIMEOUT=${CLASHCTL_DOWNLOAD_TIMEOUT:-60}
bin_kernel_path() { printf '%s/bin/mihomo\n' "$CLASHCTL_HOME"; }
_is_root() { return 1; }
service_user_available() { [ "$USER_MANAGER_AVAILABLE" -eq 1 ]; }
detect_service_manager() {
    [ -z "$service_manager" ] || return 0
    INIT_TYPE=${INIT_TYPE:-nohup}
    service_manager=$INIT_TYPE
}
_service_privileged_marker_exists() { return 1; }
operation_lock_acquire() { :; }
prepare_zip() { :; }
_set_env() {
    sed -i "/^$1=/d" "$CLASHCTL_HOME/.env"
    printf '%s=%q\n' "$1" "$2" >>"$CLASHCTL_HOME/.env"
}
install_service() {
    touch "$CLASH_DATA_DIR/registered-$service_manager"
    printf 'register:%s\n' "$service_manager" >>"$CLASH_DATA_DIR/operations"
}
uninstall_service() {
    rm -f "$CLASH_DATA_DIR/registered-$service_manager" \
        "$CLASH_DATA_DIR/active-$service_manager" "$CLASH_DATA_DIR/enabled-$service_manager"
    printf 'remove:%s\n' "$service_manager" >>"$CLASH_DATA_DIR/operations"
}
service_is_active() { [ -f "$CLASH_DATA_DIR/active-$service_manager" ]; }
service_state() { if service_is_active; then printf 'running\n'; else printf 'stopped\n'; fi; }
service_start() {
    touch "$CLASH_DATA_DIR/active-$service_manager"
    printf 'start:%s\n' "$service_manager" >>"$CLASH_DATA_DIR/operations"
}
service_enable() { [ "$service_manager" = nohup ] || touch "$CLASH_DATA_DIR/enabled-$service_manager"; }
_is_tun_enabled() { [ "${FIXTURE_TUN:-0}" -eq 1 ]; }
systemctl() {
    [ "$*" = '--user is-enabled --quiet mihomo' ] || return 1
    [ -f "$CLASH_DATA_DIR/enabled-systemd-user" ]
}
clashstart() { service_is_active && return 0; service_start && service_enable; }
clashsub() { printf 'configured\n' >"$CLASH_CONFIG_BASE"; service_start; }
apply_rc() { touch "$CLASH_DATA_DIR/shell-ready"; }
detect_rc() { SHELL_RC_BASH='' SHELL_RC_ZSH='' SHELL_RC_FISH=''; }
_install_ui_step() { :; }
_install_ui_ok() { printf '%s\n' "$*"; }
FIXTURE

for scenario in 'new-auto auto none 1 0 systemd-user' 'new-fallback auto none 0 0 nohup' \
    'new-user-sub systemd-user none 1 0 systemd-user yes 0' \
    'new-nohup-sub nohup none 1 0 nohup yes 0' \
    'new-user-tun systemd-user none 1 0 systemd-user no 1' \
    'keep-nohup auto nohup 1 1 nohup' 'switch-user systemd-user nohup 1 1 systemd-user' \
    'switch-nohup nohup systemd-user 1 1 nohup'; do
    read -r case_name requested saved available configured expected subscribing tun <<<"$scenario"
    subscribing=${subscribing:-no} tun=${tun:-0}
    initialize_home="$WORK_DIR/$case_name"
    mkdir -p "$initialize_home/scripts/cmd" "$initialize_home/resources" "$initialize_home/data"
    cp "$WORK_DIR/preflight.fixture" "$initialize_home/scripts/preflight.sh"
    cp "$REPO_DIR/.env.example" "$initialize_home/"
    cp "$REPO_DIR/resources/"{mixin.yaml.example,profiles.yaml} "$initialize_home/resources/"
    cat >"$initialize_home/scripts/cmd/clashctl.sh" <<'LOADER'
. "$CLASHCTL_HOME/.env"
service_manager=''
LOADER
    if [ "$saved" != none ]; then
        printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=%s\n' "$saved" >"$initialize_home/.env"
        touch "$initialize_home/data/registered-$saved" "$initialize_home/data/active-$saved"
        [ "$saved" != systemd-user ] || touch "$initialize_home/data/enabled-$saved"
    fi
    [ "$configured" -ne 1 ] || printf 'configured\n' >"$initialize_home/data/config.yaml"
    (
        export CLASHCTL_HOME="$initialize_home"
        # shellcheck disable=SC2034  # 安装器读取锁库路径；fixture 禁用实际操作锁。
        CLASHCTL_INSTALL_SOURCE='' USER_MANAGER_AVAILABLE=$available FIXTURE_TUN=$tun
        subscription_arg=''
        [ "$subscribing" != yes ] || subscription_arg=https://example.invalid/install-subscription
        _install_initialize mihomo master '' '' '' "$subscription_arg" "$requested" || exit 1
        _install_next_step bash >"$initialize_home/footer" 2>&1
    ) >"$initialize_home/output" 2>&1 || {
        cat "$initialize_home/output" >&2
        fail "actual initialization failed: $case_name"
    }
    bash -c '. "$1"; [ "$INIT_TYPE" = "$2" ]' _ "$initialize_home/.env" "$expected" ||
        fail "initialization did not persist selected backend: $case_name"
    [ -e "$initialize_home/data/registered-$expected" ] || fail "initialization did not register backend: $case_name"
    [ -e "$initialize_home/data/shell-ready" ] || fail "initialization did not finish Shell setup: $case_name"
    [ -e "$initialize_home/data/active-$expected" ] || fail "initialization did not start the kernel: $case_name"
    if [ "$expected" = nohup ]; then
        [ ! -e "$initialize_home/data/enabled-$expected" ] || fail 'nohup installation enabled a service'
        ! grep -q '已设置登录自启\|已设置开机自启' "$initialize_home/output" || fail 'nohup installation claimed autostart'
    else
        [ -e "$initialize_home/data/enabled-$expected" ] || fail "initialization did not enable autostart: $case_name"
    fi
    if [ "$expected" = systemd-user ] && [ "$tun" -eq 0 ]; then
        grep -Fq '已注册 systemd --user 服务' "$initialize_home/output" || fail 'user installation omitted registration result'
        grep -Fq '已设置登录自启' "$initialize_home/output" || fail 'user installation omitted login startup result'
        ! grep -q 'loginctl enable-linger' "$initialize_home/output" || fail 'linger command appeared before completion'
        [ "$(grep -c 'sudo loginctl enable-linger' "$initialize_home/footer")" -eq 1 ] || fail 'footer omitted or repeated linger command'
        grep -q '按需设置（需管理员权限）:' "$initialize_home/footer" || fail 'linger omitted administrator context'
    else
        ! grep -q 'loginctl enable-linger' "$initialize_home/footer" || fail 'footer suggested unavailable user autostart'
        ! grep -q '已设置登录自启' "$initialize_home/output" || fail 'TUN installation claimed login autostart'
    fi
    if [ "$configured" -eq 0 ]; then
        [ "$(grep -c "^start:$expected$" "$initialize_home/data/operations")" -eq 1 ] ||
            fail 'new installation did not start the kernel exactly once'
        if [ "$subscribing" = no ]; then
            [ ! -s "$initialize_home/data/config.yaml" ] || fail 'direct installation created a fake subscription'
            grep -Fq 'mihomo 已启动（直连）' "$initialize_home/output" || fail 'direct installation omitted mode explanation'
            grep -q '按需添加订阅:' "$initialize_home/footer" || fail 'direct installation omitted optional subscription'
        else
            ! grep -q '按需添加订阅:' "$initialize_home/footer" || fail 'configured installation suggested adding a subscription'
        fi
    elif [ "$saved" = "$expected" ]; then
        ! grep -Eq '^(start|remove):' "$initialize_home/data/operations" || fail 'unchanged installation restarted its service'
        grep -Fq 'mihomo 已在运行' "$initialize_home/output" || fail 'unchanged installation did not preserve its running status'
        ! grep -Fq 'mihomo 已启动' "$initialize_home/output" || fail 'unchanged installation claimed a new startup'
    else
        [ "$(grep -c "^start:$expected$" "$initialize_home/data/operations")" -eq 1 ] ||
            fail "service switch did not start the new backend exactly once: $case_name"
        [ ! -e "$initialize_home/data/active-$saved" ] || fail 'service switch retained the old process'
        [ ! -e "$initialize_home/data/registered-$saved" ] || fail 'service switch retained the old registration'
    fi
done

python3 - "$WORK_DIR" <<'PY'
from pathlib import Path
import sys
for footer in Path(sys.argv[1]).glob('*/footer'):
    text = footer.read_text()
    commands = ['在当前终端执行', 'clashctl on', 'clashctl ui']
    if '按需添加订阅:' in text:
        commands += ['按需添加订阅:', 'clashctl sub add --use']
    if '按需设置（需管理员权限）:' in text:
        commands += ['按需设置（需管理员权限）:', 'sudo loginctl enable-linger']
    positions = [text.index(command) for command in commands]
    assert positions == sorted(positions), f'footer sections overlap: {footer.parent.name}'
PY

printf 'install-service: ok\n'
