#!/usr/bin/env bash
# 本地 Git 源模拟网络，执行实际管道入口、初始化和更新流程。
# shellcheck disable=SC2119  # 测试无参数的更新入口
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
interrupt_shell_launcher_pid='' interrupt_shell_main_pid=''
cleanup() {
    [ -z "$interrupt_shell_main_pid" ] || kill "$interrupt_shell_main_pid" 2>/dev/null || true
    [ -z "$interrupt_shell_launcher_pid" ] || kill "$interrupt_shell_launcher_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
saved_options() (
    . "$1/.env"
    printf '%s|%s|%s' "$CLASHCTL_KERNEL" "$CLASHCTL_UPDATE_BRANCH" "$GH_PROXY"
)
saved_timeout() ( . "$1/.env"; printf '%s' "$CLASHCTL_DOWNLOAD_TIMEOUT"; )
retry_command_from_output() {
    awk '/^重试:$/ {
        if ((getline) > 0 && /^  /) {
            sub(/^  /, "")
            print
        }
        exit
    }' "$1"
}
export REAL_GIT
REAL_GIT=$(command -v git)
export FIXTURE="$WORK_DIR/source" CI=1 CLASHCTL_HOME="$WORK_DIR/installed"
mkdir -p "$FIXTURE/scripts/lib" "$FIXTURE/scripts/cmd" "$FIXTURE/resources" "$WORK_DIR/bin"
export TEST_CRONTAB="$WORK_DIR/crontab"
: >"$TEST_CRONTAB"
cat >"$WORK_DIR/bin/crontab" <<'CRONTAB'
#!/usr/bin/env bash
case ${1:-} in
-l) cat "$TEST_CRONTAB" ;;
-r) : >"$TEST_CRONTAB" ;;
*) cp "$1" "$TEST_CRONTAB" ;;
esac
CRONTAB
chmod +x "$WORK_DIR/bin/crontab"
cp "$REPO_DIR/scripts/lib/operation-lock.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/lib/install-maintenance.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/lib/service-process.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/lib/common.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/lib/shell.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/cmd/update.sh" "$FIXTURE/scripts/cmd/"
cp "$REPO_DIR/scripts/cmd/tui.sh" "$FIXTURE/scripts/cmd/"
cp "$REPO_DIR/scripts/lib/tui-i18n.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/install.sh" "$FIXTURE/"
cp "$REPO_DIR/uninstall.sh" "$FIXTURE/"
cp "$REPO_DIR/.env.example" "$FIXTURE/"
cp "$REPO_DIR/resources/"{mixin.yaml.example,profiles.yaml} "$FIXTURE/resources/"
printf 'data/\nbin/\n.env\n.clashctl-install\n.clashctl-uninitialized\n.clashctl-incomplete\n.clashctl-files\n' >"$FIXTURE/.gitignore"
cat >"$FIXTURE/scripts/preflight.sh" <<'STUB'
[ ! -f "$CLASHCTL_HOME/.env" ] || . "$CLASHCTL_HOME/.env"
. "$CLASHCTL_SRC/scripts/lib/common.sh"
. "$CLASHCTL_SRC/scripts/lib/service-process.sh"
. "$CLASHCTL_SRC/scripts/lib/operation-lock.sh"
CLASH_DATA_DIR="$CLASHCTL_HOME/data"
CLASH_PROFILES_DIR="$CLASH_DATA_DIR/profiles"
CLASH_RESOURCES_DIR="$CLASHCTL_HOME/resources"
CLASH_CONFIG_BASE="$CLASH_DATA_DIR/config.yaml"
CLASH_CONFIG_MIXIN="$CLASH_DATA_DIR/mixin.yaml"
BIN_YQ=fixture_yq
[ "${TEST_LOCAL_YQ:-0}" != 1 ] || BIN_YQ="$CLASHCTL_HOME/bin/yq"
fixture_yq() {
    if [ "${1:-}" = '.mode // "rule"' ]; then
        if [ -s "$CLASH_CONFIG_BASE" ]; then printf rule; else printf direct; fi
    else
        printf existing-secret
    fi
}
bin_kernel_path() {
    if [ "$CLASHCTL_KERNEL" = mihomo ]; then
        printf '%s/bin/mihomo' "$CLASHCTL_HOME"
    else
        printf '%s/bin/%s/%s' "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" "$CLASHCTL_KERNEL"
    fi
}
gh_proxy_url() { [ -z "${GH_PROXY:-}" ] && printf '%s\n' "$1" || printf '%s/%s\n' "${GH_PROXY%/}" "$1"; }
valid_required() { :; }
detect_service_manager() { service_manager=${TEST_SERVICE_MANAGER:-nohup}; }
detect_rc() {
    SHELL_RC_BASH="$HOME/.bashrc"
    SHELL_RC_ZSH=
    SHELL_RC_FISH=
    [ ! -d "$HOME/.config/fish" ] || SHELL_RC_FISH="$HOME/.config/fish/conf.d/clashctl.fish"
}
_service_check_conflict() { :; }
prepare_zip() {
    if [ "${FAIL_PREPARE:-0}" != 0 ]; then
        [ "${FAIL_PREPARE_TIMEOUT:-0}" != 1 ] || CLASHCTL_DOWNLOAD_TIMED_OUT=1
        if [ "${FAIL_DOWNLOAD_HINT:-0}" = 1 ]; then
            [ "${_INSTALL_DEFER_DOWNLOAD_HINT:-0}" = 1 ] || return 1
            _INSTALL_DOWNLOAD_FAILED_URL=$(gh_proxy_url https://example.invalid/mihomo.gz)
            _INSTALL_DOWNLOAD_FAILED_TARGET="$CLASHCTL_HOME/archives/mihomo.gz"
        fi
        return 1
    fi
    mkdir -p "$CLASHCTL_HOME/bin"
    printf kernel >"$CLASHCTL_HOME/bin/kernel"
    printf '%s\n' "$*" >"$CLASHCTL_HOME/data/prepared-components"
    for component in "$@"; do
        case $component in
        kernel)
            mkdir -p "$(dirname -- "$BIN_KERNEL")"
            printf kernel >"$BIN_KERNEL"
            chmod 755 "$BIN_KERNEL"
            ;;
        yq)
            if [ "${TEST_LOCAL_YQ:-0}" = 1 ]; then
                printf '#!/bin/sh\nprintf existing-secret\n' >"$BIN_YQ"
                chmod 755 "$BIN_YQ"
            fi
            ;;
        esac
    done
    printf '%s|%s|%s\n' "$CLASHCTL_KERNEL" "$CLASHCTL_UPDATE_BRANCH" "$GH_PROXY" >"$CLASHCTL_HOME/data/download-options"
    printf '%s\n' "$CLASHCTL_DOWNLOAD_TIMEOUT" >"$CLASHCTL_HOME/data/download-timeout"
    printf '%s\n' "${_INSTALL_VERBOSE:-}" >"$CLASHCTL_HOME/data/download-verbose"
}
_set_env() { printf '%s=%q\n' "$1" "$2" >>"$CLASHCTL_HOME/.env"; }
_merge_config() { printf runtime >"$CLASH_DATA_DIR/runtime.yaml"; }
_detect_proxy_port() { :; }
_detect_ext_addr() { :; }
_get_secret() { printf existing-secret; }
install_service() { :; }
service_start() { [ "${FAIL_START:-0}" = 0 ] && touch "$CLASH_DATA_DIR/started"; }
service_stop_checked() { rm -f "$CLASH_DATA_DIR/started"; }
service_is_active() { [ -f "$CLASH_DATA_DIR/started" ]; }
_service_enable() {
    [ "${FAIL_ENABLE:-0}" = 0 ] || return 1
    [ "$service_manager" = nohup ] || touch "$CLASH_DATA_DIR/enabled"
}
clashstart() { service_is_active && return 0; _merge_config && service_start && service_enable; }
clashsub() {
    [ "${FAIL_SUB:-0}" = 0 ] || return 1
    printf '%s' "$3" >"$CLASH_DATA_DIR/subscription"
    printf main-config >"$CLASH_CONFIG_BASE"
    _merge_config && service_start
}
apply_rc() {
    if [ "${FAIL_RC:-0}" = 1 ]; then
        printf 'partial-new-shell-config\n' >>"$HOME/.bashrc"
        if [ -f "$HOME/.config/fish/conf.d/clashctl.fish" ]; then
            printf 'partial-new-fish-config\n' >>"$HOME/.config/fish/conf.d/clashctl.fish"
        fi
        return 1
    fi
    if [ "${INTERRUPT_AFTER_RC:-0}" = 1 ]; then
        printf '# new shell integration\nexport CLASHCTL_HOME=%q\n. $CLASHCTL_HOME/scripts/cmd/clashctl.sh\n' \
            "$CLASHCTL_HOME" >"$HOME/.bashrc"
        printf "# new fish integration\nset -gx CLASHCTL_HOME '%s'\n" \
            "$CLASHCTL_HOME" >"$HOME/.config/fish/conf.d/clashctl.fish"
        printf '%s\n' "$BASHPID" >"$INTERRUPT_SHELL_MARKER"
        while :; do sleep 0.05; done
    fi
    touch "$CLASH_DATA_DIR/shell-ready"
    SHELL_RC_BASH="$CLASH_DATA_DIR/.bashrc"
    touch "$SHELL_RC_BASH"
}
uninstall_service() { [ "${FAIL_STOP:-0}" = 0 ]; }
revoke_rc() { :; }
_ui_error() { printf '%s\n' "$*" >&2; }
_ui_info() { printf '%s\n' "$*"; }
_ui_step() { printf '\n[STEP] %s\n' "$*" >&2; }
_ui_ok() { printf '%s\n' "$*"; }
_ui_warn() { printf '%s\n' "$*"; }
_install_ui_step() { _ui_step "$@"; }
_install_ui_info() { _ui_info "$@"; }
_install_ui_ok() { _ui_ok "$@"; }
_install_ui_warn() { _ui_warn "$@"; }
_ui_detail() {
    if [ "$#" -gt 1 ]; then
        printf '        %s: %s\n' "$1" "$2"
    else
        printf '        %s\n' "$1"
    fi
}
STUB
# 使用真实的自启错误处理；后端操作由 fixture 接管，不访问宿主服务。
(
    # shellcheck source=../scripts/lib/service.sh
    . "$REPO_DIR/scripts/lib/service.sh"
    declare -f service_enable
) >>"$FIXTURE/scripts/preflight.sh"
# 与真实加载器一致：重载服务库后需要重新检测管理方式。
printf 'service_manager=\nfixture_version=old\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
"$REAL_GIT" -C "$FIXTURE" init -q -b main
"$REAL_GIT" -C "$FIXTURE" config user.email test@example.invalid
"$REAL_GIT" -C "$FIXTURE" config user.name test
"$REAL_GIT" -C "$FIXTURE" add .
"$REAL_GIT" -C "$FIXTURE" commit -qm initial
"$REAL_GIT" -C "$FIXTURE" branch iu
"$REAL_GIT" -C "$FIXTURE" checkout -qb legacy
"$REAL_GIT" -C "$FIXTURE" rm -q .env.example
"$REAL_GIT" -C "$FIXTURE" commit -qm legacy-layout
"$REAL_GIT" -C "$FIXTURE" checkout -q main
cat >"$WORK_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
[ "${FAIL_FETCH:-0}" = 0 ] || exit 1
[ -z "${GIT_CALL_LOG:-}" ] || printf '%s\n' "$*" >>"$GIT_CALL_LOG"
args=()
for arg in "$@"; do
    case $arg in
    *github.com/HolyDDL/clashctl-daemon.git) arg=$FIXTURE ;;
    esac
    args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
STUB
chmod +x "$WORK_DIR/bin/git"
export PATH="$WORK_DIR/bin:$PATH"
# 正式目录落盘前必须持锁；失败不能留下半安装目录或临时源码。
(
    . "$REPO_DIR/scripts/lib/operation-lock.sh"
    operation_lock_acquire || fail 'could not hold installation lock'
    trap operation_lock_release EXIT
    locked_home="$WORK_DIR/locked-new"
    if CLASHCTL_HOME="$locked_home" bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/locked-new.out" 2>&1; then
        fail 'new installation ignored held lock'
    fi
    grep -q '另一项 clashctl' "$WORK_DIR/locked-new.out" || fail 'new installation did not diagnose contention'
    [ ! -e "$locked_home" ] || fail 'lock contention created installation directory'
    [ -z "$(find "$WORK_DIR" -maxdepth 1 -name 'locked-new.download.*' -print -quit)" ] || fail 'lock contention left staged source'
)
# 兼容后端的安装/更新回归显式选择 auto；默认用户服务由 install-service.sh 覆盖。
# stdin 是脚本，CI 跳过 /dev/tty 输入；初始化不能只安装命令空壳。
# shellcheck disable=SC2002  # 必须验证管道输入，不能改成文件执行
# 两个 env -u：未设时才走管道安装，保证下面断言的是"未提供即直连"。
GIT_CALL_LOG="$WORK_DIR/quiet-git.log" env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH \
    bash -c 'cat "$1" | bash -s -- --service auto' _ "$REPO_DIR/install.sh" >"$WORK_DIR/install.out" 2>&1
