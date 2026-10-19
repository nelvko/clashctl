#!/usr/bin/env bash
# 真实命令与 Shell 环境；服务用磁盘状态模拟，覆盖 Bash/Zsh/Fish 的子进程边界。
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
for shell in bash zsh fish; do command -v "$shell" >/dev/null || fail "$shell is required"; done

cat >"$WORK_DIR/services.sh" <<'STUB'
service_is_active() { [ -f "$CLASHCTL_HOME/running" ]; }
_require_base_config() { [ -f "$CLASHCTL_HOME/base-ready" ]; }
_merge_config() { _require_base_config || return 1; printf 'merge\n' >>"$CLASHCTL_HOME/calls"; }
_detect_proxy_port() { :; }
_detect_ext_addr() { :; }
service_start() {
    [ ! -f "$CLASHCTL_HOME/fail-start" ] || return 1
    printf 'start\n' >>"$CLASHCTL_HOME/calls"
    touch "$CLASHCTL_HOME/running"
}
_assert_stop_proxy_cleared() {
    [ ! -f "$CLASHCTL_HOME/expect-proxy-cleared" ] && return 0
    [ -z "${http_proxy+x}${HTTP_PROXY+x}${https_proxy+x}${HTTPS_PROXY+x}${all_proxy+x}${ALL_PROXY+x}${no_proxy+x}${NO_PROXY+x}" ] &&
        [ ! -f "$XDG_CACHE_HOME/clashctl/proxy.fish" ]
}
service_stop() {
    _assert_stop_proxy_cleared || return 1
    printf 'stop-attempt\n' >>"$CLASHCTL_HOME/calls"
    [ ! -f "$CLASHCTL_HOME/fail-stop" ] && [ ! -f "$CLASHCTL_HOME/privileged" ] || return 1
    printf 'stop\n' >>"$CLASHCTL_HOME/calls"
    rm -f "$CLASHCTL_HOME/running"
}
service_enable() { :; }
_service_privileged_marker_exists() { [ -f "$CLASHCTL_HOME/privileged" ]; }
service_sudo_stop() {
    _assert_stop_proxy_cleared || return 1
    printf 'sudo-stop\n' >>"$CLASHCTL_HOME/calls"
    rm -f "$CLASHCTL_HOME/running" "$CLASHCTL_HOME/privileged"
}
STUB
cat >"$WORK_DIR/probe.sh" <<'PROBE'
set -e
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
assert_proxy_cleared() {
    [ -z "${http_proxy+x}${HTTP_PROXY+x}${https_proxy+x}${HTTPS_PROXY+x}${all_proxy+x}${ALL_PROXY+x}${no_proxy+x}${NO_PROXY+x}" ]
}
snapshot_proxy() {
    env | grep -E '^(http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|all_proxy|ALL_PROXY|no_proxy|NO_PROXY)=' | sort
}
assert_off_unchanged() {
    [ "$(snapshot_proxy)" = "$prior_proxy" ]
    [ "$(wc -l <"$CLASHCTL_HOME/calls")" = "$prior_calls" ]
    if [ "$kernel_state" = running ]; then
        [ -f "$CLASHCTL_HOME/running" ]
    else
        [ ! -f "$CLASHCTL_HOME/running" ]
    fi
}
clashctl off
clashctl start
[ -z "${http_proxy:-}" ]
clashctl on
clashctl on
[ "$http_proxy" = http://127.0.0.1:7890 ]
[ "$(grep -c '^start$' "$CLASHCTL_HOME/calls")" = 1 ]
[ "$(grep -c '^merge$' "$CLASHCTL_HOME/calls")" = 1 ]
clashctl off
[ -z "${http_proxy:-}" ] && [ -f "$CLASHCTL_HOME/running" ]
clashctl on
clashctl stop
clashctl stop
[ ! -f "$CLASHCTL_HOME/running" ] && [ -n "$http_proxy" ]
[ "$(grep -c '^stop$' "$CLASHCTL_HOME/calls")" = 1 ]
clashctl on
[ "$(grep -c '^start$' "$CLASHCTL_HOME/calls")" = 2 ]
# 移除的选项必须报错，且不能改变当前终端环境或内核状态。
for kernel_state in running stopped; do
    [ "$kernel_state" != stopped ] || clashctl stop
    for proxy_command in on off; do
        for legacy_option in -e -s --env-only --service-only; do
            prior_calls=$(wc -l <"$CLASHCTL_HOME/calls")
            if clashctl "$proxy_command" "$legacy_option"; then exit 1; fi
            [ "$http_proxy" = http://127.0.0.1:7890 ]
            [ "$(wc -l <"$CLASHCTL_HOME/calls")" = "$prior_calls" ]
            if [ "$kernel_state" = running ]; then
                [ -f "$CLASHCTL_HOME/running" ]
            else
                [ ! -f "$CLASHCTL_HOME/running" ]
            fi
        done
        if clashctl "$proxy_command" --help -s; then exit 1; fi
        option_help=$(clashctl "$proxy_command" --help)
        if printf '%s\n' "$option_help" | grep -Eq -- '--env-only|--service-only|^[[:space:]]+-[es],'; then exit 1; fi
        [ "$http_proxy" = http://127.0.0.1:7890 ]
    done
done
clashctl on
touch "$CLASHCTL_HOME/fail-stop"
if clashctl stop; then exit 1; fi
[ -f "$CLASHCTL_HOME/running" ] && [ -n "$http_proxy" ]
rm "$CLASHCTL_HOME/fail-stop"
touch "$CLASHCTL_HOME/privileged"
clashctl stop
[ ! -f "$CLASHCTL_HOME/running" ] && [ ! -f "$CLASHCTL_HOME/privileged" ]
# 帮助及参数错误必须在清理代理、停止内核之前返回。
for kernel_state in running stopped; do
    clashctl on
    [ "$kernel_state" != stopped ] || clashctl stop
    prior_calls=$(wc -l <"$CLASHCTL_HOME/calls")
    prior_proxy=$(snapshot_proxy)
    for help_option in -h --help; do
        clashctl off "$help_option" >"$CLASHCTL_HOME/off-help"
        grep -q -- '--stop' "$CLASHCTL_HOME/off-help"
        assert_off_unchanged
    done
    for first_option in --stop --help; do
        for extra_argument in --stop --help --invalid extra; do
            if clashctl off "$first_option" "$extra_argument"; then exit 1; fi
            assert_off_unchanged
        done
    done
    if clashctl on --stop; then exit 1; fi
    assert_off_unchanged
done
# --stop 先清除全部代理变量，再复用 stop 的普通、失败及特权停止路径。
clashctl on
touch "$CLASHCTL_HOME/expect-proxy-cleared"
prior_stops=$(grep -c '^stop$' "$CLASHCTL_HOME/calls")
clashctl off --stop
assert_proxy_cleared
[ ! -f "$CLASHCTL_HOME/running" ]
[ "$(grep -c '^stop$' "$CLASHCTL_HOME/calls")" = "$((prior_stops + 1))" ]
prior_calls=$(wc -l <"$CLASHCTL_HOME/calls")
clashctl off --stop
assert_proxy_cleared
[ "$(wc -l <"$CLASHCTL_HOME/calls")" = "$prior_calls" ]
clashctl on
touch "$CLASHCTL_HOME/fail-stop"
prior_attempts=$(grep -c '^stop-attempt$' "$CLASHCTL_HOME/calls")
if clashctl off --stop; then exit 1; fi
assert_proxy_cleared
[ -f "$CLASHCTL_HOME/running" ]
[ "$(grep -c '^stop-attempt$' "$CLASHCTL_HOME/calls")" = "$((prior_attempts + 1))" ]
rm "$CLASHCTL_HOME/fail-stop"
clashctl on
touch "$CLASHCTL_HOME/privileged"
prior_sudo_stops=$(grep -c '^sudo-stop$' "$CLASHCTL_HOME/calls")
clashctl off --stop
assert_proxy_cleared
[ ! -f "$CLASHCTL_HOME/running" ] && [ ! -f "$CLASHCTL_HOME/privileged" ]
[ "$(grep -c '^sudo-stop$' "$CLASHCTL_HOME/calls")" = "$((prior_sudo_stops + 1))" ]
rm "$CLASHCTL_HOME/expect-proxy-cleared"
export http_proxy=http://before
touch "$CLASHCTL_HOME/fail-start"
if clashctl on; then exit 1; fi
[ "$http_proxy" = http://before ]
rm "$CLASHCTL_HOME/fail-start" "$CLASHCTL_HOME/base-ready"
if clashctl on; then exit 1; fi
[ "$http_proxy" = http://before ]
if clashctl off --invalid; then exit 1; fi
[ "$http_proxy" = http://before ]
clashctl off --help
[ "$http_proxy" = http://before ]
rm "$BIN_KERNEL"
clashctl off
assert_proxy_cleared
PROBE
cat >"$WORK_DIR/probe.fish" <<'PROBE'
source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"
function assert_proxy_cleared
    for name in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
        set -q $name; and exit 1
    end
    test ! -f (__clashctl_state_path); or exit 1
end
function snapshot_proxy
    env | grep -E '^(http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|all_proxy|ALL_PROXY|no_proxy|NO_PROXY)=' | sort
end
function assert_off_unchanged
    set -l kernel_state $argv[1]
    test (string join '|' -- (snapshot_proxy)) = "$prior_proxy"; or exit 1
    test (wc -l <"$CLASHCTL_HOME/calls") = "$prior_calls"; or exit 1
    cmp -s (__clashctl_state_path) "$CLASHCTL_HOME/proxy-before.fish"; or exit 1
    if test "$kernel_state" = running
        test -f "$CLASHCTL_HOME/running"; or exit 1
    else
        test ! -f "$CLASHCTL_HOME/running"; or exit 1
    end
end
clashctl off; or exit 1
clashctl start; or exit 1
set -q http_proxy; and exit 1
clashctl on; or exit 1
clashctl on; or exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
test (grep -c '^start$' "$CLASHCTL_HOME/calls") = 1; or exit 1
clashctl off; or exit 1
set -q http_proxy; and exit 1
test -f "$CLASHCTL_HOME/running"; or exit 1
clashctl on; or exit 1
clashctl stop; or exit 1
test -n "$http_proxy"; or exit 1
test ! -f "$CLASHCTL_HOME/running"; or exit 1
clashctl on; or exit 1
test (grep -c '^start$' "$CLASHCTL_HOME/calls") = 2; or exit 1
for kernel_state in running stopped
    if test "$kernel_state" = stopped
        clashctl stop; or exit 1
    end
    for proxy_command in on off
        for legacy_option in -e -s --env-only --service-only
            set prior_calls (wc -l <"$CLASHCTL_HOME/calls")
            clashctl $proxy_command $legacy_option; and exit 1
            test "$http_proxy" = http://127.0.0.1:7890; or exit 1
            test (wc -l <"$CLASHCTL_HOME/calls") = "$prior_calls"; or exit 1
            if test "$kernel_state" = running
                test -f "$CLASHCTL_HOME/running"; or exit 1
            else
                test ! -f "$CLASHCTL_HOME/running"; or exit 1
            end
        end
        clashctl $proxy_command --help -s; and exit 1
        set option_help (clashctl $proxy_command --help); or exit 1
        printf '%s\n' $option_help | grep -Eq -- '--env-only|--service-only|^[[:space:]]+-[es],'; and exit 1
        test "$http_proxy" = http://127.0.0.1:7890; or exit 1
    end
end
# --stop 的参数校验不能修改 Fish 环境或已缓存的代理配置。
for kernel_state in running stopped
    clashctl on; or exit 1
    if test "$kernel_state" = stopped
        clashctl stop; or exit 1
    end
    set prior_calls (wc -l <"$CLASHCTL_HOME/calls")
    set prior_proxy (string join '|' -- (snapshot_proxy))
    cp (__clashctl_state_path) "$CLASHCTL_HOME/proxy-before.fish"
    for help_option in -h --help
        clashctl off $help_option >"$CLASHCTL_HOME/off-help"; or exit 1
        grep -q -- '--stop' "$CLASHCTL_HOME/off-help"; or exit 1
        assert_off_unchanged $kernel_state
    end
    for first_option in --stop --help
        for extra_argument in --stop --help --invalid extra
            clashctl off $first_option $extra_argument; and exit 1
            assert_off_unchanged $kernel_state
        end
    end
    clashctl on --stop; and exit 1
    assert_off_unchanged $kernel_state
end
clashctl on; or exit 1
touch "$CLASHCTL_HOME/expect-proxy-cleared"
set prior_stops (grep -c '^stop$' "$CLASHCTL_HOME/calls")
clashctl off --stop; or exit 1
assert_proxy_cleared
test ! -f "$CLASHCTL_HOME/running"; or exit 1
test (grep -c '^stop$' "$CLASHCTL_HOME/calls") = (math $prior_stops + 1); or exit 1
set prior_calls (wc -l <"$CLASHCTL_HOME/calls")
clashctl off --stop; or exit 1
assert_proxy_cleared
test (wc -l <"$CLASHCTL_HOME/calls") = "$prior_calls"; or exit 1
clashctl on; or exit 1
touch "$CLASHCTL_HOME/fail-stop"
set prior_attempts (grep -c '^stop-attempt$' "$CLASHCTL_HOME/calls")
clashctl off --stop; and exit 1
assert_proxy_cleared
test -f "$CLASHCTL_HOME/running"; or exit 1
test (grep -c '^stop-attempt$' "$CLASHCTL_HOME/calls") = (math $prior_attempts + 1); or exit 1
rm "$CLASHCTL_HOME/fail-stop"
clashctl on; or exit 1
touch "$CLASHCTL_HOME/privileged"
clashctl off --stop; or exit 1
assert_proxy_cleared
test ! -f "$CLASHCTL_HOME/running"; or exit 1
test ! -f "$CLASHCTL_HOME/privileged"; or exit 1
test (grep -c '^sudo-stop$' "$CLASHCTL_HOME/calls") = 1; or exit 1
rm "$CLASHCTL_HOME/expect-proxy-cleared"
clashctl on; or exit 1
clashctl off; or exit 1
clashctl stop; or exit 1
set -gx http_proxy http://before
touch "$CLASHCTL_HOME/fail-start"
clashctl on; and exit 1
test "$http_proxy" = http://before; or exit 1
clashctl off --invalid; and exit 1
test "$http_proxy" = http://before; or exit 1
clashctl off --help; or exit 1
test "$http_proxy" = http://before; or exit 1
rm "$CLASHCTL_HOME/bin/mihomo" "$CLASHCTL_HOME/base-ready"
clashctl off; or exit 1
assert_proxy_cleared
exit 0
PROBE
for shell in bash zsh fish; do
    home_dir="$WORK_DIR/$shell"
    mkdir -p "$home_dir/bin"
    cp -a "$REPO_DIR/scripts" "$home_dir/"
    printf '1\n' >"$home_dir/.clashctl-format"
    cp "$WORK_DIR/services.sh" "$home_dir/scripts/lib/zz-test.sh"
    printf 'CLASHCTL_KERNEL=mihomo\n' >"$home_dir/.env"
    printf '#!/bin/sh\nprintf "7890\\t0\\t0\\t*\\tfalse\\t\\n"\n' >"$home_dir/bin/yq"
    printf '#!/bin/sh\nexit 0\n' >"$home_dir/bin/mihomo"
    chmod +x "$home_dir/bin/yq" "$home_dir/bin/mihomo"
    touch "$home_dir/base-ready"
    probe="$WORK_DIR/probe.sh"
    shell_args=()
    case "$shell" in
    zsh) shell_args=(-f) ;;
    fish) shell_args=(--no-config); probe="$WORK_DIR/probe.fish" ;;
    esac
    CLASHCTL_HOME="$home_dir" XDG_CACHE_HOME="$home_dir/cache" "$shell" "${shell_args[@]}" "$probe" \
        >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail "$shell proxy lifecycle failed"; }
done
printf 'proxy-lifecycle: ok\n'
