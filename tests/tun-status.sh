#!/usr/bin/env bash
# TUN 状态归属与同名网卡冲突；不调用宿主网络或服务。
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
export CLASHCTL_HOME="$WORK_DIR/home"
make_fake_home "$CLASHCTL_HOME"
printf 'false\n' >"$CLASHCTL_HOME/data/runtime.yaml"
cat >"$CLASHCTL_HOME/bin/yq" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*'.tun.device'*) printf 'ct-test\n' ;;
*'.tun.enable == true'*) grep -qx true "${@: -1}" ;;
*) exit 1 ;;
esac
EOF
chmod +x "$CLASHCTL_HOME/bin/yq"
cat >"$CLASHCTL_HOME/scripts/lib/zz-test.sh" <<'EOF'
_operation_lock_base() { printf '%s\n' "$CLASHCTL_HOME/data"; }
_require_base_config() { :; }
_is_root() { [ ! -f "$CLASHCTL_HOME/regular-user" ]; }
service_is_active() { [ -f "$CLASHCTL_HOME/running" ]; }
service_main_pid() { [ ! -f "$CLASHCTL_HOME/no-main-pid" ] && service_is_active && printf '999\n'; }
_tun_api_state() {
    [ ! -f "$CLASHCTL_HOME/api-unavailable" ] || return 1
    if [ -f "$CLASHCTL_HOME/owned" ]; then printf 'true\tct-test\n'; else printf 'false\tct-test\n'; fi
}
_tun_pid_owns_device() {
    _is_root || return 2
    [ -f "$CLASHCTL_HOME/owned" ] && [ ! -f "$CLASHCTL_HOME/foreign-owner" ]
}
ip() {
    [ "$1" != -o ] || shift
    [ "$1 $2 $3 $4" = 'link show dev ct-test' ] || return 1
    [ -f "$CLASHCTL_HOME/device" ] || return 1
    if [ -f "$CLASHCTL_HOME/link-down" ]; then
        printf '7: ct-test: <POINTOPOINT> state DOWN\n'
    elif [ -f "$CLASHCTL_HOME/no-carrier" ]; then
        printf '7: ct-test: <NO-CARRIER,POINTOPOINT,UP> state DOWN\n'
    else
        printf '7: ct-test: <POINTOPOINT,UP,LOWER_UP> state UNKNOWN\n'
    fi
}
# 外部网卡冲突时应在修改配置和停止服务之前返回。
service_stop() { printf 'stop\n' >>"$CLASHCTL_HOME/calls"; return 1; }
_merge_config() { printf 'merge\n' >>"$CLASHCTL_HOME/calls"; return 1; }
service_sudo_start() { printf 'start\n' >>"$CLASHCTL_HOME/calls"; return 1; }
EOF
# shellcheck source=/dev/null
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
expect_off() {
    local rc=0
    clashctl tun >"$WORK_DIR/output" 2>&1 || rc=$?
    [ "$rc" -eq 1 ] && grep -q 'Tun 状态：关闭' "$WORK_DIR/output" || fail "$1"
}

touch "$CLASHCTL_HOME/device"
expect_off 'stopped kernel accepted a foreign persistent interface'
clashctl tun on >"$WORK_DIR/output" 2>&1 && fail 'foreign interface enabled TUN'
grep -q 'Tun 网卡 ct-test 已存在' "$WORK_DIR/output" || fail 'foreign interface conflict was not reported'
[ ! -e "$CLASHCTL_HOME/calls" ] || fail 'foreign interface caused configuration or service changes'
touch "$CLASHCTL_HOME/running"
expect_off 'disabled running kernel accepted a foreign interface'
touch "$CLASHCTL_HOME/owned" "$CLASHCTL_HOME/foreign-owner"
expect_off 'kernel API overrode conflicting device ownership'
rm -- "$CLASHCTL_HOME/foreign-owner"
clashctl tun >/dev/null || fail 'owned interface was not active'
touch "$CLASHCTL_HOME/link-down"
expect_off 'DOWN interface was active'
rm -- "$CLASHCTL_HOME/link-down"
touch "$CLASHCTL_HOME/no-main-pid"
expect_off 'root accepted an interface without a verified process'
rm -- "$CLASHCTL_HOME/no-main-pid"
touch "$CLASHCTL_HOME/regular-user"
clashctl tun >/dev/null || fail 'unprivileged status did not use the kernel API'
touch "$CLASHCTL_HOME/no-carrier"
expect_off 'unprivileged status accepted an interface without carrier'
rm -- "$CLASHCTL_HOME/no-carrier"
touch "$CLASHCTL_HOME/api-unavailable"
expect_off 'unprivileged status accepted unavailable ownership and API'
rm -- "$CLASHCTL_HOME/regular-user"
printf 'true\n' >"$CLASH_CONFIG_RUNTIME"
clashctl tun >/dev/null || fail 'verified root ownership required a working API'
rm -- "$CLASHCTL_HOME/api-unavailable"

# Bash/Zsh/Fish 的公开入口都应报告本次安装的网卡。
for shell in bash zsh fish; do
    case $shell in
    zsh) args=(-f -c); probe='. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashctl tun' ;;
    fish) args=(--no-config -c); probe='source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; clashctl tun' ;;
    *) args=(-c); probe='. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashctl tun' ;;
    esac
    "$shell" "${args[@]}" "$probe" >/dev/null || fail "$shell status entry failed"
done
printf 'tun-status: ok\n'