[ -f "$CLASHCTL_HOME/data/started" ] || fail 'empty install did not start service'
[ ! -f "$CLASHCTL_HOME/data/enabled" ] || fail 'nohup install enabled a service'
[ ! -s "$CLASHCTL_HOME/data/config.yaml" ] || fail 'empty install created a fake subscription'
grep -Fq 'mihomo 已启动（直连）' "$WORK_DIR/install.out" || fail 'empty install did not explain direct mode'
grep -Fq 'nohup 后台运行' "$WORK_DIR/install.out" || fail 'nohup install did not explain its startup mode'
! grep -q '开机自启' "$WORK_DIR/install.out" || fail 'nohup install claimed boot startup'
grep -q 'clone .*--quiet' "$WORK_DIR/quiet-git.log" || fail 'default source download did not quiet Git progress'
[ -f "$CLASHCTL_HOME/data/shell-ready" ] || fail 'pipeline did not install shell integration'
[ -f "$CLASHCTL_HOME/.env" ] || fail 'pipeline did not write environment'
[ ! -e "$CLASHCTL_HOME/.clashctl-uninitialized" ] || fail 'initialized installation retains uninitialized marker'
[ ! -e "$CLASHCTL_HOME/.clashctl-incomplete" ] || fail 'initialized installation retains incomplete marker'
[ "$(head -n 1 "$CLASHCTL_HOME/.clashctl-install")" = "$CLASHCTL_HOME" ] || fail 'pipeline did not record installation path'
[ "$(stat -c %a "$CLASHCTL_HOME/.clashctl-install")" = 600 ] || fail 'installation marker is not private'
# 默认安装实际使用并保存直连配置；模板注释及示例值不决定安装器行为。
[ "$(cat "$CLASHCTL_HOME/data/download-options")" = 'mihomo|main|' ] || fail 'default install used an implicit proxy'
bash -c '. "$1"; [ -z "${GH_PROXY:-}" ]' _ "$CLASHCTL_HOME/.env" || fail 'default install persisted an implicit proxy'
grep -q '安装完成' "$WORK_DIR/install.out" || fail 'missing install result'
grep -q '新安装 clashctl' "$WORK_DIR/install.out" || fail 'missing initial installation state'
grep -Fq "安装目录: $CLASHCTL_HOME" "$WORK_DIR/install.out" || fail 'missing installation directory'
grep -Fq "安装目录: $CLASHCTL_HOME（CLASHCTL_HOME）" "$WORK_DIR/install.out" || fail 'missing installation directory source'
grep -Fq '（分支 main）' "$WORK_DIR/install.out" || fail 'missing source branch'
grep -Fq '在当前终端执行（bash）:' "$WORK_DIR/install.out" || fail 'missing shell activation heading'
grep -Fq 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"' "$WORK_DIR/install.out" || fail 'missing shell activation step'
grep -Fq 'clashctl sub add --use "<URL>"' "$WORK_DIR/install.out" || fail 'missing subscription step'
grep -q '^ *clashctl on *#' "$WORK_DIR/install.out" || fail 'missing proxy activation step'
python3 - "$WORK_DIR/install.out" <<'PY'
import pathlib, sys
output = pathlib.Path(sys.argv[1]).read_text()
commands = ['在当前终端执行', 'source ', 'clashctl on', 'clashctl ui', '按需添加订阅:', 'clashctl sub add --use']
positions = [output.index(command) for command in commands]
assert positions == sorted(positions), 'optional subscription interrupted terminal activation steps'
PY
if grep -q 'find: warning:' "$WORK_DIR/install.out"; then fail 'source validation emitted a find warning'; fi

# 首次安装前仅准备 archives，源码提交与失败重试都必须保留原安装包。
prepared_home="$WORK_DIR/prepared-archives"
mkdir -p "$prepared_home/archives"
printf 'user-package\n' | gzip >"$prepared_home/archives/mihomo-linux-amd64-v1-v1.19.32.gz"
prepared_sum=$(sha256sum "$prepared_home/archives/"*.gz)
if FAIL_FETCH=1 CLASHCTL_HOME="$prepared_home" bash "$REPO_DIR/install.sh" --service auto \
    >"$WORK_DIR/prepared-source-failed.out" 2>&1; then fail 'prepared source download failure was ignored'; fi
[ "$(sha256sum "$prepared_home/archives/"*.gz)" = "$prepared_sum" ] || fail 'source failure changed prepared archives'
[ ! -e "$prepared_home/install.sh" ] || fail 'source failure wrote installation files'
if FAIL_PREPARE=1 CLASHCTL_HOME="$prepared_home" bash "$REPO_DIR/install.sh" --service auto \
    >"$WORK_DIR/prepared-components-failed.out" 2>&1; then fail 'prepared component failure was ignored'; fi
[ "$(sha256sum "$prepared_home/archives/"*.gz)" = "$prepared_sum" ] || fail 'component failure changed prepared archives'
CLASHCTL_HOME="$prepared_home" bash "$prepared_home/install.sh" --service auto \
    >"$WORK_DIR/prepared-retry.out" 2>&1 || { cat "$WORK_DIR/prepared-retry.out"; fail 'prepared installation retry failed'; }
[ -f "$prepared_home/data/started" ] || fail 'prepared installation did not start'
[ "$(sha256sum "$prepared_home/archives/"*.gz)" = "$prepared_sum" ] || fail 'prepared installation lost original archives'

# 只放安装包的目录不能被误认为可卸载安装；未知内容和链接仍然拒绝。
(
    . "$REPO_DIR/install.sh"
    for kind in unknown symlink-file symlink-dir writable; do
        unsafe_home="$WORK_DIR/prepared-$kind"
        mkdir -p "$unsafe_home/archives"
        case $kind in
        unknown) printf untouched >"$unsafe_home/unrelated" ;;
        symlink-file) ln -s "$prepared_home/archives/"*.gz "$unsafe_home/archives/package.gz" ;;
        symlink-dir) rmdir "$unsafe_home/archives"; ln -s "$prepared_home/archives" "$unsafe_home/archives" ;;
        writable) chmod 0777 "$unsafe_home/archives" ;;
        esac
        if _install_prepared_archives_safe "$unsafe_home"; then fail "unsafe prepared directory accepted: $kind"; fi
    done
    raw_home="$WORK_DIR/prepared-identity"
    mkdir -p "$raw_home/archives"
    if _install_existing_kind "$raw_home" >/dev/null 2>&1; then fail 'prepared directory was treated as an installed instance'; fi
    for failure in error signal; do
        stage_dir="$WORK_DIR/prepared-rollback-$failure"
        mkdir "$stage_dir"
        printf a >"$stage_dir/a"
        printf b >"$stage_dir/b"
        mv() {
            if [ "${3:-}" = "$stage_dir/b" ]; then
                [ "$failure" != signal ] || kill -TERM "$BASHPID"
                return 1
            fi
            command mv "$@"
        }
        if _install_commit_prepared_source "$stage_dir" "$raw_home"; then fail "prepared $failure commit succeeded"; fi
        [ -f "$stage_dir/a" ] && [ -f "$stage_dir/b" ] || fail "prepared $failure rollback lost source files"
        [ ! -e "$raw_home/a" ] && [ ! -e "$raw_home/b" ] || fail "prepared $failure rollback left partial files"
        unset -f mv
    done
)

# 未添加订阅也要启动内核并为受管服务启用默认自启。
direct_managed_home="$WORK_DIR/direct-managed"
TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$direct_managed_home" bash "$REPO_DIR/install.sh" --service auto \
    >"$WORK_DIR/direct-managed.out" 2>&1 || fail 'managed direct install failed'
[ -f "$direct_managed_home/data/started" ] || fail 'managed direct install did not start the kernel'
[ -f "$direct_managed_home/data/enabled" ] || fail 'managed direct install did not enable autostart'
# 重装应保留运行/停止 × 启用/禁用四种组合，已有内核无需下载。
for running in yes no; do
    for enabled in yes no; do
        rm -f "$direct_managed_home/data/started" "$direct_managed_home/data/enabled"
        [ "$running" != yes ] || touch "$direct_managed_home/data/started"
        [ "$enabled" != yes ] || touch "$direct_managed_home/data/enabled"
        FAIL_PREPARE=1 TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$direct_managed_home" \
            bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/reinstall.out" 2>&1 || {
                cat "$WORK_DIR/reinstall.out"; fail 'reinstall downloaded an existing kernel or failed';
            }
        actual_running=no actual_enabled=no
        [ ! -f "$direct_managed_home/data/started" ] || actual_running=yes
        [ ! -f "$direct_managed_home/data/enabled" ] || actual_enabled=yes
        [ "$running:$enabled" = "$actual_running:$actual_enabled" ] || fail 'reinstall changed service state'
    done
done
# 缺失组件修复失败再重试，也不能把已完成但停止的安装当作首次安装启动。
rm "$direct_managed_home/bin/mihomo"
if FAIL_PREPARE=1 TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$direct_managed_home" \
    bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/repair-failed.out" 2>&1; then
    fail 'missing kernel repair failure was ignored'
fi
[ ! -e "$direct_managed_home/.clashctl-incomplete" ] || fail 'repair failure lost completed installation state'
TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$direct_managed_home" \
    bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/repair.out" 2>&1
[ -x "$direct_managed_home/bin/mihomo" ] || fail 'missing kernel was not repaired'
[ ! -e "$direct_managed_home/data/started" ] || fail 'repair retry started a stopped kernel'
[ ! -e "$direct_managed_home/data/enabled" ] || fail 'repair retry enabled autostart'
printf preserved-kernel >"$direct_managed_home/bin/mihomo"
TEST_LOCAL_YQ=1 TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$direct_managed_home" \
    bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/repair-yq.out" 2>&1
[ -x "$direct_managed_home/bin/yq" ] || fail 'missing yq was not repaired'
[ "$(cat "$direct_managed_home/data/prepared-components")" = yq ] || fail 'yq repair downloaded other components'
[ "$(cat "$direct_managed_home/bin/mihomo")" = preserved-kernel ] || fail 'yq repair overwrote existing kernel'
[ ! -e "$direct_managed_home/data/started" ] || fail 'yq repair started a stopped kernel'


grep -Fq '已注册 systemd 服务' "$WORK_DIR/direct-managed.out" || fail 'managed direct install omitted registration result'
grep -Fq '已设置开机自启' "$WORK_DIR/direct-managed.out" || fail 'managed direct install omitted autostart result'
# 无订阅的启动失败仍是安装失败，不能输出成功或设置自启。
direct_failed_home="$WORK_DIR/direct-start-failed"
if FAIL_START=1 TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$direct_failed_home" bash "$REPO_DIR/install.sh" --service auto \
    >"$WORK_DIR/direct-start-failed.out" 2>&1; then
    fail 'direct install ignored kernel startup failure'
fi
[ -f "$direct_failed_home/.clashctl-incomplete" ] || fail 'direct startup failure lost incomplete marker'
[ ! -e "$direct_failed_home/data/enabled" ] || fail 'failed direct startup enabled autostart'
! grep -q '安装完成\|已设置开机自启' "$WORK_DIR/direct-start-failed.out" || fail 'failed direct startup claimed success'
# 订阅失败后仍可直连使用；可复制的添加命令仅在末尾出现一次。
sub_failed_home="$WORK_DIR/subscription-failed"
FAIL_SUB=1 CLASHCTL_HOME="$sub_failed_home" bash "$REPO_DIR/install.sh" --service auto --sub file:///unavailable \
    >"$WORK_DIR/subscription-failed.out" 2>&1 || fail 'subscription failure prevented direct installation'
[ -f "$sub_failed_home/data/started" ] || fail 'subscription failure did not fall back to direct startup'
grep -q '订阅添加失败，可稍后重试' "$WORK_DIR/subscription-failed.out" || fail 'subscription failure omitted retry hint'
[ "$(grep -Fc 'clashctl sub add --use "<URL>"' "$WORK_DIR/subscription-failed.out")" -eq 1 ] ||
    fail 'subscription retry command was duplicated'
# 下载运行组件失败时仍可凭安装阶段标记清理，不能依靠 .env 缺失猜测。
interrupted_home="$WORK_DIR/prepare-failed"
if FAIL_PREPARE=1 FAIL_PREPARE_TIMEOUT=1 FAIL_DOWNLOAD_HINT=1 CLASHCTL_HOME="$interrupted_home" bash "$REPO_DIR/install.sh" --service auto \
    --gh-proxy=https://slow.proxy.test >"$WORK_DIR/prepare-failed.out" 2>&1; then
    fail 'component preparation failure was ignored'
fi
[ "$(retry_command_from_output "$WORK_DIR/prepare-failed.out")" = \
    "CLASHCTL_DOWNLOAD_TIMEOUT=0 bash $interrupted_home/install.sh --install-dir $interrupted_home --branch=main --gh-proxy=https://slow.proxy.test --service=auto" ] ||
    fail 'retry hint lost the proxy or unlimited timeout'
python3 - "$WORK_DIR/prepare-failed.out" "$interrupted_home" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1]).read_text()
expected = ('安装未完成，已保留目录：', '\n重试:\n  CLASHCTL_DOWNLOAD_TIMEOUT=0 bash ',
            '\n手动下载安装包:\n', '  下载地址: https://slow.proxy.test/https://example.invalid/mihomo.gz',
            f'  保存位置: {sys.argv[2]}/archives/mihomo.gz', '保存完整安装包后，执行上述重试命令。')
positions = [output.index(value) for value in expected]
assert positions == sorted(positions), 'manual download instructions interrupt the retry steps'
assert output.count('下载地址:') == 1, 'failed installation repeats its download URL'
assert '目标:' not in output and '保存目录:' not in output, 'failed installation repeats the destination'
PY
if FAIL_PREPARE=1 FAIL_PREPARE_TIMEOUT=1 CLASHCTL_DOWNLOAD_TIMEOUT=30 CLASHCTL_HOME="$interrupted_home" \
    bash "$interrupted_home/install.sh" --service auto >"$WORK_DIR/prepare-limited.out" 2>&1; then
    fail 'component preparation with a finite timeout unexpectedly succeeded'
fi
[[ "$(retry_command_from_output "$WORK_DIR/prepare-limited.out")" == 'CLASHCTL_DOWNLOAD_TIMEOUT=180 bash '* ]] ||
    fail 'retry hint did not extend an explicit finite timeout'
[ ! -e "$interrupted_home/.env" ] || fail 'failed preparation wrote environment'
[ "$(cat "$interrupted_home/.clashctl-uninitialized")" = "$interrupted_home" ] || fail 'missing uninitialized path marker'
bash "$interrupted_home/uninstall.sh" --yes >"$WORK_DIR/prepare-uninstall.out" 2>&1 || fail 'interrupted installation cannot be cleaned'
[ ! -d "$interrupted_home" ] || fail 'interrupted installation remains'
# --gh-proxy 旗标：管道写法下参数写在右侧 bash 之后，两种形式都要生效并写入 .env。
for flag in '--gh-proxy https://flag.proxy.test' '--gh-proxy=https://flag.proxy.test'; do
    proxy_home="$WORK_DIR/flag-home"
    rm -rf "$proxy_home"
    # shellcheck disable=SC2002,SC2086  # 验证管道入口，并故意拆分旗标和值。
    cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$proxy_home" CI=1 bash -s -- --service auto $flag >"$WORK_DIR/flag.out" 2>&1 ||
        { cat "$WORK_DIR/flag.out"; fail "gh-proxy flag rejected: $flag"; }
    grep -q '^GH_PROXY=https://flag.proxy.test$' "$proxy_home/.env" ||
        fail "gh-proxy flag was not persisted: $flag"
done
rm -rf "$WORK_DIR/flag-home"
# --branch 两种形式控制实际克隆并覆盖环境变量；保存后供重复安装和更新沿用。
for form in separate equals; do
    branch_home="$WORK_DIR/branch-$form"
    branch_args=(--branch=iu)
    [ "$form" != separate ] || branch_args=(--branch iu)
    # shellcheck disable=SC2002  # 验证管道右侧的命令行分支参数。
    cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$branch_home" CLASHCTL_UPDATE_BRANCH=legacy \
        bash -s -- --service auto "${branch_args[@]}" >"$WORK_DIR/branch-$form.out" 2>&1 ||
        { cat "$WORK_DIR/branch-$form.out"; fail "branch flag rejected: $form"; }
    [ "$("$REAL_GIT" -C "$branch_home" branch --show-current)" = iu ] || fail 'branch flag did not select clone source'
    grep -q '^CLASHCTL_UPDATE_BRANCH=iu$' "$branch_home/.env" || fail 'branch flag was not persisted'
    env -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$branch_home" \
        bash "$branch_home/install.sh" --service auto >"$WORK_DIR/branch-retry.out" 2>&1
    [ "$(saved_options "$branch_home")" = 'mihomo|iu|' ] || fail 'retry lost selected branch'
    : >"$WORK_DIR/branch-update.log"
    (
        export CLASHCTL_HOME="$branch_home" CLASHCTL_SRC="$branch_home" GIT_CALL_LOG="$WORK_DIR/branch-update.log"
        . "$branch_home/scripts/preflight.sh"
        . "$branch_home/scripts/cmd/update.sh"
        _update_scripts
    ) >"$WORK_DIR/branch-update.out" 2>&1 ||
        { cat "$WORK_DIR/branch-update.out"; fail 'update failed for selected branch'; }
    grep -q 'fetch .* iu$' "$WORK_DIR/branch-update.log" || fail 'update did not fetch saved branch'
    CLASHCTL_HOME="$branch_home" CLASHCTL_UPDATE_BRANCH=legacy \
        bash "$branch_home/install.sh" --service auto --branch main >"$WORK_DIR/branch-switch.out" 2>&1
    [ "$(saved_options "$branch_home")" = 'mihomo|main|' ] || fail 'branch flag did not override environment and saved branch'
    grep -q '^CLASHCTL_UPDATE_BRANCH=main$' "$branch_home/.env" || fail 'branch switch was not persisted'
done
# .env 尚未生成时，失败提示中的命令也必须能恢复原分支。
branch_failed_home="$WORK_DIR/branch-failed"
if FAIL_PREPARE=1 CLASHCTL_HOME="$branch_failed_home" CLASHCTL_UPDATE_BRANCH=main \
    bash "$REPO_DIR/install.sh" --service auto --branch iu >"$WORK_DIR/branch-failed.out" 2>&1; then
    fail 'failed branch installation succeeded'
fi
[ ! -e "$branch_failed_home/.env" ] || fail 'branch retry fixture already has saved options'
branch_retry_command=$(retry_command_from_output "$WORK_DIR/branch-failed.out")
[ -n "$branch_retry_command" ] || fail 'branch installation omitted retry command'
env -u CLASHCTL_UPDATE_BRANCH bash -c "$branch_retry_command" >"$WORK_DIR/branch-recovery.out" 2>&1
grep -q '^CLASHCTL_UPDATE_BRANCH=iu$' "$branch_failed_home/.env" || fail 'retry command lost branch before configuration was saved'
# 安装参数：显式内核和订阅支持分离值与等号写法，订阅立即启用。
for form in separate equals; do
    option_home="$WORK_DIR/options-$form"
    if [ "$form" = separate ]; then
        option_args=(--kernel clash --sub 'file:///install-sub?token=example&name=main')
    else
        option_args=(--kernel=clash '--sub=file:///install-sub?token=example&name=main')
    fi
    TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$option_home" bash "$REPO_DIR/install.sh" --service auto "${option_args[@]}" \
        >"$WORK_DIR/options-$form.out" 2>&1 ||
        { cat "$WORK_DIR/options-$form.out"; fail "install options rejected: $form"; }
    [ "$(cat "$option_home/data/subscription")" = 'file:///install-sub?token=example&name=main' ] ||
        fail "install subscription was not passed through: $form"
    [ "$(cat "$option_home/data/download-options")" = 'clash|main|' ] ||
        fail "install kernel option was not applied: $form"
    [ -f "$option_home/data/started" ] || fail "install subscription was not activated: $form"
    [ -f "$option_home/data/enabled" ] || fail "install subscription did not enable service: $form"
    grep -Fq '已注册 systemd 服务' "$WORK_DIR/options-$form.out" || fail 'managed service registration result missing'
    grep -Fq '已设置开机自启' "$WORK_DIR/options-$form.out" || fail 'managed service startup result missing'
done
# 详细模式必须从安装入口传递到组件下载阶段。
verbose_home="$WORK_DIR/verbose-install"
GIT_CALL_LOG="$WORK_DIR/verbose-git.log" CLASHCTL_HOME="$verbose_home" bash "$REPO_DIR/install.sh" --service auto --verbose >"$WORK_DIR/verbose.out" 2>&1 ||
    { cat "$WORK_DIR/verbose.out"; fail 'verbose installation failed'; }
[ "$(cat "$verbose_home/data/download-verbose")" = 1 ] || fail 'verbose option did not reach component downloads'
! grep -q 'clone .*--quiet' "$WORK_DIR/verbose-git.log" || fail 'verbose source download hid Git progress'
# 订阅与无订阅路径都必须指出自启设置失败；续装需恢复已运行内核的自启。
for subscription_state in subscribed direct; do
    enable_failed_home="$WORK_DIR/enable-failed-$subscription_state"
    enable_args=()
    [ "$subscription_state" != subscribed ] || enable_args=(--sub file:///enable-retry)
    if FAIL_ENABLE=1 TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$enable_failed_home" bash "$REPO_DIR/install.sh" --service auto \
        "${enable_args[@]}" >"$WORK_DIR/enable-failed-$subscription_state.out" 2>&1; then
        fail 'service enable failure succeeded'
    fi
    grep -q '开机自启设置失败' "$WORK_DIR/enable-failed-$subscription_state.out" || fail 'enable failure omitted its failed operation'
    ! grep -q '安装完成\|已设置开机自启' "$WORK_DIR/enable-failed-$subscription_state.out" || fail 'enable failure claimed installation or autostart success'
    [ -f "$enable_failed_home/data/started" ] && [ -f "$enable_failed_home/.clashctl-incomplete" ] || fail 'enable failure lost running/incomplete state'
    [ ! -e "$enable_failed_home/data/enabled" ] || fail 'failed enable set autostart'
    TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$enable_failed_home" bash "$enable_failed_home/install.sh" --service auto >"$WORK_DIR/enable-retry-$subscription_state.out" 2>&1
    [ -f "$enable_failed_home/data/enabled" ] || fail 'retry did not enable already running service'
    [ ! -e "$enable_failed_home/.clashctl-incomplete" ] || fail 'enable retry retained incomplete state'
    grep -Fq 'mihomo 已在运行' "$WORK_DIR/enable-retry-$subscription_state.out" || fail 'enable retry did not preserve the running status'
done
# 无效参数应在下载源码、创建安装目录前报错。
for bad_arg in --kernel --kernel= --kernel=unknown --sub --sub= mihomo clash; do
    invalid_option_home="$WORK_DIR/invalid-option"
    if CLASHCTL_HOME="$invalid_option_home" bash "$REPO_DIR/install.sh" --service auto "$bad_arg" \
        >"$WORK_DIR/invalid-option.out" 2>&1; then
        fail "invalid install option accepted: $bad_arg"
    fi
    [ ! -e "$invalid_option_home" ] || fail "invalid option created installation: $bad_arg"
done
# 分支缺失或下一参数被误作分支时，在任何下载与落盘前拒绝。
for form in missing empty equals next-option; do
    case $form in
    missing) branch_args=(--branch) ;;
    empty) branch_args=(--branch '') ;;
    equals) branch_args=(--branch=) ;;
    next-option) branch_args=(--branch --local) ;;
    esac
    invalid_branch_home="$WORK_DIR/invalid-branch"
    if FAIL_FETCH=1 CLASHCTL_HOME="$invalid_branch_home" bash "$REPO_DIR/install.sh" --service auto "${branch_args[@]}" \
        >"$WORK_DIR/invalid-branch.out" 2>&1; then
        fail "missing branch accepted: $form"
    fi
    grep -q -- '--branch 需要一个分支名称' "$WORK_DIR/invalid-branch.out" || fail 'missing branch was not diagnosed before fetch'
    [ ! -e "$invalid_branch_home" ] || fail 'invalid branch created installation directory'
done
# 未发布的旧参数直接移除，带有效值时也不能作为兼容别名接受。
for old_option in --home --subscription; do
    old_value="$WORK_DIR/removed-option-target"
    [ "$old_option" != --subscription ] || old_value=file:///removed-option-sub
    for form in separate equals; do
        old_args=("$old_option" "$old_value")
        [ "$form" != equals ] || old_args=("$old_option=$old_value")
        rejected_home="$WORK_DIR/removed-option-home"
        if FAIL_FETCH=1 CLASHCTL_HOME="$rejected_home" bash "$REPO_DIR/install.sh" --service auto "${old_args[@]}" \
            >"$WORK_DIR/removed-option.out" 2>&1; then
            fail "removed option was accepted: $old_option ($form)"
        fi
        grep -q '未知安装参数' "$WORK_DIR/removed-option.out" || fail 'removed option reached source preparation'
        [ ! -e "$rejected_home" ] && [ ! -e "$WORK_DIR/removed-option-target" ] || fail 'removed option created installation'
    done
done
# --install-dir 两种形式均可用于管道安装，且覆盖右侧 bash 继承的 CLASHCTL_HOME。
for form in separate equals; do
    flag_home="$WORK_DIR/home-$form"
    ignored_home="$WORK_DIR/ignored-home-$form"
    if [ "$form" = separate ]; then
        home_args=(--install-dir "$flag_home")
    else
        home_args=("--install-dir=$flag_home")
    fi
    # shellcheck disable=SC2002  # 验证从 stdin 运行安装器及右侧 bash 的参数。
    cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$ignored_home" CI=1 \
        bash -s -- --service auto "${home_args[@]}" >"$WORK_DIR/home-$form.out" 2>&1 ||
        { cat "$WORK_DIR/home-$form.out"; fail "home flag rejected: $form"; }
    [ -f "$flag_home/.env" ] || fail "home flag did not initialize target: $form"
    [ "$(head -n 1 "$flag_home/.clashctl-install")" = "$flag_home" ] ||
        fail "home flag recorded wrong path: $form"
    [ ! -e "$ignored_home" ] || fail "CLASHCTL_HOME overrode home flag: $form"
    grep -Fq "安装目录: $flag_home" "$WORK_DIR/home-$form.out" || fail 'explicit home not shown'
done
# 缺失值、空值和无效路径都必须在创建安装目录前拒绝。
for bad_arg in --install-dir --install-dir=; do
    missing_home="$WORK_DIR/missing-home"
    if CLASHCTL_HOME="$missing_home" bash "$REPO_DIR/install.sh" --service auto "$bad_arg" \
        >"$WORK_DIR/missing-home.out" 2>&1; then
        fail "home accepted missing value: $bad_arg"
    fi
    grep -q -- '--install-dir' "$WORK_DIR/missing-home.out" ||
        fail "home missing value lacked a diagnosis: $bad_arg"
    [ ! -e "$missing_home" ] || fail "missing home value fell back to CLASHCTL_HOME: $bad_arg"
done
for invalid_dir in relative-home "$WORK_DIR/invalid install dir"; do
    if bash "$REPO_DIR/install.sh" --service auto --install-dir "$invalid_dir" \
        >"$WORK_DIR/invalid-home.out" 2>&1; then
        fail "home accepted invalid path: $invalid_dir"
    fi
    grep -q '安装目录必须是绝对路径' "$WORK_DIR/invalid-home.out" ||
        fail "home invalid path lacked a diagnosis: $invalid_dir"
done
# 执行 README 安装代码块，将入口下载替换成本地脚本，并显式选择兼容后端。
readme_command=$(awk '
    /^```bash[[:space:]]*$/ { in_block=1; command=""; next }
    in_block && /^```[[:space:]]*$/ {
        if (command ~ /curl .*install\.sh.*\|/ && command ~ /bash -s/) {
            printf "%s", command
            exit
        }
        in_block=0
        next
    }
    in_block { command=command $0 "\n" }
' "$REPO_DIR/README.md")
[ -n "$readme_command" ] || fail 'README installation command missing'
CLASHCTL_HOME="$WORK_DIR/readme-home" bash -c '
    installer=$1
    curl() { cat "$installer"; }
    eval "$2 --service auto"
' _ "$REPO_DIR/install.sh" "$readme_command" >"$WORK_DIR/readme.out" 2>&1 || {
    cat "$WORK_DIR/readme.out"; fail 'README installation command failed'
}
grep -Eq '^GH_PROXY=https://gh-proxy\.org/?$' "$WORK_DIR/readme-home/.env" || fail 'README proxy was not persisted'
grep -q '^CLASHCTL_UPDATE_BRANCH=main$' "$WORK_DIR/readme-home/.env" || fail 'README main branch was not persisted'
# 续装保留已保存的选项；显式参数优先，空代理可切回直连。
retry_home="$WORK_DIR/retry-options"
CLASHCTL_HOME="$retry_home" CLASHCTL_UPDATE_BRANCH=iu bash "$REPO_DIR/install.sh" --service auto --kernel clash --gh-proxy=https://old.proxy.test >"$WORK_DIR/options.out" 2>&1
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" bash "$retry_home/install.sh" --service auto >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'clash|iu|https://old.proxy.test' ] || fail 'retry lost saved options'
# 已有安装禁止切换内核，检查必须早于更新、配置写入和服务操作。
cp "$retry_home/.env" "$WORK_DIR/kernel-env.expected"
retry_head=$("$REAL_GIT" -C "$retry_home" rev-parse HEAD)
for kernel_form in equals separate; do
    kernel_args=(--kernel=mihomo)
    [ "$kernel_form" != separate ] || kernel_args=(--kernel mihomo)
    if FAIL_FETCH=1 CLASHCTL_HOME="$retry_home" \
        bash "$retry_home/install.sh" --service auto "${kernel_args[@]}" >"$WORK_DIR/kernel-change.out" 2>&1; then
        fail "existing installation changed kernel: $kernel_form"
    fi
    grep -q '已有安装不支持切换内核' "$WORK_DIR/kernel-change.out" || fail 'kernel change was not diagnosed before fetch'
    cmp -s "$retry_home/.env" "$WORK_DIR/kernel-env.expected" || fail 'kernel rejection modified config'
    [ "$("$REAL_GIT" -C "$retry_home" rev-parse HEAD)" = "$retry_head" ] || fail 'kernel rejection updated source'
    [ "$(cat "$retry_home/data/download-options")" = 'clash|iu|https://old.proxy.test' ] || fail 'kernel rejection downloaded components'
    [ ! -e "$retry_home/.clashctl-incomplete" ] || fail 'kernel rejection changed installation state'
done
(
    . "$REPO_DIR/scripts/lib/operation-lock.sh"
    operation_lock_acquire || fail 'could not hold retry lock'
    trap operation_lock_release EXIT
    if CLASHCTL_HOME="$retry_home" bash "$retry_home/install.sh" --service auto >"$WORK_DIR/locked-retry.out" 2>&1; then
        fail 'existing installation ignored held lock'
    fi
    grep -q '另一项 clashctl' "$WORK_DIR/locked-retry.out" || fail 'retry did not diagnose contention'
    cmp -s "$retry_home/.env" "$WORK_DIR/kernel-env.expected" || fail 'locked retry modified config'
    [ ! -e "$retry_home/.clashctl-incomplete" ] || fail 'locked retry changed installation state'
)
CLASHCTL_HOME="$retry_home" CLASHCTL_UPDATE_BRANCH=main GH_PROXY=https://env.proxy.test \
    bash "$retry_home/install.sh" --service auto --kernel clash --gh-proxy=https://new.proxy.test >"$WORK_DIR/options.out" 2>&1
[ "$(saved_options "$retry_home")" = 'clash|main|https://new.proxy.test' ] || fail 'saved options overrode retry arguments'
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" \
    bash "$retry_home/install.sh" --service auto --gh-proxy= >"$WORK_DIR/options.out" 2>&1
[ "$(saved_options "$retry_home")" = 'clash|main|' ] || fail 'retry could not clear proxy'
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" \
    bash "$retry_home/install.sh" --service auto >"$WORK_DIR/options.out" 2>&1
[ "$(saved_options "$retry_home")" = 'clash|main|' ] || fail 'retry options were not persisted'
CLASHCTL_HOME="$retry_home" CLASHCTL_DOWNLOAD_TIMEOUT=180 bash "$retry_home/install.sh" --service auto \
    >"$WORK_DIR/options.out" 2>&1
[ "$(saved_timeout "$retry_home")" = 180 ] || fail 'retry timeout was overridden by saved config'
env -u CLASHCTL_DOWNLOAD_TIMEOUT CLASHCTL_HOME="$retry_home" \
    bash "$retry_home/install.sh" --service auto >"$WORK_DIR/timeout-persisted.out" 2>&1
[ "$(saved_timeout "$retry_home")" = 180 ] || fail 'retry did not persist timeout override'
# 指向已有安装时，--install-dir 也必须决定更新目标，而不是环境变量或已保存的路径。
ignored_existing="$WORK_DIR/ignored-existing"
CLASHCTL_HOME="$ignored_existing" GH_PROXY=https://env.proxy.test \
    bash "$retry_home/install.sh" --service auto --install-dir "$retry_home" --gh-proxy=https://flag-existing.test \
    >"$WORK_DIR/existing-home.out" 2>&1 ||
    { cat "$WORK_DIR/existing-home.out"; fail 'home could not update existing installation'; }
[ "$(saved_options "$retry_home")" = 'clash|main|https://flag-existing.test' ] ||
    fail 'home did not update the selected installation'
[ ! -e "$ignored_existing" ] || fail 'existing installation update used CLASHCTL_HOME instead of home'
# 源码不能通过重试初始化获得安装身份；克隆真实安装也不会继承 Git 私有标记。
if CLASHCTL_HOME="$FIXTURE" bash "$FIXTURE/install.sh" --service auto >"$WORK_DIR/source-retry.out" 2>&1; then
    fail 'installer adopted source checkout as installation'
fi
[ ! -e "$FIXTURE/.clashctl-install" ] || fail 'installer marked source checkout'
[ ! -e "$FIXTURE/.env" ] || fail 'installer initialized source checkout'
# --local 取脚本所在目录的工作区，不依赖 cwd、Git 或源码下载。
local_source="$WORK_DIR/local-source"
local_home="$WORK_DIR/local-home"
cp -a "$FIXTURE" "$local_source"
printf 'fixture_version=uncommitted\n' >"$local_source/scripts/cmd/clashctl.sh"
printf 'local_helper=true\n' >"$local_source/scripts/local-helper.sh"
printf 'ignored.txt\n' >>"$local_source/.gitignore"
printf private >"$local_source/ignored.txt"
printf 'exit 99\n' >"$local_source/.env"
printf old-marker >"$local_source/.clashctl-install"
printf old-manifest >"$local_source/.clashctl-files"
mkdir -p "$local_source/data" "$local_source/bin" "$local_source/archives" "$local_source/resources/dist"
for file in data/private bin/private archives/private resources/dist/index.html resources/cache.db; do
    printf private >"$local_source/$file"
done
(
    cd "$WORK_DIR"
    FAIL_FETCH=1 FAIL_DOWNLOAD=1 CLASHCTL_HOME="$local_home" CLASHCTL_UPDATE_BRANCH=main \
        bash "$local_source/install.sh" --service auto --local --branch iu --gh-proxy=https://local.proxy.test
) >"$WORK_DIR/local.out" 2>&1 || { cat "$WORK_DIR/local.out"; fail 'local installation failed'; }
grep -qx 'fixture_version=uncommitted' "$local_home/scripts/cmd/clashctl.sh" || fail 'local edits were not installed'
[ -f "$local_home/scripts/local-helper.sh" ] || fail 'untracked source file was omitted'
for file in .git ignored.txt data/private bin/private archives/private resources/dist resources/cache.db; do
    [ ! -e "$local_home/$file" ] || fail "local installation copied $file"
done
grep -q '^CLASHCTL_UPDATE_BRANCH=iu$' "$local_home/.env" || fail 'local installation lost update branch'
[ "$(tail -n 1 "$local_home/.clashctl-install")" = archive ] || fail 'local installation did not reuse archive updates'
(cd "$local_home" && sha256sum --status -c .clashctl-files) || fail 'local manifest is invalid'
[ "$(cat "$local_source/.env")" = 'exit 99' ] || fail 'source environment changed'
[ "$(cat "$local_source/.clashctl-install")" = old-marker ] || fail 'source identity changed'
local_interrupted="$WORK_DIR/local-interrupted"
if FAIL_PREPARE=1 CLASHCTL_HOME="$local_interrupted" bash "$local_source/install.sh" --service auto --local \
    >"$WORK_DIR/local-interrupted.out" 2>&1; then
    fail 'interrupted local installation was accepted'
fi
printf 'fixture_version=after-interruption\n' >"$local_source/scripts/cmd/clashctl.sh"
CLASHCTL_HOME="$local_interrupted" bash "$local_source/install.sh" --service auto --local \
    >"$WORK_DIR/local-resume.out" 2>&1 ||
    { cat "$WORK_DIR/local-resume.out"; fail 'interrupted local installation did not resume'; }
grep -qx 'fixture_version=after-interruption' "$local_interrupted/scripts/cmd/clashctl.sh" ||
    fail 'local retry did not refresh copied program files'
grep -Fq '（本地源码）' "$WORK_DIR/local-resume.out" || fail 'missing local source indication'
awk '
    /继续未完成的安装/ { resumed = 1 }
    /应用本地源码更新/ { if (!resumed) exit 1; updated = 1 }
    END { if (!updated) exit 1 }
' "$WORK_DIR/local-resume.out" || fail 'local retry did not explain its state before refreshing source'
printf 'fixture_version=local-refresh\n' >"$local_source/scripts/cmd/clashctl.sh"
printf 'saved local data\n' >"$local_home/data/config.yaml"
# --local 更新与回滚同时失败时，外层退出清理不能删除内层保留的恢复备份。
local_failure_bin="$WORK_DIR/local-failure-bin"
mkdir "$local_failure_bin"
cat >"$local_failure_bin/tar" <<'LOCAL_TAR'
#!/usr/bin/env bash
if [ "${1:-}" = -xf ] && [ "${2:-}" = - ]; then
    cat >/dev/null
    printf 'partial=true\n' >"$LOCAL_UPDATE_PROGRAM"
    exit 1
fi
if [ "${1:-}" = -xf ] && [[ ${2:-} == */previous.tar ]] &&
    [ "${FAIL_LOCAL_RESTORE:-0}" = 1 ]; then
    exit 1
fi
exec "$REAL_TAR" "$@"
LOCAL_TAR
chmod +x "$local_failure_bin/tar"
real_tar=$(command -v tar)
cp "$local_home/scripts/cmd/clashctl.sh" "$WORK_DIR/local-program.before"
cp "$local_home/.clashctl-files" "$WORK_DIR/local-manifest.before"
cp "$local_home/.env" "$WORK_DIR/local-env.before"
for restore_failure in 0 1; do
    if PATH="$local_failure_bin:$PATH" REAL_TAR="$real_tar" \
        LOCAL_UPDATE_PROGRAM="$local_home/scripts/cmd/clashctl.sh" FAIL_LOCAL_RESTORE="$restore_failure" \
        CLASHCTL_HOME="$local_home" bash "$local_source/install.sh" --service auto --local \
        >"$WORK_DIR/local-failure.out" 2>&1; then
        fail 'partial local update reported success'
    fi
    recovery_directory=$(find "$WORK_DIR" -maxdepth 1 -type d -name 'local-home.update.*' -print -quit)
    if [ "$restore_failure" = 0 ]; then
        cmp "$WORK_DIR/local-program.before" "$local_home/scripts/cmd/clashctl.sh" || fail 'local rollback did not restore program'
        cmp "$WORK_DIR/local-manifest.before" "$local_home/.clashctl-files" || fail 'local rollback did not restore manifest'
        [ -z "$recovery_directory" ] || fail 'successful local rollback retained temporary source'
    else
        [ -n "$recovery_directory" ] && [ -f "$recovery_directory/keep" ] &&
            [ -s "$recovery_directory/previous.tar" ] || fail 'failed local rollback lost recovery backup'
        grep -Fq "$recovery_directory/previous.tar" "$WORK_DIR/local-failure.out" || fail 'failed local rollback did not identify backup'
        tar -xOf "$recovery_directory/previous.tar" ./scripts/cmd/clashctl.sh >"$WORK_DIR/local-program.saved"
        cmp "$WORK_DIR/local-program.before" "$WORK_DIR/local-program.saved" || fail 'recovery backup lost original program'
        tar -xOf "$recovery_directory/previous.tar" .clashctl-files >"$WORK_DIR/local-manifest.saved"
        cmp "$WORK_DIR/local-manifest.before" "$WORK_DIR/local-manifest.saved" || fail 'recovery backup lost original manifest'
        # 验证保留下来的备份可实际恢复，再继续成功更新的验收。
        tar -xf "$recovery_directory/previous.tar" -C "$local_home"
        rm -rf -- "$recovery_directory"
    fi
    cmp "$WORK_DIR/local-env.before" "$local_home/.env" || fail 'failed local update changed environment'
    [ "$(<"$local_home/data/config.yaml")" = 'saved local data' ] || fail 'failed local update changed user config'
done
CLASHCTL_HOME="$local_home" bash "$local_source/install.sh" --service auto --local >"$WORK_DIR/local-refresh.out" 2>&1 ||
    { cat "$WORK_DIR/local-refresh.out"; fail 'local archive update failed'; }
grep -q '更新现有安装' "$WORK_DIR/local-refresh.out" || fail 'existing installation reported as new'
grep -qx 'fixture_version=local-refresh' "$local_home/scripts/cmd/clashctl.sh" ||
    fail 'local archive source did not refresh'
[ "$(<"$local_home/data/config.yaml")" = 'saved local data' ] || fail 'local archive update changed data'
[ -z "$(find "$WORK_DIR" -maxdepth 1 -type d -name 'local-home.update.*' -print -quit)" ] ||
    fail 'successful local update retained temporary source'
# 上一版 current 布局自动切换时，始终使用新源码中的锁。
old_protocol_home="$WORK_DIR/old-protocol-home"
cp -a "$local_home" "$old_protocol_home"
printf '%s\narchive\n' "$old_protocol_home" >"$old_protocol_home/.clashctl-install"
for old_file in install.sh scripts/cmd/update.sh scripts/lib/operation-lock.sh; do
    "$REAL_GIT" -C "$REPO_DIR" show "HEAD:$old_file" >"$old_protocol_home/$old_file"
    case $old_file in
    scripts/lib/operation-lock.sh) printf '\nflock() { exit 91; }\n' >>"$old_protocol_home/$old_file" ;;
    *) printf '\nreturn 91 # 新安装器不可 source 安装目录里的旧安装器或更新器。\n' >>"$old_protocol_home/$old_file" ;;
    esac
    old_protocol_hash=$(sha256sum "$old_protocol_home/$old_file")
    old_protocol_hash=${old_protocol_hash%% *}
    sed -i "s|^[0-9a-f]*  ./$old_file$|$old_protocol_hash  ./$old_file|" "$old_protocol_home/.clashctl-files"
done
# 更新失败也必须沿用新安装器的退出清理，恢复旧文件并释放目录锁。
if PATH="$local_failure_bin:$PATH" REAL_TAR="$real_tar" \
    LOCAL_UPDATE_PROGRAM="$old_protocol_home/scripts/cmd/clashctl.sh" FAIL_LOCAL_RESTORE=0 \
    CLASHCTL_HOME="$old_protocol_home" bash "$local_source/install.sh" --service auto --local >"$WORK_DIR/old-protocol-failed.out" 2>&1; then
    fail 'old current partial update reported success'
fi
grep -q '原程序文件已恢复' "$WORK_DIR/old-protocol-failed.out" ||
    { cat "$WORK_DIR/old-protocol-failed.out"; fail 'old current update did not use the new rollback handler'; }
bash -c '. "$1"; operation_lock_acquire && trap operation_lock_release EXIT' _ "$REPO_DIR/scripts/lib/operation-lock.sh" ||
    fail 'old current failed update retained the new operation lock'
CLASHCTL_HOME="$old_protocol_home" bash "$local_source/install.sh" --service auto --local \
    >"$WORK_DIR/old-protocol-updated.out" 2>&1 ||
    { cat "$WORK_DIR/old-protocol-updated.out"; fail 'old current protocol did not migrate using the new lock'; }
grep -q '^_directory_lock_acquire()' "$old_protocol_home/scripts/lib/operation-lock.sh" ||
    fail 'old current protocol library was not replaced'
# 管道更新没有伴随库，必须先准备新源码，不能调用安装目录里的旧锁函数。
old_protocol_git="$WORK_DIR/old-protocol-git"
cp -a "$CLASHCTL_HOME" "$old_protocol_git"
printf '%s\ngit\n' "$old_protocol_git" >"$old_protocol_git/.clashctl-install"
for old_file in install.sh scripts/cmd/update.sh scripts/lib/operation-lock.sh; do
    "$REAL_GIT" -C "$REPO_DIR" show "HEAD:$old_file" >"$old_protocol_git/$old_file"
    case $old_file in
    scripts/lib/operation-lock.sh) printf '\nflock() { exit 91; }\n' >>"$old_protocol_git/$old_file" ;;
    *) printf '\nreturn 91 # 管道入口不可 source 旧安装器或更新器。\n' >>"$old_protocol_git/$old_file" ;;
    esac
done
"$REAL_GIT" -C "$old_protocol_git" config user.email test@example.invalid
"$REAL_GIT" -C "$old_protocol_git" config user.name test
"$REAL_GIT" -C "$old_protocol_git" add install.sh scripts/cmd/update.sh scripts/lib/operation-lock.sh
"$REAL_GIT" -C "$old_protocol_git" commit -qm old-lock-protocol
CLASHCTL_HOME="$old_protocol_git" bash -c 'cat "$1" | bash -s -- --service auto' _ "$REPO_DIR/install.sh" \
    >"$WORK_DIR/old-protocol-pipe.out" 2>&1 ||
    { cat "$WORK_DIR/old-protocol-pipe.out"; fail 'piped update reused the old installed lock implementation'; }
grep -q '^_directory_lock_acquire()' "$old_protocol_git/scripts/lib/operation-lock.sh" ||
    fail 'piped update did not replace the old protocol library'
[ -z "$(find "$WORK_DIR" -maxdepth 1 -type d -name 'old-protocol-git.download.*' -print -quit)" ] ||
    fail 'piped update retained bootstrap source'
bash "$local_home/uninstall.sh" --yes >"$WORK_DIR/local-uninstall.out" 2>&1 || fail 'local installation could not be uninstalled'
[ -f "$local_source/install.sh" ] || fail 'uninstall removed local source'

# 带旧身份标记的安装：先准备新源码，失败时恢复原目录，成功时备份旧目录。
legacy_v2="$WORK_DIR/legacy-v2-home"
recovery_root="$WORK_DIR/.clashctl-backups"
mkdir -p "$legacy_v2/scripts/lib" "$legacy_v2/data/profiles" "$legacy_v2/resources/dist"
cp "$FIXTURE/install.sh" "$legacy_v2/install.sh"
cp "$FIXTURE/scripts/preflight.sh" "$legacy_v2/scripts/preflight.sh"
cp "$FIXTURE/scripts/lib/common.sh" "$legacy_v2/scripts/lib/common.sh"
printf 'legacy config\n' >"$legacy_v2/data/config.yaml"
printf 'legacy profile\n' >"$legacy_v2/data/profiles/first.yaml"
printf 'legacy v2 cache\n' >"$legacy_v2/resources/cache.db"
printf 'legacy v2 dashboard\n' >"$legacy_v2/resources/dist/index.html"
printf 'CLASHCTL_KERNEL=mihomo\nCLASHCTL_UPDATE_BRANCH=iu\nGH_PROXY=https://legacy.proxy.test\nCLASHCTL_HOME=/old/path\nCLASHCTL_SRC=/old/path\n' >"$legacy_v2/.env"
printf 'CLASHCTL_INSTALLATION=clashctl\nCLASHCTL_INSTALLATION_FORMAT=1\nCLASHCTL_INSTALLATION_HOME=%s\nCLASHCTL_INSTALLATION_UID=%s\n' \
    "$legacy_v2" "$(id -u)" >"$legacy_v2/.clashctl-installation"
chmod 0600 "$legacy_v2/.clashctl-installation"
# 迁移也必须在停旧服务、复制数据和移动旧目录之前取得同一把锁。
(
    . "$REPO_DIR/scripts/lib/operation-lock.sh"
    operation_lock_acquire || fail 'could not hold migration lock'
    trap operation_lock_release EXIT
    tar -cf "$WORK_DIR/legacy-before-lock.tar" -C "$legacy_v2" .
    if CLASHCTL_HOME="$legacy_v2" bash "$local_source/install.sh" --service auto --local >"$WORK_DIR/locked-legacy.out" 2>&1; then
        fail 'legacy migration ignored held lock'
    fi
    grep -q '另一项 clashctl' "$WORK_DIR/locked-legacy.out" || fail 'migration did not diagnose contention'
    tar -df "$WORK_DIR/legacy-before-lock.tar" -C "$legacy_v2" || fail 'lock contention modified legacy installation'
    [ ! -e "$recovery_root" ] || fail 'locked migration created recovery directories'
    [ -z "$(find "$WORK_DIR" -maxdepth 1 -name 'legacy-v2-home.download.*' -print -quit)" ] || fail 'locked migration left staged source'
)
# 旧服务接管必须精确匹配旧二进制与配置路径；恢复时保留启用和运行状态。
(
    . "$REPO_DIR/install.sh"
    existing_kind='legacy-v2'
    unit_target="$WORK_DIR/legacy.service"
    unit_calls="$WORK_DIR/legacy-service.calls"
    printf 'ExecStart=%s/bin/mihomo -d %s/resources -f %s/data/runtime.yaml\n' \
        "$legacy_v2" "$legacy_v2" "$legacy_v2" >"$unit_target"
    cp "$unit_target" "$WORK_DIR/legacy.service.expected"
    detect_service_manager() { service_manager=systemd; }
    _service_target() { printf '%s\n' "$unit_target"; }
    systemctl() { printf '%s\n' "$*" >>"$unit_calls"; }
    _install_legacy_service_prepare "$legacy_v2" mihomo || fail 'owned legacy service was rejected'
    [ ! -e "$unit_target" ] || fail 'legacy service was not detached'
    _install_legacy_service_restore mihomo || fail 'legacy service restore failed'
    cmp -s "$unit_target" "$WORK_DIR/legacy.service.expected" || fail 'legacy service file changed after restore'
    grep -qx 'stop mihomo' "$unit_calls" || fail 'legacy service was not stopped'
    grep -qx 'start mihomo' "$unit_calls" || fail 'legacy service was not restarted'
    printf 'ExecStart=/usr/bin/unrelated\n' >"$unit_target"
    if _install_legacy_service_prepare "$legacy_v2" mihomo; then
        fail 'foreign service was adopted as legacy service'
    fi
    grep -qx 'ExecStart=/usr/bin/unrelated' "$unit_target" || fail 'foreign service was modified'
    mkdir "$WORK_DIR/rollback-current" "$WORK_DIR/rollback-backup"
    _service_definition_is_owned() { return 0; }
    uninstall_service() { return 1; }
    if _install_legacy_rollback "$WORK_DIR/rollback-old" "$WORK_DIR/rollback-backup" \
        "$WORK_DIR/rollback-current" mihomo; then
        fail 'rollback accepted a service that could not be stopped'
    fi
    [ -d "$WORK_DIR/rollback-current" ] && [ -d "$WORK_DIR/rollback-backup" ] ||
        fail 'failed service stop moved installation directories'
)
# 不安全的恢复路径必须在修改旧目录之前拒绝，也不能写入链接指向的目录。
rm -rf -- "$recovery_root"
mkdir "$WORK_DIR/recovery-outside"
printf 'keep outside data\n' >"$WORK_DIR/recovery-outside/sentinel"
unsafe_cases=(root-link root-file root-mode backups-link failed-link)
[ "$(id -u)" != 0 ] || unsafe_cases+=(foreign-owner)
for unsafe_case in "${unsafe_cases[@]}"; do
    case $unsafe_case in
    root-link) ln -s "$WORK_DIR/recovery-outside" "$recovery_root" ;;
    root-file) printf 'unrelated file\n' >"$recovery_root" ;;
    root-mode) mkdir -m 0755 "$recovery_root" ;;
    backups-link | failed-link)
        mkdir -m 0700 "$recovery_root"
        ln -s "$WORK_DIR/recovery-outside" "$recovery_root/${unsafe_case%-link}"
        ;;
    foreign-owner)
        mkdir -m 0700 "$recovery_root"
        chown 65534 "$recovery_root"
        ;;
    esac
    tar -cf "$WORK_DIR/legacy-before-recovery.tar" -C "$legacy_v2" .
    if CLASHCTL_HOME="$legacy_v2" bash "$local_source/install.sh" --service auto --local \
        >"$WORK_DIR/recovery-unsafe.out" 2>&1; then
        fail "migration accepted unsafe recovery directory: $unsafe_case"
    fi
    grep -q '恢复目录必须' "$WORK_DIR/recovery-unsafe.out" || fail 'unsafe recovery path was not diagnosed'
    tar -df "$WORK_DIR/legacy-before-recovery.tar" -C "$legacy_v2" || fail 'unsafe recovery path modified old installation'
    [ "$(find "$WORK_DIR/recovery-outside" -mindepth 1 | wc -l)" -eq 1 ] || fail 'unsafe recovery path wrote outside files'
    grep -qx 'keep outside data' "$WORK_DIR/recovery-outside/sentinel" || fail 'unsafe recovery path changed outside data'
    rm -rf -- "$recovery_root"
done
# 已有散落备份由用户管理；新迁移不搬动或删除它。
mkdir "$WORK_DIR/legacy-v2-home.bak.existing"
printf 'keep old backup\n' >"$WORK_DIR/legacy-v2-home.bak.existing/sentinel"
if FAIL_PREPARE=1 CLASHCTL_HOME="$legacy_v2" bash "$local_source/install.sh" --service auto --local >"$WORK_DIR/legacy-failed.out" 2>&1; then
    fail 'failed legacy migration was accepted'
fi
[ "$(<"$legacy_v2/data/config.yaml")" = 'legacy config' ] || fail 'failed migration lost old config'
[ -f "$legacy_v2/.clashctl-installation" ] || fail 'failed migration did not restore old marker'
# 显式分支在旧版迁移时也覆盖环境变量和旧 .env，并保存至新安装。
branch_migration_home="$WORK_DIR/branch-migration"
cp -a "$legacy_v2" "$branch_migration_home"
sed -i "s|^CLASHCTL_INSTALLATION_HOME=.*|CLASHCTL_INSTALLATION_HOME=$branch_migration_home|" \
    "$branch_migration_home/.clashctl-installation"
CLASHCTL_HOME="$branch_migration_home" CLASHCTL_UPDATE_BRANCH=legacy \
    bash "$local_source/install.sh" --service auto --local --branch main >"$WORK_DIR/branch-migration.out" 2>&1 ||
    { cat "$WORK_DIR/branch-migration.out"; fail 'branch selection during migration failed'; }
grep -q '^CLASHCTL_UPDATE_BRANCH=main$' "$branch_migration_home/.env" || fail 'migration did not persist branch flag'
[ "$(cat "$branch_migration_home/data/download-options")" = 'mihomo|main|https://legacy.proxy.test' ] || fail 'migration lost explicit branch'
CLASHCTL_HOME="$WORK_DIR/ignored-legacy-v2" bash "$local_source/install.sh" --service auto --kernel clash --local \
    --install-dir "$legacy_v2" >"$WORK_DIR/legacy-success.out" 2>&1 ||
    { cat "$WORK_DIR/legacy-success.out"; fail 'legacy v2 migration failed'; }
[ ! -e "$WORK_DIR/ignored-legacy-v2" ] || fail 'legacy v2 migration used CLASHCTL_HOME instead of home'
[ "$(<"$legacy_v2/data/config.yaml")" = 'legacy config' ] || fail 'legacy v2 config was not migrated'
[ "$(<"$legacy_v2/data/profiles/first.yaml")" = 'legacy profile' ] || fail 'legacy v2 profile was not migrated'
[ "$(<"$legacy_v2/resources/cache.db")" = 'legacy v2 cache' ] || fail 'legacy v2 runtime cache was not migrated'
[ "$(<"$legacy_v2/resources/dist/index.html")" = 'legacy v2 dashboard' ] || fail 'legacy v2 dashboard was not migrated'
[ -f "$legacy_v2/.clashctl-install" ] || fail 'legacy v2 did not gain current marker'
! grep -Eq '^CLASHCTL_(HOME|SRC)=' "$legacy_v2/.env" || fail 'legacy path overrides were retained'
[ "$(<"$legacy_v2/data/download-options")" = 'clash|iu|https://legacy.proxy.test' ] ||
    fail 'legacy v2 update options were not retained'
[ -n "$(find "$recovery_root/backups" -maxdepth 1 -name 'legacy-v2-home.*' -print -quit)" ] ||
    fail 'legacy v2 backup missing'
for directory in "$recovery_root" "$recovery_root/backups" "$recovery_root/failed"; do
    [ "$(stat -c %a "$directory")" = 700 ] || fail 'recovery directory exposes old credentials'
done
grep -qx 'keep old backup' "$WORK_DIR/legacy-v2-home.bak.existing/sentinel" || fail 'migration modified existing scattered backup'
[ "$(find "$WORK_DIR" -maxdepth 1 \( -name '*.bak.*' -o -name '*.failed.*' \) | wc -l)" -eq 1 ] ||
    fail 'migration left new scattered recovery directories'

# master 实际安装目录没有 install.sh 和 preflight.sh，只有运行脚本和用户数据。
# 模板故意设置不同代理，确认迁移沿用旧配置，不依赖当前模板的默认值。
printf '\nGH_PROXY=https://template.proxy.test\n' >>"$local_source/.env.example"
legacy_v1="$WORK_DIR/legacy-v1-home"
mkdir -p "$legacy_v1/scripts/lib" "$legacy_v1/scripts/cmd" \
    "$legacy_v1/resources/profiles" "$legacy_v1/resources/dist" \
    "$legacy_v1/resources/proxies" "$legacy_v1/resources/rules"
printf '#!/usr/bin/env bash\n' >"$legacy_v1/uninstall.sh"
printf '#!/usr/bin/env bash\n' >"$legacy_v1/scripts/cmd/clashctl.sh"
printf '#!/usr/bin/env bash\n' >"$legacy_v1/scripts/lib/service.sh"
printf 'CLASH_CONFIG_BASE="${CLASH_RESOURCES_DIR}/config.yaml"\nCLASH_PROFILES_DIR="${CLASH_RESOURCES_DIR}/profiles"\n' >"$legacy_v1/scripts/lib/common.sh"
printf 'export CLASHCTL_KERNEL=\047clash\047\nexport GH_PROXY=\047https://legacy.proxy.test\047\nCLASHCTL_SUB_TIMEOUT=31\nCLASHCTL_NODE_DELAY_URL=\047https://example.test/check?x=1&y=2\047\nCLASHCTL_SUB_UA="Custom Agent"\n' >"$legacy_v1/.env"
printf 'legacy v1 config\n' >"$legacy_v1/resources/config.yaml"
printf 'legacy v1 profile\n' >"$legacy_v1/resources/profiles/first.yaml"
printf 'legacy selected node\n' >"$legacy_v1/resources/cache.db"
printf 'legacy dashboard\n' >"$legacy_v1/resources/dist/index.html"
printf 'legacy proxy provider\n' >"$legacy_v1/resources/proxies/provider"
printf 'legacy rule provider\n' >"$legacy_v1/resources/rules/provider"
printf 'legacy subscription history\n' >"$legacy_v1/resources/profiles.log"
printf 'legacy failed subscription\n' >"$legacy_v1/resources/last-failed.raw"
printf 'profiles:\n  - name: first\n    path: %s/resources/profiles/first.yaml\nuse: first\n' \
    "$legacy_v1" >"$legacy_v1/resources/profiles.yaml"
[ ! -e "$legacy_v1/install.sh" ] && [ ! -e "$legacy_v1/scripts/preflight.sh" ] ||
    fail 'master runtime fixture contains source-only installer files'
mv "$legacy_v1/uninstall.sh" "$legacy_v1/uninstall.sh.saved"
if ( . "$REPO_DIR/install.sh"; _install_existing_kind "$legacy_v1" >/dev/null ); then
    fail 'master runtime without its uninstall script was accepted'
fi
mv "$legacy_v1/uninstall.sh.saved" "$legacy_v1/uninstall.sh"
legacy_user="$WORK_DIR/legacy-user"
mkdir -p "$legacy_user/.config/fish/conf.d"
printf 'export CLASHCTL_HOME=%q\n. $CLASHCTL_HOME/scripts/cmd/clashctl.sh\n' "$legacy_v1" >"$legacy_user/.bashrc"
printf "# clashctl shell-rc (managed by install.sh, do not edit)\nset -gx CLASHCTL_HOME '%s'\n" \
    "$legacy_v1" >"$legacy_user/.config/fish/conf.d/clashctl.fish"
cp -p "$legacy_user/.bashrc" "$WORK_DIR/legacy-user.bashrc"
cp -p "$legacy_user/.config/fish/conf.d/clashctl.fish" "$WORK_DIR/legacy-user.fish"
cp "$legacy_v1/.env" "$WORK_DIR/legacy-v1.env"
printf '%s\n' 'CLASHCTL_KERNEL=$(printf clash)' >"$legacy_v1/.env"
if HOME="$legacy_user" bash -c '. "$HOME/.bashrc"; bash "$1" --local --service auto' _ \
    "$local_source/install.sh" >"$WORK_DIR/v1-unsafe-kernel.out" 2>&1; then
    fail 'migration accepted a dynamic old kernel name'
fi
cmp -s "$legacy_user/.bashrc" "$WORK_DIR/legacy-user.bashrc" ||
    fail 'invalid old kernel changed shell configuration'
mv "$WORK_DIR/legacy-v1.env" "$legacy_v1/.env"
if HOME="$legacy_user" FAIL_RC=1 bash -c '. "$HOME/.bashrc"; bash "$1" --local --service auto' _ \
    "$local_source/install.sh" >"$WORK_DIR/v1-rc-failed.out" 2>&1; then
    fail 'legacy migration accepted failed shell integration'
fi
cmp -s "$legacy_user/.bashrc" "$WORK_DIR/legacy-user.bashrc" ||
    fail 'failed legacy migration changed shell configuration'
cmp -s "$legacy_user/.config/fish/conf.d/clashctl.fish" "$WORK_DIR/legacy-user.fish" ||
    fail 'failed legacy migration changed fish configuration'
[ -f "$legacy_v1/resources/config.yaml" ] && [ ! -e "$legacy_v1/.clashctl-install" ] ||
    fail 'failed legacy migration did not restore master runtime directory'
failed_v1=$(find "$recovery_root/failed" -maxdepth 1 -name 'legacy-v1-home.*' -print -quit)
[ -n "$failed_v1" ] && [ ! -e "$failed_v1/data/started" ] ||
    fail 'failed legacy migration left the new nohup service running'
# Shell 集成已写入时收到 TERM，迁移回滚必须恢复用户原有的 Bash/Fish 配置。
interrupt_v1="$WORK_DIR/interrupt-v1-home"
cp -a -- "$legacy_v1" "$interrupt_v1"
sed -i "s#$legacy_v1/resources/profiles/#$interrupt_v1/resources/profiles/#g" \
    "$interrupt_v1/resources/profiles.yaml"
interrupt_user="$WORK_DIR/interrupt-user"
mkdir -p "$interrupt_user/.config/fish/conf.d"
printf 'export CLASHCTL_HOME=%q\n. $CLASHCTL_HOME/scripts/cmd/clashctl.sh\n' \
    "$interrupt_v1" >"$interrupt_user/.bashrc"
printf "# clashctl shell-rc (managed by install.sh, do not edit)\nset -gx CLASHCTL_HOME '%s'\n" \
    "$interrupt_v1" >"$interrupt_user/.config/fish/conf.d/clashctl.fish"
cp -p "$interrupt_user/.bashrc" "$WORK_DIR/interrupt-user.bashrc"
cp -p "$interrupt_user/.config/fish/conf.d/clashctl.fish" "$WORK_DIR/interrupt-user.fish"
interrupt_shell_marker="$WORK_DIR/interrupt-shell-main.pid"
HOME="$interrupt_user" CLASHCTL_HOME="$interrupt_v1" INTERRUPT_AFTER_RC=1 \
    INTERRUPT_SHELL_MARKER="$interrupt_shell_marker" \
    bash "$local_source/install.sh" --service auto --local >"$WORK_DIR/interrupt-shell.out" 2>&1 &
interrupt_shell_launcher_pid=$!
for ((i=0; i<300; i++)); do
    [ ! -s "$interrupt_shell_marker" ] || break
    kill -0 "$interrupt_shell_launcher_pid" 2>/dev/null || break
    sleep 0.05
done
[ -s "$interrupt_shell_marker" ] || {
    cat "$WORK_DIR/interrupt-shell.out" >&2
    fail 'migration did not reach modified shell integration'
}
interrupt_shell_main_pid=$(cat "$interrupt_shell_marker")
[[ $interrupt_shell_main_pid =~ ^[0-9]+$ ]] || fail 'shell integration marker did not contain a PID'
! cmp -s "$interrupt_user/.bashrc" "$WORK_DIR/interrupt-user.bashrc" ||
    fail 'interrupt fixture did not modify Bash configuration'
! cmp -s "$interrupt_user/.config/fish/conf.d/clashctl.fish" "$WORK_DIR/interrupt-user.fish" ||
    fail 'interrupt fixture did not modify Fish configuration'
kill -TERM "$interrupt_shell_main_pid" || fail 'could not interrupt shell integration'
if wait "$interrupt_shell_launcher_pid"; then
    fail 'interrupted shell integration unexpectedly succeeded'
fi
interrupt_shell_launcher_pid=''
interrupt_shell_main_pid=''
cmp -s "$interrupt_user/.bashrc" "$WORK_DIR/interrupt-user.bashrc" ||
    fail 'TERM during shell integration did not restore Bash configuration'
cmp -s "$interrupt_user/.config/fish/conf.d/clashctl.fish" "$WORK_DIR/interrupt-user.fish" ||
    fail 'TERM during shell integration did not restore Fish configuration'
[ -f "$interrupt_v1/resources/config.yaml" ] && [ ! -e "$interrupt_v1/.clashctl-install" ] ||
    fail 'TERM during shell integration did not restore old installation'
# 迁移保留用户最后一次完成的订阅写入。
printf 'legacy v1 profile after update\n' >"$legacy_v1/resources/profiles/first.yaml"
HOME="$legacy_user" bash -c '. "$HOME/.bashrc"; bash "$1" --local --service auto' _ \
    "$local_source/install.sh" >"$WORK_DIR/v1-success.out" 2>&1 ||
    { cat "$WORK_DIR/v1-success.out"; fail 'legacy v1 migration failed'; }
legacy_v1_backup=$(find "$recovery_root/backups" -maxdepth 1 -name 'legacy-v1-home.*' -print -quit)
grep -q '原路径升级' "$WORK_DIR/v1-success.out" || fail 'in-place migration did not explain its path choice'
! grep -q '旧版目录:' "$WORK_DIR/v1-success.out" || fail 'in-place migration duplicated the installation path'
grep -Fq "旧版备份: $legacy_v1_backup" "$WORK_DIR/v1-success.out" || fail 'migration did not identify its backup'
awk '
    /安装完成/ { completed = 1 }
    /旧版备份:/ { if (!completed) exit 1; backed_up = 1 }
    /在当前终端执行/ { if (!backed_up) exit 1; guided = 1 }
    END { if (!guided) exit 1 }
' "$WORK_DIR/v1-success.out" || fail 'migration backup was not shown between completion and guidance'
[ "$(<"$legacy_v1/data/config.yaml")" = 'legacy v1 config' ] || fail 'legacy v1 config was not migrated'
[ "$(<"$legacy_v1/data/profiles/first.yaml")" = 'legacy v1 profile after update' ] ||
    fail 'migration did not preserve the latest profile'
[ "$(<"$legacy_v1/data/download-options")" = 'clash|main|https://legacy.proxy.test' ] ||
    fail 'quoted/exported old kernel or proxy was not migrated'
for file in resources/cache.db resources/dist/index.html resources/proxies/provider resources/rules/provider; do
    cmp "$legacy_v1_backup/$file" "$legacy_v1/$file" || fail "legacy runtime resource was not migrated: $file"
done
cmp "$legacy_v1_backup/resources/profiles.log" "$legacy_v1/data/profiles.log" ||
    fail 'legacy subscription history was not migrated'
cmp "$legacy_v1_backup/resources/last-failed.raw" "$legacy_v1/data/last-failed.raw" ||
    fail 'legacy subscription debug output was not migrated'
grep -Fqx "    path: $legacy_v1/data/profiles/first.yaml" "$legacy_v1/data/profiles.yaml" ||
    fail 'legacy v1 profile metadata still points to resources'
grep -q '^CLASHCTL_SUB_TIMEOUT=31$' "$legacy_v1/.env" || fail 'legacy user option was not migrated'
grep -Fqx "CLASHCTL_NODE_DELAY_URL='https://example.test/check?x=1&y=2'" "$legacy_v1/.env" ||
    fail 'quoted legacy URL was not migrated'
grep -Fqx 'CLASHCTL_SUB_UA="Custom Agent"' "$legacy_v1/.env" ||
    fail 'quoted legacy user agent was not migrated'
legacy_unsafe_user="$WORK_DIR/legacy-unsafe-user"
mkdir -p "$legacy_unsafe_user"
cp -a -- "$legacy_v1_backup" "$legacy_unsafe_user/clashctl"
chmod g+w "$legacy_unsafe_user/clashctl/scripts/cmd/clashctl.sh"
if env -u CLASHCTL_HOME HOME="$legacy_unsafe_user" bash "$local_source/install.sh" --service auto --local \
    >"$WORK_DIR/v1-unsafe-default.out" 2>&1; then
    fail 'unsafe old default directory was silently skipped'
fi
grep -q '无法安全确认' "$WORK_DIR/v1-unsafe-default.out" ||
    fail 'unsafe old default directory did not explain why migration stopped'
[ -f "$legacy_unsafe_user/clashctl/resources/config.yaml" ] && [ ! -e "$legacy_unsafe_user/.clashctl" ] ||
    fail 'unsafe old default directory was modified or shadowed by a new installation'
current_default_user="$WORK_DIR/current-default-user"
current_old_home="$current_default_user/clashctl"
mkdir -p "$current_old_home/scripts/lib"
printf '#!/usr/bin/env bash\n' >"$current_old_home/install.sh"
printf '#!/usr/bin/env bash\n' >"$current_old_home/scripts/preflight.sh"
printf '#!/usr/bin/env bash\n' >"$current_old_home/scripts/lib/common.sh"
printf '%s\narchive\n' "$current_old_home" >"$current_old_home/.clashctl-install"
chmod 0600 "$current_old_home/.clashctl-install"
if env -u CLASHCTL_HOME HOME="$current_default_user" bash "$local_source/install.sh" --service auto --local \
    >"$WORK_DIR/current-default.out" 2>&1; then
    fail 'current installation at old default path was silently shadowed'
fi
grep -q '已在旧默认路径发现新版安装' "$WORK_DIR/current-default.out" ||
    fail 'current installation at old default path lacks an actionable diagnosis'
[ ! -e "$current_default_user/.clashctl" ] || fail 'current old-path installation gained a duplicate'
legacy_default_user="$WORK_DIR/legacy-default-user"
mkdir -p "$legacy_default_user"
cp -a -- "$legacy_v1_backup" "$legacy_default_user/clashctl"
sed -i "s#$legacy_v1/resources/profiles/#$legacy_default_user/clashctl/resources/profiles/#g" \
    "$legacy_default_user/clashctl/resources/profiles.yaml"
env -u CLASHCTL_HOME HOME="$legacy_default_user" bash "$local_source/install.sh" --service auto --local \
    >"$WORK_DIR/v1-default.out" 2>&1 ||
    { cat "$WORK_DIR/v1-default.out"; fail 'historical default directory was not migrated'; }
grep -q '迁移旧版安装' "$WORK_DIR/v1-default.out" || fail 'migration reported as new'
grep -Fq "安装目录: $legacy_default_user/.clashctl" "$WORK_DIR/v1-default.out" || fail 'default home not shown'
[ "$(<"$legacy_default_user/.clashctl/data/config.yaml")" = 'legacy v1 config' ] ||
    fail 'historical default config was not migrated'
grep -Fqx "    path: $legacy_default_user/.clashctl/data/profiles/first.yaml" \
    "$legacy_default_user/.clashctl/data/profiles.yaml" ||
    fail 'default-path migration retained old profile path'
default_backup=$(find "$legacy_default_user/.clashctl-backups/backups" -maxdepth 1 -name 'clashctl.*' -print -quit)
[ -n "$default_backup" ] ||
    fail 'historical default directory was not backed up'
# 卸载新版后，外部恢复资料仍可搬回旧路径，实现实际回退。
bash "$legacy_default_user/.clashctl/uninstall.sh" --yes >"$WORK_DIR/default-uninstall.out" 2>&1 ||
    fail 'migrated default installation could not be uninstalled'
[ ! -e "$legacy_default_user/.clashctl" ] && [ -f "$default_backup/resources/config.yaml" ] ||
    fail 'uninstall removed recovery backup'
grep -Fq "恢复资料已保留，确认无需回退后可手动清理：$legacy_default_user/.clashctl-backups" \
    "$WORK_DIR/default-uninstall.out" || fail 'uninstall did not identify preserved recovery data'
mv -T -- "$default_backup" "$legacy_default_user/clashctl"
cmp "$legacy_v1_backup/resources/config.yaml" "$legacy_default_user/clashctl/resources/config.yaml" ||
    fail 'grouped backup could not restore old config'

if CLASHCTL_HOME="$local_source/nested" bash "$local_source/install.sh" --service auto --local >"$WORK_DIR/local-nested.out" 2>&1; then
    fail 'local installation accepted a destination inside its source'
fi
[ ! -e "$local_source/nested" ] || fail 'nested local installation changed source'
# shellcheck disable=SC2002  # 验证管道输入缺少本地源码路径时的错误。
if cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$WORK_DIR/local-pipe" bash -s -- --service auto --local >"$WORK_DIR/local-pipe.out" 2>&1; then
    fail 'local installation accepted pipeline input'
fi
grep -q '不支持管道输入' "$WORK_DIR/local-pipe.out" || fail 'missing local pipeline diagnosis'
printf 'broken() {\n' >"$local_source/scripts/local-helper.sh"
if CLASHCTL_HOME="$local_home" bash "$local_source/install.sh" --service auto --local >"$WORK_DIR/local-broken.out" 2>&1; then
    fail 'local installation accepted broken source'
fi
[ ! -e "$local_home" ] || fail 'invalid local source left an installation'
"$REAL_GIT" clone -q "$CLASHCTL_HOME" "$WORK_DIR/cloned-install"
[ ! -e "$WORK_DIR/cloned-install/.clashctl-install" ] || fail 'Git clone inherited installation identity'
if CLASHCTL_HOME="$WORK_DIR/cloned-install" bash "$WORK_DIR/cloned-install/uninstall.sh" --yes >"$WORK_DIR/cloned-uninstall.out" 2>&1; then
    fail 'cloned installation was accepted for uninstall'
fi
[ -f "$WORK_DIR/cloned-install/install.sh" ] || fail 'cloned installation was removed'
printf 'fixture_version=auto-updated\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
"$REAL_GIT" -C "$FIXTURE" commit -qam auto-updated
printf 'user data preserved\n' >"$CLASHCTL_HOME/data/config.yaml"
bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/existing.out" 2>&1 || {
    cat "$WORK_DIR/existing.out"; fail 'existing installation was not updated'
}
grep -qx 'fixture_version=auto-updated' "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ||
    fail 'installer did not refresh existing program files'
[ "$(<"$CLASHCTL_HOME/data/config.yaml")" = 'user data preserved' ] ||
    fail 'installer changed existing user data'
chmod 0644 "$CLASHCTL_HOME/.clashctl-install"
if bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/unsafe-marker.out" 2>&1; then
    fail 'installer accepted a writable installation marker'
fi
chmod 0600 "$CLASHCTL_HOME/.clashctl-install"
mv "$CLASHCTL_HOME/.env" "$CLASHCTL_HOME/.env.saved"
ln -s .env.saved "$CLASHCTL_HOME/.env"
if bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/unsafe-env.out" 2>&1; then
    fail 'installer accepted a symlinked environment file'
fi
rm "$CLASHCTL_HOME/.env"
mv "$CLASHCTL_HOME/.env.saved" "$CLASHCTL_HOME/.env"
if FAIL_FETCH=1 CLASHCTL_HOME="$WORK_DIR/failed" bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/failed.out" 2>&1; then
    fail 'download failure succeeded'
fi
[ ! -e "$WORK_DIR/failed" ] || fail 'download failure installed a partial tree'
# 路径先规范化再登记；含 . 或 .. 的路径不能绕过根目录和 HOME 限制。
for unsafe_home in /tmp/.. "$HOME/./"; do
    if CLASHCTL_HOME="$unsafe_home" bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/unsafe-home.out" 2>&1; then
        fail 'installer accepted root or HOME through path aliases'
    fi
    grep -q '不能使用根目录或用户主目录' "$WORK_DIR/unsafe-home.out" || fail 'unsafe path was not rejected before cloning'
done
CLASHCTL_HOME="$WORK_DIR/unused/../normalized" bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/normalized.out" 2>&1
[ "$(head -n 1 "$WORK_DIR/normalized/.clashctl-install")" = "$WORK_DIR/normalized" ] || fail 'marker did not use physical installation path'
bash "$WORK_DIR/normalized/uninstall.sh" --yes >"$WORK_DIR/normalized-uninstall.out" 2>&1
[ ! -e "$WORK_DIR/normalized" ] || fail 'normalized installation could not be uninstalled'
# 未完成安装仍需启动；完整重装则保留停止状态。
: >"$CLASHCTL_HOME/.clashctl-incomplete"
printf main-config >"$CLASHCTL_HOME/data/config.yaml"
rm -f "$CLASHCTL_HOME/data/started"
if FAIL_START=1 bash "$CLASHCTL_HOME/install.sh" --service auto >"$WORK_DIR/start-failed.out" 2>&1; then
    fail 'service failure succeeded'
fi
! grep -q '安装完成' "$WORK_DIR/start-failed.out" || fail 'service failure reported success'
[ -f "$CLASHCTL_HOME/.clashctl-incomplete" ] || fail 'failed initialization lost incomplete marker'
bash "$CLASHCTL_HOME/install.sh" --service auto >"$WORK_DIR/retry.out" 2>&1
[ -f "$CLASHCTL_HOME/data/started" ] || fail 'root installer could not retry initialization'
[ ! -e "$CLASHCTL_HOME/.clashctl-incomplete" ] || fail 'retry retained incomplete marker'

# 不兼容分支必须在落位和初始化前拒绝，不能留下半成品目录。
if CLASHCTL_UPDATE_BRANCH=legacy CLASHCTL_HOME="$WORK_DIR/legacy" bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/legacy.out" 2>&1; then
    fail 'incompatible source was installed'
fi
[ ! -e "$WORK_DIR/legacy" ] || fail 'incompatible source created an installation'
grep -q '源码不兼容' "$WORK_DIR/legacy.out" || fail 'missing incompatible branch diagnosis'
! grep -q 'command not found' "$WORK_DIR/legacy.out" || fail 'incompatible source reached initialization'
# 左侧命令的环境变量不影响安装器，取源分支以右侧 bash 的环境为准。
# shellcheck disable=SC2002  # 验证真实管道两侧的环境变量作用域
CLASHCTL_UPDATE_BRANCH=legacy cat "$REPO_DIR/install.sh" | CLASHCTL_UPDATE_BRANCH=iu CLASHCTL_HOME="$WORK_DIR/iu" bash -s -- --service auto >"$WORK_DIR/iu.out" 2>&1
[ "$("$REAL_GIT" -C "$WORK_DIR/iu" branch --show-current)" = iu ] || fail 'pipeline cloned the wrong branch'
grep -q '^CLASHCTL_UPDATE_BRANCH=iu$' "$WORK_DIR/iu/.env" || fail 'pipeline did not persist selected branch'

# 控制终端与脚本 stdin 分离：交互输入和显式订阅共用 PTY 驱动。
# 继承前面设置的 Git 桩，将源码请求重定向到本地 fixture。
TEST_REPO="$REPO_DIR" TEST_WORK="$WORK_DIR" python3 - <<'PTY'
import errno, os, pty, select, signal, time
work = os.environ["TEST_WORK"]
prompt = "订阅链接（回车跳过）: ".encode()

def install_in_terminal(name, args=(), subscription=None):
    home = work + "/" + name
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.pop("CI", None)
        os.environ["CLASHCTL_HOME"] = home
        os.environ["CLASHCTL_UPDATE_BRANCH"] = "main"
        os.environ["TERM"] = "xterm-256color"
        os.environ["INPUTRC"] = "/dev/null"
        os.execvp("bash", ["bash", "-c",
                  'cat "$TEST_REPO/install.sh" | bash -s -- --service auto "$@"',
                  "terminal-install", *args])
    output, sent, status = b"", False, None
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                output += chunk
                if subscription is not None and not sent and prompt in output:
                    data = subscription if isinstance(subscription, bytes) else subscription.encode() + b"\n"
                    os.write(fd, data)
                    sent = True
            child, child_status = os.waitpid(pid, os.WNOHANG)
            if child:
                status = child_status
                break
        # PTY 关闭可能早于子进程可回收；仍受同一个截止时间约束。
        while status is None and time.monotonic() < deadline:
            child, child_status = os.waitpid(pid, os.WNOHANG)
            if child:
                status = child_status
                break
            time.sleep(0.01)
        assert status is not None, "TTY installation timed out: " + output.decode(errors="replace")
        assert os.waitstatus_to_exitcode(status) == 0, output.decode(errors="replace")
        return home, output, sent
    finally:
        if status is None:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except ProcessLookupError:
                pass
        os.close(fd)

home, output, sent = install_in_terminal("tty-install", subscription="file:///private-subscription")
assert sent, "subscription prompt missing"
assert os.path.isfile(home + "/data/started")
assert not os.path.exists(home + "/data/enabled"), "nohup installation enabled a service"
assert output.count(b"file:///private-subscription") == 1, "subscription input was not shown exactly once"
assert "在当前终端执行（bash）:".encode() in output, "missing shell activation heading"
assert b'clashctl sub add --use "<URL>"' not in output, "configured installation suggested adding a subscription"
assert "启用当前终端代理".encode() in output, "missing proxy activation heading"
assert b"clashctl on" in output, "missing proxy activation step"
with open(home + "/data/subscription") as saved:
    assert saved.read() == "file:///private-subscription"

# 安装器从 /dev/tty 读取时，同样支持粘贴、方向键编辑，以及回车/EOF 跳过。
for name, data, expected in [
    ("paste", b"\x1b[200~file:///pasted?token=a&b=2\x1b[201~\n", "file:///pasted?token=a&b=2"),
    ("arrow", b"file:///sb\x1b[Du\n", "file:///sub"),
    ("empty", b"\n", None),
    ("eof", b"\x04", None),
]:
    test_home, _, sent = install_in_terminal("tty-" + name, subscription=data)
    assert sent, name + ": subscription prompt missing"
    saved = test_home + "/data/subscription"
    if expected is None:
        assert not os.path.exists(saved), name + ": skipped input added a subscription"
        assert os.path.isfile(test_home + "/data/started"), name + ": skipped input did not start direct kernel"
        assert os.path.getsize(test_home + "/data/config.yaml") == 0, name + ": skipped input created a fake subscription"
    else:
        with open(saved) as file:
            assert file.read() == expected, name + ": incorrect subscription URL"

# 已有配置的重复安装不能再次询问或覆盖订阅，保留停止状态。
os.remove(home + "/data/started")
home, output, _ = install_in_terminal("tty-install")
assert prompt not in output, "configured installation prompted again"
assert not os.path.exists(home + "/data/started"), "reinstallation started a stopped kernel"
with open(home + "/data/subscription") as saved:
    assert saved.read() == "file:///private-subscription", "repeat installation changed the subscription"

# 即便已有配置，显式 --sub 仍应添加并启用指定订阅。
home, output, _ = install_in_terminal("tty-install", ["--sub", "file:///replacement"])
assert prompt not in output, "explicit subscription prompted again"
with open(home + "/data/subscription") as saved:
    assert saved.read() == "file:///replacement", "existing configuration ignored --sub"

# 显式订阅和内核参数从管道入口传入，有控制终端时也不能再提示输入。
home, output, _ = install_in_terminal("tty-option-install",
                                     ["--kernel", "clash", "--sub", "file:///from-flag"])
assert prompt not in output, "flag installation prompted for a subscription"
with open(home + "/data/subscription") as saved:
    assert saved.read() == "file:///from-flag"
with open(home + "/data/download-options") as saved:
    assert saved.read().startswith("clash|main|")
PTY

. "$REPO_DIR/scripts/cmd/update.sh"
. "$REPO_DIR/scripts/lib/operation-lock.sh"
gh_proxy_url() { printf '%s\n' "$1"; }
_ui_step() { :; }
_ui_error() { printf '%s\n' "$*" >&2; }
_ui_info() { printf '%s\n' "$*"; }
_ui_ok() { :; }
_ui_ok_out() { printf '%s\n' "$*"; }
CLASHCTL_UPDATE_BRANCH=main
printf 'user config' >"$CLASHCTL_HOME/data/config.yaml"
cp "$CLASHCTL_HOME/.env" "$WORK_DIR/env.before"
printf 'fixture_version=new\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
"$REAL_GIT" -C "$FIXTURE" commit -qam update
clashupdate >"$WORK_DIR/update.out" 2>&1
# shellcheck disable=SC2154  # 更新后的加载器赋值
[ "$fixture_version" = new ] || fail 'current shell did not load update'
[ "$(cat "$CLASHCTL_HOME/data/config.yaml")" = 'user config' ] || fail 'update changed config'
[ "$(cat "$CLASHCTL_HOME/bin/kernel")" = kernel ] || fail 'update changed kernel'
cmp "$WORK_DIR/env.before" "$CLASHCTL_HOME/.env" || fail 'update changed environment'
[ "$(head -n 1 "$CLASHCTL_HOME/.clashctl-install")" = "$CLASHCTL_HOME" ] || fail 'update lost installation marker'
# 标记完整时不得重写：截断后被掉电/满盘打断会留下空标记，更新与卸载双双死锁。
printf '%s\ngit\n' "$CLASHCTL_HOME" >"$CLASHCTL_HOME/.clashctl-install"
touch -d '2 seconds ago' "$CLASHCTL_HOME/.clashctl-install"
marker_mtime=$(stat -c %Y "$CLASHCTL_HOME/.clashctl-install")
clashupdate >"$WORK_DIR/marker-intact.out" 2>&1 || fail 'update failed with a healthy marker'
[ "$(stat -c %Y "$CLASHCTL_HOME/.clashctl-install")" = "$marker_mtime" ] ||
    fail 'update rewrote an intact installation marker'
# 空标记（半截写入的残留）必须指出具体文件，便于用户排查。
printf '' >"$CLASHCTL_HOME/.clashctl-install"
if clashupdate >"$WORK_DIR/marker-empty.out" 2>&1; then fail 'empty installation marker was accepted'; fi
grep -q '安装标记为空' "$WORK_DIR/marker-empty.out" || fail 'empty marker had no diagnosis'
grep -qF "$CLASHCTL_HOME/.clashctl-install" "$WORK_DIR/marker-empty.out" || fail 'empty marker diagnosis did not name the file'
printf '%s\ngit\n' "$CLASHCTL_HOME" >"$CLASHCTL_HOME/.clashctl-install"
# 无 Git 和 flock 的真实 PATH：下载器只复制本地 tar 包，其余使用系统工具。
no_git_bin="$WORK_DIR/no-git-bin"
mkdir "$no_git_bin"
for tool in install bash cat dirname readlink mkdir mktemp rm rmdir mv tar gzip unzip sha256sum find sort xargs chmod cp head stat sleep touch grep sed awk id; do
    ln -s "$(command -v "$tool")" "$no_git_bin/$tool"
done
PATH="$no_git_bin" bash -c '! command -v flock >/dev/null 2>&1' || fail 'archive fixture unexpectedly provides flock'
export SOURCE_ARCHIVE="$WORK_DIR/source.tar.gz" DOWNLOAD_LOG="$WORK_DIR/download.log"
cat >"$no_git_bin/curl" <<'DOWNLOAD'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$DOWNLOAD_LOG"
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
while [ "$#" -gt 0 ]; do
    case "$1" in -o | -O) destination=$2; shift ;; esac
    shift
done
cp "$SOURCE_ARCHIVE" "$destination"
DOWNLOAD
chmod +x "$no_git_bin/curl"
cp "$no_git_bin/curl" "$no_git_bin/wget"
archive_source="$WORK_DIR/archive-source"
mkdir "$archive_source"
"$REAL_GIT" -C "$FIXTURE" archive HEAD | tar -x -C "$archive_source"
printf 'obsolete=true\n' >"$archive_source/scripts/obsolete.sh"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
archive_home="$WORK_DIR/archive-home"
PATH="$no_git_bin" CLASHCTL_HOME="$archive_home" CLASHCTL_UPDATE_BRANCH=legacy GH_PROXY=https://proxy.example \
    bash "$REPO_DIR/install.sh" --service auto --branch main >"$WORK_DIR/archive-install.out" 2>&1 || { cat "$WORK_DIR/archive-install.out"; fail 'curl fallback install failed'; }
[ ! -e "$archive_home/.git" ] || fail 'fallback created a Git repository'
[ "$(tail -n 1 "$archive_home/.clashctl-install")" = archive ] || fail 'archive type was not recorded'
[ -s "$archive_home/.clashctl-files" ] || fail 'archive file manifest missing'
grep -Fq 'https://proxy.example/https://github.com/HolyDDL/clashctl-daemon/archive/refs/heads/main.tar.gz' "$DOWNLOAD_LOG" || fail 'source archive ignored proxy or branch'
# wget 只负责拉取源码，此处初始化桩不依赖 curl。
mv "$no_git_bin/curl" "$WORK_DIR/saved-curl"
PATH="$no_git_bin" CLASHCTL_HOME="$WORK_DIR/wget-home" GH_PROXY='' \
    bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/wget-install.out" 2>&1 || { cat "$WORK_DIR/wget-install.out"; fail 'wget fallback install failed'; }
grep -q '^wget ' "$DOWNLOAD_LOG" || fail 'wget fallback was not used'
mv "$WORK_DIR/saved-curl" "$no_git_bin/curl"
# Git 存在但失败时不能偷偷回退下载。
before_downloads=$(wc -l <"$DOWNLOAD_LOG")
ln -s "$WORK_DIR/bin/git" "$no_git_bin/git"
if PATH="$no_git_bin" FAIL_FETCH=1 CLASHCTL_HOME="$WORK_DIR/git-failed" bash "$REPO_DIR/install.sh" --service auto >"$WORK_DIR/git-failed.out" 2>&1; then fail 'Git failure succeeded'; fi
[ "$(wc -l <"$DOWNLOAD_LOG")" = "$before_downloads" ] || fail 'Git failure fell back to archive'
rm "$no_git_bin/git"
if PATH="$no_git_bin" FAIL_DOWNLOAD=1 CLASHCTL_HOME="$WORK_DIR/archive-failed" bash "$REPO_DIR/install.sh" --service auto >/dev/null 2>&1; then fail 'archive download failure succeeded'; fi
[ ! -e "$WORK_DIR/archive-failed" ] || fail 'failed download created installation'

archive_update() (
    export CLASHCTL_HOME="$archive_home" PATH="$no_git_bin"
    . "$archive_home/scripts/cmd/update.sh"
    clashupdate >"$WORK_DIR/archive-update.out" 2>&1 || return
    printf '%s\n' "$fixture_version" >"$WORK_DIR/archive-version"
)
printf keep-config >"$archive_home/data/config.yaml"
mkdir -p "$archive_home/resources/dist" "$archive_home/archives"
printf keep-ui >"$archive_home/resources/dist/index.html"
printf keep-cache >"$archive_home/resources/cache.db"
printf keep-archive >"$archive_home/archives/kernel.gz"
cp "$archive_home/.env" "$WORK_DIR/archive.env.before"
cp "$archive_home/.clashctl-install" "$WORK_DIR/archive.marker.before"
cp "$archive_home/.clashctl-files" "$WORK_DIR/archive.manifest.before"
rm "$archive_source/scripts/obsolete.sh"
printf 'new_helper=true\n' >"$archive_source/scripts/new-helper.sh"
printf 'fixture_version=archive-new\n' >"$archive_source/scripts/cmd/clashctl.sh"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
# 本地修改与非托管文件冲突都应在替换前拒绝。
printf 'local-change=true\n' >>"$archive_home/scripts/obsolete.sh"
if archive_update; then fail 'archive update overwrote modified code'; fi
printf 'obsolete=true\n' >"$archive_home/scripts/obsolete.sh"
printf 'user-file=true\n' >"$archive_home/scripts/new-helper.sh"
if archive_update; then fail 'archive update overwrote unmanaged file'; fi
rm "$archive_home/scripts/new-helper.sh"
# 模拟写入阶段中途失败，必须恢复旧程序文件与旧清单。
(
    tar() {
        if [ "${1:-}" = -xf ] && [ "${2:-}" = - ]; then
            cat >/dev/null
            printf 'partial=true\n' >"$archive_home/scripts/cmd/clashctl.sh"
            printf 'partial=true\n' >"$archive_home/scripts/new-helper.sh"
            return 1
        fi
        command tar "$@"
    }
    if archive_update; then fail 'partial archive write reported success'; fi
)
grep -qx 'fixture_version=new' "$archive_home/scripts/cmd/clashctl.sh" || fail 'failed update did not restore code'
[ ! -e "$archive_home/scripts/new-helper.sh" ] || fail 'failed update retained new file'
cmp "$WORK_DIR/archive.manifest.before" "$archive_home/.clashctl-files" || fail 'failed update lost old manifest'
# 后续系统装上 Git，压缩包安装仍使用原方式更新。
cat >"$no_git_bin/git" <<'GIT'
#!/usr/bin/env bash
exit 97
GIT
chmod +x "$no_git_bin/git"
archive_update || { cat "$WORK_DIR/archive-update.out"; fail 'archive update failed'; }
[ "$(cat "$WORK_DIR/archive-version")" = archive-new ] || fail 'archive update did not reload shell'
[ ! -e "$archive_home/scripts/obsolete.sh" ] || fail 'obsolete script survived archive update'
[ ! -e "$archive_home/.git" ] || fail 'archive install changed type after Git appeared'
[ "$(cat "$archive_home/data/config.yaml")" = keep-config ] || fail 'archive update changed subscription'
[ "$(cat "$archive_home/resources/dist/index.html")" = keep-ui ] || fail 'archive update changed UI'
[ "$(cat "$archive_home/resources/cache.db")" = keep-cache ] || fail 'archive update changed runtime cache'
[ "$(cat "$archive_home/archives/kernel.gz")" = keep-archive ] || fail 'archive update changed archives'
[ "$(cat "$archive_home/bin/kernel")" = kernel ] || fail 'archive update changed kernel'
cmp "$WORK_DIR/archive.env.before" "$archive_home/.env" || fail 'archive update changed environment'
cmp "$WORK_DIR/archive.marker.before" "$archive_home/.clashctl-install" || fail 'archive update changed identity'
# 下载失败、语法错误、保留目录和越界/链接归档不得影响已安装文件。
cp "$archive_home/.clashctl-files" "$WORK_DIR/archive.manifest.after"
if FAIL_DOWNLOAD=1 archive_update; then fail 'failed archive update download succeeded'; fi
printf 'broken() {\n' >"$archive_source/scripts/new-helper.sh"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
if archive_update; then fail 'archive update accepted syntax error'; fi
printf 'new_helper=true\n' >"$archive_source/scripts/new-helper.sh"
mkdir "$archive_source/data"
printf forbidden >"$archive_source/data/config.yaml"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
if archive_update; then fail 'archive update accepted user data paths'; fi
rm -rf "$archive_source/data"
python3 - "$WORK_DIR" <<'BAD_ARCHIVES'
import io, sys, tarfile
from pathlib import Path
root=Path(sys.argv[1])
for kind in ['traversal','symlink','hardlink']:
    with tarfile.open(root/(kind+'.tar.gz'),'w:gz') as archive:
        item=tarfile.TarInfo('source/../../escaped' if kind=='traversal' else 'source/link')
        if kind=='traversal':
            item.size=3
            archive.addfile(item,io.BytesIO(b'bad'))
        else:
            item.type=tarfile.SYMTYPE if kind=='symlink' else tarfile.LNKTYPE
            item.linkname=str(root/'escaped')
            archive.addfile(item)
BAD_ARCHIVES
for kind in traversal symlink hardlink; do
    if SOURCE_ARCHIVE="$WORK_DIR/$kind.tar.gz" archive_update; then fail "accepted $kind archive"; fi
done
[ ! -e "$WORK_DIR/escaped" ] || fail 'archive escaped staging directory'
cmp "$WORK_DIR/archive.manifest.after" "$archive_home/.clashctl-files" || fail 'rejected archive changed manifest'
# 无 Git 的安装也能正常卸载，更新后标记仍有效。
PATH="$no_git_bin" bash "$archive_home/uninstall.sh" --yes >"$WORK_DIR/archive-uninstall.out" 2>&1 || { cat "$WORK_DIR/archive-uninstall.out"; fail 'archive uninstall failed'; }
[ ! -e "$archive_home" ] || fail 'archive installation remains after uninstall'

old=$("$REAL_GIT" -C "$CLASHCTL_HOME" rev-parse HEAD)
printf 'local edit\n' >>"$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
if clashupdate >"$WORK_DIR/dirty.out" 2>&1; then fail 'update overwrote local edits'; fi
"$REAL_GIT" -C "$CLASHCTL_HOME" checkout -- scripts/cmd/clashctl.sh
printf '\nbroken() {\n' >>"$FIXTURE/install.sh"
"$REAL_GIT" -C "$FIXTURE" commit -qam broken-installer
if clashupdate >"$WORK_DIR/broken-installer.out" 2>&1; then fail 'invalid installer was deployed'; fi
[ "$("$REAL_GIT" -C "$CLASHCTL_HOME" rev-parse HEAD)" = "$old" ] || fail 'invalid installer changed version'
cp "$REPO_DIR/install.sh" "$FIXTURE/install.sh"
printf 'broken() {\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
"$REAL_GIT" -C "$FIXTURE" commit -qam broken
if clashupdate >"$WORK_DIR/broken.out" 2>&1; then fail 'syntax error was deployed'; fi
[ "$("$REAL_GIT" -C "$CLASHCTL_HOME" rev-parse HEAD)" = "$old" ] || fail 'syntax failure changed version'
if FAIL_FETCH=1 clashupdate >"$WORK_DIR/network.out" 2>&1; then fail 'fetch failure succeeded'; fi
[ "$("$REAL_GIT" -C "$CLASHCTL_HOME" rev-parse HEAD)" = "$old" ] || fail 'fetch failure changed version'
printf 'fixture_version=new\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
printf 'foreign environment\n' >"$FIXTURE/.env"
"$REAL_GIT" -C "$FIXTURE" add -f .env
"$REAL_GIT" -C "$FIXTURE" commit -qam incompatible-layout
if clashupdate >"$WORK_DIR/layout.out" 2>&1; then fail 'update accepted tracked user data'; fi
cmp "$WORK_DIR/env.before" "$CLASHCTL_HOME/.env" || fail 'incompatible update overwrote environment'
if FAIL_STOP=1 bash "$CLASHCTL_HOME/uninstall.sh" --yes >"$WORK_DIR/uninstall-failed.out" 2>&1; then
    fail 'uninstall ignored service stop failure'
fi
[ -f "$CLASHCTL_HOME/data/config.yaml" ] || fail 'failed uninstall removed user data'
bash "$CLASHCTL_HOME/uninstall.sh" --yes >"$WORK_DIR/uninstall.out" 2>&1
[ ! -e "$CLASHCTL_HOME" ] || fail 'uninstall retained installation'
printf 'install-update: ok\n'
