#!/usr/bin/env bash
# 本地 Git 源模拟网络，执行实际管道入口、初始化和更新流程。
# shellcheck disable=SC2119  # 测试无参数的更新入口
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
interrupt_shell_launcher_pid='' interrupt_shell_main_pid=''
cleanup_hook() {
    [ -z "$interrupt_shell_main_pid" ] || kill "$interrupt_shell_main_pid" 2>/dev/null || true
    [ -z "$interrupt_shell_launcher_pid" ] || kill "$interrupt_shell_launcher_pid" 2>/dev/null || true
    wait 2>/dev/null || true
}
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
cp "$REPO_DIR/scripts/lib/operation-lock.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/lib/install-maintenance.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/lib/service-process.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/lib/common.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/lib/shell.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/cmd/update.sh" "$FIXTURE/scripts/cmd/"
cp "$REPO_DIR/install.sh" "$FIXTURE/"
cp "$REPO_DIR/uninstall.sh" "$FIXTURE/"
cp "$REPO_DIR/.env.example" "$FIXTURE/"
cp "$REPO_DIR/resources/"{mixin.yaml.example,profiles.yaml} "$FIXTURE/resources/"
printf 'data/\nbin/\n.env\n.clashctl-install\n.clashctl-format\n.clashctl-uninitialized\n.clashctl-incomplete\n.clashctl-files\n' >"$FIXTURE/.gitignore"
cat >"$FIXTURE/scripts/preflight.sh" <<'STUB'
[ ! -f "$CLASHCTL_HOME/.env" ] || . "$CLASHCTL_HOME/.env"
. "$CLASHCTL_SRC/scripts/lib/common.sh"
. "$CLASHCTL_SRC/scripts/lib/service-process.sh"
. "$CLASHCTL_SRC/scripts/lib/operation-lock.sh"
STUB
cat "$TEST_DIR/lib/preflight.fixture" >>"$FIXTURE/scripts/preflight.sh"
cat >>"$FIXTURE/scripts/preflight.sh" <<'STUB'
bin_kernel_path() {
    if [ "$CLASHCTL_KERNEL" = mihomo ]; then
        printf '%s/bin/mihomo' "$CLASHCTL_HOME"
    else
        printf '%s/bin/%s/%s' "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" "$CLASHCTL_KERNEL"
    fi
}
gh_proxy_url() { [ -z "${GH_PROXY:-}" ] && printf '%s\n' "$1" || printf '%s/%s\n' "${GH_PROXY%/}" "$1"; }
detect_service_manager() { service_manager=${TEST_SERVICE_MANAGER:-nohup}; }
detect_rc() {
    SHELL_RC_BASH="$HOME/.bashrc"
    SHELL_RC_ZSH=
    SHELL_RC_FISH=
    [ ! -d "$HOME/.config/fish" ] || SHELL_RC_FISH="$HOME/.config/fish/conf.d/clashctl.fish"
}
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
uninstall_service() {
    [ "${FAIL_STOP:-0}" = 0 ] || return 1
    if [ "$CLASHCTL_KERNEL" = clash ]; then
        touch "$CLASH_DATA_DIR/clash-retired"
        rm -f "$CLASH_DATA_DIR/started"
    fi
}
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
init_fixture_repo "$FIXTURE"
"$REAL_GIT" -C "$FIXTURE" branch iu
"$REAL_GIT" -C "$FIXTURE" checkout -qb legacy
"$REAL_GIT" -C "$FIXTURE" rm -q .env.example
"$REAL_GIT" -C "$FIXTURE" commit -qm legacy-layout
"$REAL_GIT" -C "$FIXTURE" checkout -q master
cat >"$WORK_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
[ "${FAIL_FETCH:-0}" = 0 ] || exit 1
[ -z "${GIT_CALL_LOG:-}" ] || printf '%s\n' "$*" >>"$GIT_CALL_LOG"
args=()
for arg in "$@"; do
    case $arg in
    *github.com/nelvko/clashctl.git) arg=$FIXTURE ;;
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
    if CLASHCTL_HOME="$locked_home" bash "$REPO_DIR/install.sh" >"$WORK_DIR/locked-new.out" 2>&1; then
        fail 'new installation ignored held lock'
    fi
    grep -q '另一项 clashctl' "$WORK_DIR/locked-new.out" || fail 'new installation did not diagnose contention'
    [ ! -e "$locked_home" ] || fail 'lock contention created installation directory'
    [ -z "$(find "$WORK_DIR" -maxdepth 1 -name 'locked-new.download.*' -print -quit)" ] || fail 'lock contention left staged source'
)
# stdin 是脚本，CI 跳过 /dev/tty 输入；初始化不能只安装命令空壳。
# shellcheck disable=SC2002  # 必须验证管道输入，不能改成文件执行
# 两个 env -u：未设时才走管道安装，保证下面断言的是"未提供即直连"。
GIT_CALL_LOG="$WORK_DIR/quiet-git.log" env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH \
    bash -c 'cat "$1" | bash' _ "$REPO_DIR/install.sh" >"$WORK_DIR/install.out" 2>&1
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
[ "$(cat "$CLASHCTL_HOME/data/download-options")" = 'mihomo|master|' ] || fail 'default install used an implicit proxy'
bash -c '. "$1"; [ -z "${GH_PROXY:-}" ]' _ "$CLASHCTL_HOME/.env" || fail 'default install persisted an implicit proxy'
grep -q '安装完成' "$WORK_DIR/install.out" || fail 'missing install result'
grep -q '新安装 clashctl' "$WORK_DIR/install.out" || fail 'missing initial installation state'
grep -Fq "安装目录: $CLASHCTL_HOME" "$WORK_DIR/install.out" || fail 'missing installation directory'
grep -Fq "安装目录: $CLASHCTL_HOME（CLASHCTL_HOME）" "$WORK_DIR/install.out" || fail 'missing installation directory source'
grep -Fq '（分支 master）' "$WORK_DIR/install.out" || fail 'missing source branch'
grep -Fq '在当前终端执行（bash）:' "$WORK_DIR/install.out" || fail 'missing shell activation heading'
grep -q '^ *source .*\.bashrc *#' "$WORK_DIR/install.out" || fail 'missing shell activation step'
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
if FAIL_FETCH=1 CLASHCTL_HOME="$prepared_home" bash "$REPO_DIR/install.sh" \
    >"$WORK_DIR/prepared-source-failed.out" 2>&1; then fail 'prepared source download failure was ignored'; fi
[ "$(sha256sum "$prepared_home/archives/"*.gz)" = "$prepared_sum" ] || fail 'source failure changed prepared archives'
[ ! -e "$prepared_home/install.sh" ] || fail 'source failure wrote installation files'
if FAIL_PREPARE=1 CLASHCTL_HOME="$prepared_home" bash "$REPO_DIR/install.sh" \
    >"$WORK_DIR/prepared-components-failed.out" 2>&1; then fail 'prepared component failure was ignored'; fi
[ "$(sha256sum "$prepared_home/archives/"*.gz)" = "$prepared_sum" ] || fail 'component failure changed prepared archives'
CLASHCTL_HOME="$prepared_home" bash "$prepared_home/install.sh" \
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
TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$direct_managed_home" bash "$REPO_DIR/install.sh" \
    >"$WORK_DIR/direct-managed.out" 2>&1 || fail 'managed direct install failed'
[ -f "$direct_managed_home/data/started" ] || fail 'managed direct install did not start the kernel'
[ -f "$direct_managed_home/data/enabled" ] || fail 'managed direct install did not enable autostart'
grep -Fq '已注册 systemd 服务' "$WORK_DIR/direct-managed.out" || fail 'managed direct install omitted registration result'
grep -Fq '已设置开机自启' "$WORK_DIR/direct-managed.out" || fail 'managed direct install omitted autostart result'
# 无订阅的启动失败仍是安装失败，不能输出成功或设置自启。
direct_failed_home="$WORK_DIR/direct-start-failed"
if FAIL_START=1 TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$direct_failed_home" bash "$REPO_DIR/install.sh" \
    >"$WORK_DIR/direct-start-failed.out" 2>&1; then
    fail 'direct install ignored kernel startup failure'
fi
[ -f "$direct_failed_home/.clashctl-incomplete" ] || fail 'direct startup failure lost incomplete marker'
[ ! -e "$direct_failed_home/data/enabled" ] || fail 'failed direct startup enabled autostart'
! grep -q '安装完成\|已设置开机自启' "$WORK_DIR/direct-start-failed.out" || fail 'failed direct startup claimed success'
# 订阅失败后仍可直连使用；可复制的添加命令仅在末尾出现一次。
sub_failed_home="$WORK_DIR/subscription-failed"
FAIL_SUB=1 CLASHCTL_HOME="$sub_failed_home" bash "$REPO_DIR/install.sh" --sub file:///unavailable \
    >"$WORK_DIR/subscription-failed.out" 2>&1 || fail 'subscription failure prevented direct installation'
[ -f "$sub_failed_home/data/started" ] || fail 'subscription failure did not fall back to direct startup'
grep -q '订阅添加失败，可稍后重试' "$WORK_DIR/subscription-failed.out" || fail 'subscription failure omitted retry hint'
[ "$(grep -Fc 'clashctl sub add --use "<URL>"' "$WORK_DIR/subscription-failed.out")" -eq 1 ] ||
    fail 'subscription retry command was duplicated'
# 下载运行组件失败时仍可凭安装阶段标记清理，不能依靠 .env 缺失猜测。
interrupted_home="$WORK_DIR/prepare-failed"
if FAIL_PREPARE=1 FAIL_PREPARE_TIMEOUT=1 FAIL_DOWNLOAD_HINT=1 CLASHCTL_HOME="$interrupted_home" bash "$REPO_DIR/install.sh" \
    --gh-proxy=https://slow.proxy.test >"$WORK_DIR/prepare-failed.out" 2>&1; then
    fail 'component preparation failure was ignored'
fi
[ "$(retry_command_from_output "$WORK_DIR/prepare-failed.out")" = \
    "CLASHCTL_DOWNLOAD_TIMEOUT=0 bash $interrupted_home/install.sh --home $interrupted_home --branch=master --gh-proxy=https://slow.proxy.test" ] ||
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
    bash "$interrupted_home/install.sh" >"$WORK_DIR/prepare-limited.out" 2>&1; then
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
    cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$proxy_home" CI=1 bash -s -- $flag >"$WORK_DIR/flag.out" 2>&1 ||
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
        bash -s -- "${branch_args[@]}" >"$WORK_DIR/branch-$form.out" 2>&1 ||
        { cat "$WORK_DIR/branch-$form.out"; fail "branch flag rejected: $form"; }
    [ "$("$REAL_GIT" -C "$branch_home" branch --show-current)" = iu ] || fail 'branch flag did not select clone source'
    grep -q '^CLASHCTL_UPDATE_BRANCH=iu$' "$branch_home/.env" || fail 'branch flag was not persisted'
    env -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$branch_home" \
        bash "$branch_home/install.sh" >"$WORK_DIR/branch-retry.out" 2>&1
    [ "$(cat "$branch_home/data/download-options")" = 'mihomo|iu|' ] || fail 'retry lost selected branch'
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
        bash "$branch_home/install.sh" --branch master >"$WORK_DIR/branch-switch.out" 2>&1
    [ "$(cat "$branch_home/data/download-options")" = 'mihomo|master|' ] || fail 'branch flag did not override environment and saved branch'
    grep -q '^CLASHCTL_UPDATE_BRANCH=master$' "$branch_home/.env" || fail 'branch switch was not persisted'
done
# .env 尚未生成时，失败提示中的命令也必须能恢复原分支。
branch_failed_home="$WORK_DIR/branch-failed"
if FAIL_PREPARE=1 CLASHCTL_HOME="$branch_failed_home" CLASHCTL_UPDATE_BRANCH=master \
    bash "$REPO_DIR/install.sh" --branch iu >"$WORK_DIR/branch-failed.out" 2>&1; then
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
        option_args=(--kernel mihomo --sub 'file:///install-sub?token=example&name=main')
    else
        option_args=(--kernel=mihomo '--sub=file:///install-sub?token=example&name=main')
    fi
    TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$option_home" bash "$REPO_DIR/install.sh" "${option_args[@]}" \
        >"$WORK_DIR/options-$form.out" 2>&1 ||
        { cat "$WORK_DIR/options-$form.out"; fail "install options rejected: $form"; }
    [ "$(cat "$option_home/data/subscription")" = 'file:///install-sub?token=example&name=main' ] ||
        fail "install subscription was not passed through: $form"
    [ "$(cat "$option_home/data/download-options")" = 'mihomo|master|' ] ||
        fail "install kernel option was not applied: $form"
    [ -f "$option_home/data/started" ] || fail "install subscription was not activated: $form"
    [ -f "$option_home/data/enabled" ] || fail "install subscription did not enable service: $form"
    grep -Fq '已注册 systemd 服务' "$WORK_DIR/options-$form.out" || fail 'managed service registration result missing'
    grep -Fq '已设置开机自启' "$WORK_DIR/options-$form.out" || fail 'managed service startup result missing'
done
# 详细模式必须从安装入口传递到组件下载阶段。
verbose_home="$WORK_DIR/verbose-install"
GIT_CALL_LOG="$WORK_DIR/verbose-git.log" CLASHCTL_HOME="$verbose_home" bash "$REPO_DIR/install.sh" --verbose >"$WORK_DIR/verbose.out" 2>&1 ||
    { cat "$WORK_DIR/verbose.out"; fail 'verbose installation failed'; }
[ "$(cat "$verbose_home/data/download-verbose")" = 1 ] || fail 'verbose option did not reach component downloads'
! grep -q 'clone .*--quiet' "$WORK_DIR/verbose-git.log" || fail 'verbose source download hid Git progress'
# 订阅与无订阅路径都必须指出自启设置失败；续装需恢复已运行内核的自启。
for subscription_state in subscribed direct; do
    enable_failed_home="$WORK_DIR/enable-failed-$subscription_state"
    enable_args=()
    [ "$subscription_state" != subscribed ] || enable_args=(--sub file:///enable-retry)
    if FAIL_ENABLE=1 TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$enable_failed_home" bash "$REPO_DIR/install.sh" \
        "${enable_args[@]}" >"$WORK_DIR/enable-failed-$subscription_state.out" 2>&1; then
        fail 'service enable failure succeeded'
    fi
    grep -q '开机自启设置失败' "$WORK_DIR/enable-failed-$subscription_state.out" || fail 'enable failure omitted its failed operation'
    ! grep -q '安装完成\|已设置开机自启' "$WORK_DIR/enable-failed-$subscription_state.out" || fail 'enable failure claimed installation or autostart success'
    [ -f "$enable_failed_home/data/started" ] && [ -f "$enable_failed_home/.clashctl-incomplete" ] || fail 'enable failure lost running/incomplete state'
    [ ! -e "$enable_failed_home/data/enabled" ] || fail 'failed enable set autostart'
    TEST_SERVICE_MANAGER=systemd CLASHCTL_HOME="$enable_failed_home" bash "$enable_failed_home/install.sh" >"$WORK_DIR/enable-retry-$subscription_state.out" 2>&1
    [ -f "$enable_failed_home/data/enabled" ] || fail 'retry did not enable already running service'
    [ ! -e "$enable_failed_home/.clashctl-incomplete" ] || fail 'enable retry retained incomplete state'
    grep -Fq 'mihomo 已在运行' "$WORK_DIR/enable-retry-$subscription_state.out" || fail 'enable retry did not preserve the running status'
done
# 无效参数应在下载源码、创建安装目录前报错。
for bad_arg in --kernel --kernel= --kernel=unknown --sub --sub= mihomo clash; do
    invalid_option_home="$WORK_DIR/invalid-option"
    if CLASHCTL_HOME="$invalid_option_home" bash "$REPO_DIR/install.sh" "$bad_arg" \
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
    if FAIL_FETCH=1 CLASHCTL_HOME="$invalid_branch_home" bash "$REPO_DIR/install.sh" "${branch_args[@]}" \
        >"$WORK_DIR/invalid-branch.out" 2>&1; then
        fail "missing branch accepted: $form"
    fi
    grep -q -- '--branch 需要一个分支名称' "$WORK_DIR/invalid-branch.out" || fail 'missing branch was not diagnosed before fetch'
    [ ! -e "$invalid_branch_home" ] || fail 'invalid branch created installation directory'
done
# 未发布的旧参数直接移除，带有效值时也不能作为兼容别名接受。
for old_option in --install-dir --subscription; do
    old_value="$WORK_DIR/removed-option-target"
    [ "$old_option" != --subscription ] || old_value=file:///removed-option-sub
    for form in separate equals; do
        old_args=("$old_option" "$old_value")
        [ "$form" != equals ] || old_args=("$old_option=$old_value")
        rejected_home="$WORK_DIR/removed-option-home"
        if FAIL_FETCH=1 CLASHCTL_HOME="$rejected_home" bash "$REPO_DIR/install.sh" "${old_args[@]}" \
            >"$WORK_DIR/removed-option.out" 2>&1; then
            fail "removed option was accepted: $old_option ($form)"
        fi
        grep -q '未知安装参数' "$WORK_DIR/removed-option.out" || fail 'removed option reached source preparation'
        [ ! -e "$rejected_home" ] && [ ! -e "$WORK_DIR/removed-option-target" ] || fail 'removed option created installation'
    done
done
# --home 两种形式均可用于管道安装，且覆盖右侧 bash 继承的 CLASHCTL_HOME。
for form in separate equals; do
    flag_home="$WORK_DIR/home-$form"
    ignored_home="$WORK_DIR/ignored-home-$form"
    if [ "$form" = separate ]; then
        home_args=(--home "$flag_home")
    else
        home_args=("--home=$flag_home")
    fi
    # shellcheck disable=SC2002  # 验证从 stdin 运行安装器及右侧 bash 的参数。
    cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$ignored_home" CI=1 \
        bash -s -- "${home_args[@]}" >"$WORK_DIR/home-$form.out" 2>&1 ||
        { cat "$WORK_DIR/home-$form.out"; fail "home flag rejected: $form"; }
    [ -f "$flag_home/.env" ] || fail "home flag did not initialize target: $form"
    [ "$(head -n 1 "$flag_home/.clashctl-install")" = "$flag_home" ] ||
        fail "home flag recorded wrong path: $form"
    [ ! -e "$ignored_home" ] || fail "CLASHCTL_HOME overrode home flag: $form"
    grep -Fq "安装目录: $flag_home" "$WORK_DIR/home-$form.out" || fail 'explicit home not shown'
done
# 缺失值、空值和无效路径都必须在创建安装目录前拒绝。
for bad_arg in --home --home=; do
    missing_home="$WORK_DIR/missing-home"
    if CLASHCTL_HOME="$missing_home" bash "$REPO_DIR/install.sh" "$bad_arg" \
        >"$WORK_DIR/missing-home.out" 2>&1; then
        fail "home accepted missing value: $bad_arg"
    fi
    grep -q -- '--home' "$WORK_DIR/missing-home.out" ||
        fail "home missing value lacked a diagnosis: $bad_arg"
    [ ! -e "$missing_home" ] || fail "missing home value fell back to CLASHCTL_HOME: $bad_arg"
done
for invalid_dir in relative-home "$WORK_DIR/invalid install dir"; do
    if bash "$REPO_DIR/install.sh" --home "$invalid_dir" \
        >"$WORK_DIR/invalid-home.out" 2>&1; then
        fail "home accepted invalid path: $invalid_dir"
    fi
    grep -q '安装目录必须是绝对路径' "$WORK_DIR/invalid-home.out" ||
        fail "home invalid path lacked a diagnosis: $invalid_dir"
done
# 执行 README 原文中的安装代码块，只把入口下载替换成本地脚本。
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
    eval "$2"
' _ "$REPO_DIR/install.sh" "$readme_command" >"$WORK_DIR/readme.out" 2>&1 || {
    cat "$WORK_DIR/readme.out"; fail 'README installation command failed'
}
grep -Eq '^GH_PROXY=https://gh-proxy\.org/?$' "$WORK_DIR/readme-home/.env" || fail 'README proxy was not persisted'
grep -q '^CLASHCTL_UPDATE_BRANCH=master$' "$WORK_DIR/readme-home/.env" || fail 'README master branch was not persisted'
# 续装保留已保存的选项；显式参数优先，空代理可切回直连。
retry_home="$WORK_DIR/retry-options"
CLASHCTL_HOME="$retry_home" CLASHCTL_UPDATE_BRANCH=iu bash "$REPO_DIR/install.sh" --kernel mihomo --gh-proxy=https://old.proxy.test >"$WORK_DIR/options.out" 2>&1
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" bash "$retry_home/install.sh" >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'mihomo|iu|https://old.proxy.test' ] || fail 'retry lost saved options'
# 已移除的 clash 参数必须在更新、配置写入和服务操作前拒绝。
cp "$retry_home/.env" "$WORK_DIR/kernel-env.expected"
retry_head=$("$REAL_GIT" -C "$retry_home" rev-parse HEAD)
for kernel_form in equals separate; do
    kernel_args=(--kernel=clash)
    [ "$kernel_form" != separate ] || kernel_args=(--kernel clash)
    if FAIL_FETCH=1 CLASHCTL_HOME="$retry_home" \
        bash "$retry_home/install.sh" "${kernel_args[@]}" >"$WORK_DIR/kernel-change.out" 2>&1; then
        fail "removed kernel was accepted: $kernel_form"
    fi
    grep -q -- '--kernel 仅支持 mihomo' "$WORK_DIR/kernel-change.out" || fail 'kernel was not diagnosed before fetch'
    cmp -s "$retry_home/.env" "$WORK_DIR/kernel-env.expected" || fail 'kernel rejection modified config'
    [ "$("$REAL_GIT" -C "$retry_home" rev-parse HEAD)" = "$retry_head" ] || fail 'kernel rejection updated source'
    [ ! -e "$retry_home/.clashctl-incomplete" ] || fail 'kernel rejection changed installation state'
done
(
    . "$REPO_DIR/scripts/lib/operation-lock.sh"
    operation_lock_acquire || fail 'could not hold retry lock'
    trap operation_lock_release EXIT
    if CLASHCTL_HOME="$retry_home" bash "$retry_home/install.sh" >"$WORK_DIR/locked-retry.out" 2>&1; then
        fail 'existing installation ignored held lock'
    fi
    grep -q '另一项 clashctl' "$WORK_DIR/locked-retry.out" || fail 'retry did not diagnose contention'
    cmp -s "$retry_home/.env" "$WORK_DIR/kernel-env.expected" || fail 'locked retry modified config'
    [ ! -e "$retry_home/.clashctl-incomplete" ] || fail 'locked retry changed installation state'
)
CLASHCTL_HOME="$retry_home" CLASHCTL_UPDATE_BRANCH=master GH_PROXY=https://env.proxy.test \
    bash "$retry_home/install.sh" --kernel mihomo --gh-proxy=https://new.proxy.test >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'mihomo|master|https://new.proxy.test' ] || fail 'saved options overrode retry arguments'
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" \
    bash "$retry_home/install.sh" --gh-proxy= >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'mihomo|master|' ] || fail 'retry could not clear proxy'
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" \
    bash "$retry_home/install.sh" >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'mihomo|master|' ] || fail 'retry options were not persisted'
CLASHCTL_HOME="$retry_home" CLASHCTL_DOWNLOAD_TIMEOUT=180 bash "$retry_home/install.sh" \
    >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-timeout")" = 180 ] || fail 'retry timeout was overridden by saved config'
env -u CLASHCTL_DOWNLOAD_TIMEOUT CLASHCTL_HOME="$retry_home" \
    bash "$retry_home/install.sh" >"$WORK_DIR/timeout-persisted.out" 2>&1
[ "$(cat "$retry_home/data/download-timeout")" = 180 ] || fail 'retry did not persist timeout override'
# 指向已有安装时，--home 也必须决定更新目标，而不是环境变量或已保存的路径。
ignored_existing="$WORK_DIR/ignored-existing"
CLASHCTL_HOME="$ignored_existing" GH_PROXY=https://env.proxy.test \
    bash "$retry_home/install.sh" --home "$retry_home" --gh-proxy=https://flag-existing.test \
    >"$WORK_DIR/existing-home.out" 2>&1 ||
    { cat "$WORK_DIR/existing-home.out"; fail 'home could not update existing installation'; }
[ "$(cat "$retry_home/data/download-options")" = 'mihomo|master|https://flag-existing.test' ] ||
    fail 'home did not update the selected installation'
[ ! -e "$ignored_existing" ] || fail 'existing installation update used CLASHCTL_HOME instead of home'
# 源码不能通过重试初始化获得安装身份；克隆真实安装也不会继承 Git 私有标记。
if CLASHCTL_HOME="$FIXTURE" bash "$FIXTURE/install.sh" >"$WORK_DIR/source-retry.out" 2>&1; then
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
    FAIL_FETCH=1 FAIL_DOWNLOAD=1 CLASHCTL_HOME="$local_home" CLASHCTL_UPDATE_BRANCH=master \
        bash "$local_source/install.sh" --local --branch iu --gh-proxy=https://local.proxy.test
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
# 按失败提示在原目录续装时，已保留的源码无需再次联网。
offline_home="$WORK_DIR/local-offline"
if FAIL_PREPARE=1 CLASHCTL_HOME="$offline_home" bash "$local_source/install.sh" --local \
    >"$WORK_DIR/local-offline.out" 2>&1; then fail 'offline retry fixture did not fail'; fi
offline_retry=$(retry_command_from_output "$WORK_DIR/local-offline.out")
mkdir "$WORK_DIR/offline-bin"
printf '#!/bin/sh\nexit 99\n' >"$WORK_DIR/offline-bin/curl"
chmod +x "$WORK_DIR/offline-bin/curl"
cp "$offline_home/.clashctl-files" "$WORK_DIR/offline-manifest.before"
PATH="$WORK_DIR/offline-bin:$PATH" FAIL_FETCH=1 bash -c "$offline_retry" \
    >"$WORK_DIR/local-offline-resume.out" 2>&1 ||
    { cat "$WORK_DIR/local-offline-resume.out"; fail 'retained local source could not resume offline'; }
cmp "$WORK_DIR/offline-manifest.before" "$offline_home/.clashctl-files" || fail 'offline retry replaced retained source'
grep -qx 'fixture_version=uncommitted' "$offline_home/scripts/cmd/clashctl.sh" || fail 'offline retry lost local source'
[ ! -e "$offline_home/.clashctl-incomplete" ] || fail 'offline retry did not complete'
local_interrupted="$WORK_DIR/local-interrupted"
if FAIL_PREPARE=1 CLASHCTL_HOME="$local_interrupted" bash "$local_source/install.sh" --local \
    >"$WORK_DIR/local-interrupted.out" 2>&1; then
    fail 'interrupted local installation was accepted'
fi
printf 'fixture_version=after-interruption\n' >"$local_source/scripts/cmd/clashctl.sh"
CLASHCTL_HOME="$local_interrupted" bash "$local_source/install.sh" --local \
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
        CLASHCTL_HOME="$local_home" bash "$local_source/install.sh" --local \
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
CLASHCTL_HOME="$local_home" bash "$local_source/install.sh" --local >"$WORK_DIR/local-refresh.out" 2>&1 ||
    { cat "$WORK_DIR/local-refresh.out"; fail 'local archive update failed'; }
grep -q '更新现有安装' "$WORK_DIR/local-refresh.out" || fail 'existing installation reported as new'
grep -qx 'fixture_version=local-refresh' "$local_home/scripts/cmd/clashctl.sh" ||
    fail 'local archive source did not refresh'
[ "$(<"$local_home/data/config.yaml")" = 'saved local data' ] || fail 'local archive update changed data'
[ -z "$(find "$WORK_DIR" -maxdepth 1 -type d -name 'local-home.update.*' -print -quit)" ] ||
    fail 'successful local update retained temporary source'
# 支持的上一版安装更新/续装时，始终使用本次源码中的库。
previous_source_home="$WORK_DIR/previous-source-home"
cp -a "$local_home" "$previous_source_home"
printf '%s\narchive\n' "$previous_source_home" >"$previous_source_home/.clashctl-install"
for old_file in install.sh scripts/cmd/update.sh scripts/preflight.sh; do
    "$REAL_GIT" -C "$REPO_DIR" show "HEAD:$old_file" >"$previous_source_home/$old_file"
    printf '\nreturn 91 # 不可加载待更新安装中的旧库。\n' >>"$previous_source_home/$old_file"
    previous_source_hash=$(sha256sum "$previous_source_home/$old_file")
    previous_source_hash=${previous_source_hash%% *}
    sed -i "s|^[0-9a-f]*  ./$old_file$|$previous_source_hash  ./$old_file|" "$previous_source_home/.clashctl-files"
done
# 更新失败也必须沿用新安装器的退出清理，恢复旧文件并释放目录锁。
if PATH="$local_failure_bin:$PATH" REAL_TAR="$real_tar" \
    LOCAL_UPDATE_PROGRAM="$previous_source_home/scripts/cmd/clashctl.sh" FAIL_LOCAL_RESTORE=0 \
    CLASHCTL_HOME="$previous_source_home" bash "$local_source/install.sh" --local >"$WORK_DIR/previous-source-failed.out" 2>&1; then
    fail 'old current partial update reported success'
fi
grep -q '原程序文件已恢复' "$WORK_DIR/previous-source-failed.out" ||
    { cat "$WORK_DIR/previous-source-failed.out"; fail 'old current update did not use the new rollback handler'; }
bash -c '. "$1"; operation_lock_acquire && trap operation_lock_release EXIT' _ "$REPO_DIR/scripts/lib/operation-lock.sh" ||
    fail 'old current failed update retained the new operation lock'
: >"$previous_source_home/.clashctl-incomplete"
CLASHCTL_HOME="$previous_source_home" bash "$local_source/install.sh" --local \
    >"$WORK_DIR/previous-source-updated.out" 2>&1 ||
    { cat "$WORK_DIR/previous-source-updated.out"; fail 'old current protocol did not migrate using the new lock'; }
grep -q '^_directory_lock_acquire()' "$previous_source_home/scripts/lib/operation-lock.sh" ||
    fail 'old current protocol library was not replaced'
# 管道更新没有伴随库，必须先准备新源码，不能调用安装目录里的旧锁函数。
previous_source_git="$WORK_DIR/previous-source-git"
cp -a "$CLASHCTL_HOME" "$previous_source_git"
printf '%s\ngit\n' "$previous_source_git" >"$previous_source_git/.clashctl-install"
for old_file in install.sh scripts/cmd/update.sh scripts/preflight.sh; do
    "$REAL_GIT" -C "$REPO_DIR" show "HEAD:$old_file" >"$previous_source_git/$old_file"
    printf '\nreturn 91 # 不可加载待更新安装中的旧库。\n' >>"$previous_source_git/$old_file"
done
"$REAL_GIT" -C "$previous_source_git" config user.email test@example.invalid
"$REAL_GIT" -C "$previous_source_git" config user.name test
"$REAL_GIT" -C "$previous_source_git" add install.sh scripts/cmd/update.sh scripts/preflight.sh
"$REAL_GIT" -C "$previous_source_git" commit -qm old-lock-protocol
CLASHCTL_HOME="$previous_source_git" bash -c 'cat "$1" | bash -s --' _ "$REPO_DIR/install.sh" \
    >"$WORK_DIR/previous-source-pipe.out" 2>&1 ||
    { cat "$WORK_DIR/previous-source-pipe.out"; fail 'piped update reused the old installed lock implementation'; }
grep -q '^_directory_lock_acquire()' "$previous_source_git/scripts/lib/operation-lock.sh" ||
    fail 'piped update did not replace the old protocol library'
[ -z "$(find "$WORK_DIR" -maxdepth 1 -type d -name 'previous-source-git.download.*' -print -quit)" ] ||
    fail 'piped update retained bootstrap source'
bash "$local_home/uninstall.sh" --yes >"$WORK_DIR/local-uninstall.out" 2>&1 || fail 'local installation could not be uninstalled'
[ -f "$local_source/install.sh" ] || fail 'uninstall removed local source'

# 截止外的旧安装只报错，不读取 .env、不移动文件或接管服务。
for kind in v1 v2 lock; do
    legacy_home="$WORK_DIR/rejected-$kind"
    mkdir -p "$legacy_home/scripts/lib" "$legacy_home/data"
    printf 'exit 91\n' >"$legacy_home/.env"
    printf 'preserve\n' >"$legacy_home/data/config.yaml"
    if [ "$kind" = v2 ]; then
        printf 'old marker\n' >"$legacy_home/.clashctl-installation"
    elif [ "$kind" = lock ]; then
        cp -a "$local_source/." "$legacy_home/"
        printf '%s\narchive\n' "$legacy_home" >"$legacy_home/.clashctl-install"
        chmod 0600 "$legacy_home/.clashctl-install"
        printf '#!/bin/bash\n' >"$legacy_home/scripts/lib/operation-lock.sh"
    fi
    tar -cf "$WORK_DIR/rejected-before.tar" -C "$legacy_home" .
    if CLASHCTL_HOME="$legacy_home" bash "$local_source/install.sh" --local >"$WORK_DIR/rejected.out" 2>&1; then
        fail "old installation was accepted: $kind"
    fi
    grep -q '请先使用旧版卸载脚本卸载，或通过 --home' "$WORK_DIR/rejected.out" ||
        { cat "$WORK_DIR/rejected.out"; fail "missing cutoff diagnosis: $kind"; }
    tar -df "$WORK_DIR/rejected-before.tar" -C "$legacy_home" || fail "old installation was modified: $kind"
done
legacy_user="$WORK_DIR/rejected-default-user"
mkdir -p "$legacy_user/clashctl/scripts"
printf 'exit 91\n' >"$legacy_user/clashctl/.env"
if env -u CLASHCTL_HOME HOME="$legacy_user" bash "$local_source/install.sh" --local >"$WORK_DIR/rejected-default.out" 2>&1; then
    fail 'old default installation was silently adopted'
fi
grep -q '请先使用旧版卸载脚本卸载' "$WORK_DIR/rejected-default.out" || fail 'old default installation omitted cutoff diagnosis'
[ ! -e "$legacy_user/.clashctl" ] || fail 'old default installation created a new directory'

if CLASHCTL_HOME="$local_source/nested" bash "$local_source/install.sh" --local >"$WORK_DIR/local-nested.out" 2>&1; then
    fail 'local installation accepted a destination inside its source'
fi
[ ! -e "$local_source/nested" ] || fail 'nested local installation changed source'
# shellcheck disable=SC2002  # 验证管道输入缺少本地源码路径时的错误。
if cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$WORK_DIR/local-pipe" bash -s -- --local >"$WORK_DIR/local-pipe.out" 2>&1; then
    fail 'local installation accepted pipeline input'
fi
grep -q '不支持管道输入' "$WORK_DIR/local-pipe.out" || fail 'missing local pipeline diagnosis'
printf 'broken() {\n' >"$local_source/scripts/local-helper.sh"
if CLASHCTL_HOME="$local_home" bash "$local_source/install.sh" --local >"$WORK_DIR/local-broken.out" 2>&1; then
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
bash "$REPO_DIR/install.sh" >"$WORK_DIR/existing.out" 2>&1 || {
    cat "$WORK_DIR/existing.out"; fail 'existing installation was not updated'
}
grep -qx 'fixture_version=auto-updated' "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ||
    fail 'installer did not refresh existing program files'
[ "$(<"$CLASHCTL_HOME/data/config.yaml")" = 'user data preserved' ] ||
    fail 'installer changed existing user data'
chmod 0644 "$CLASHCTL_HOME/.clashctl-install"
if bash "$REPO_DIR/install.sh" >"$WORK_DIR/unsafe-marker.out" 2>&1; then
    fail 'installer accepted a writable installation marker'
fi
chmod 0600 "$CLASHCTL_HOME/.clashctl-install"
mv "$CLASHCTL_HOME/.env" "$CLASHCTL_HOME/.env.saved"
ln -s .env.saved "$CLASHCTL_HOME/.env"
if bash "$REPO_DIR/install.sh" >"$WORK_DIR/unsafe-env.out" 2>&1; then
    fail 'installer accepted a symlinked environment file'
fi
rm "$CLASHCTL_HOME/.env"
mv "$CLASHCTL_HOME/.env.saved" "$CLASHCTL_HOME/.env"
if FAIL_FETCH=1 CLASHCTL_HOME="$WORK_DIR/failed" bash "$REPO_DIR/install.sh" >"$WORK_DIR/failed.out" 2>&1; then
    fail 'download failure succeeded'
fi
[ ! -e "$WORK_DIR/failed" ] || fail 'download failure installed a partial tree'
# 路径先规范化再登记；含 . 或 .. 的路径不能绕过根目录和 HOME 限制。
for unsafe_home in /tmp/.. "$HOME/./"; do
    if CLASHCTL_HOME="$unsafe_home" bash "$REPO_DIR/install.sh" >"$WORK_DIR/unsafe-home.out" 2>&1; then
        fail 'installer accepted root or HOME through path aliases'
    fi
    grep -q '不能使用根目录或用户主目录' "$WORK_DIR/unsafe-home.out" || fail 'unsafe path was not rejected before cloning'
done
CLASHCTL_HOME="$WORK_DIR/unused/../normalized" bash "$REPO_DIR/install.sh" >"$WORK_DIR/normalized.out" 2>&1
[ "$(head -n 1 "$WORK_DIR/normalized/.clashctl-install")" = "$WORK_DIR/normalized" ] || fail 'marker did not use physical installation path'
bash "$WORK_DIR/normalized/uninstall.sh" --yes >"$WORK_DIR/normalized-uninstall.out" 2>&1
[ ! -e "$WORK_DIR/normalized" ] || fail 'normalized installation could not be uninstalled'
# 已有主配置时重试初始化：启动失败仍返回失败，恢复后可以继续。
printf main-config >"$CLASHCTL_HOME/data/config.yaml"
rm -f "$CLASHCTL_HOME/data/started"
if FAIL_START=1 bash "$CLASHCTL_HOME/install.sh" >"$WORK_DIR/start-failed.out" 2>&1; then
    fail 'service failure succeeded'
fi
! grep -q '安装完成' "$WORK_DIR/start-failed.out" || fail 'service failure reported success'
[ -f "$CLASHCTL_HOME/.clashctl-incomplete" ] || fail 'failed initialization lost incomplete marker'
bash "$CLASHCTL_HOME/install.sh" >"$WORK_DIR/retry.out" 2>&1
[ -f "$CLASHCTL_HOME/data/started" ] || fail 'root installer could not retry initialization'
[ ! -e "$CLASHCTL_HOME/.clashctl-incomplete" ] || fail 'retry retained incomplete marker'

# 不兼容分支必须在落位和初始化前拒绝，不能留下半成品目录。
if CLASHCTL_UPDATE_BRANCH=legacy CLASHCTL_HOME="$WORK_DIR/legacy" bash "$REPO_DIR/install.sh" >"$WORK_DIR/legacy.out" 2>&1; then
    fail 'incompatible source was installed'
fi
[ ! -e "$WORK_DIR/legacy" ] || fail 'incompatible source created an installation'
grep -q '源码不兼容' "$WORK_DIR/legacy.out" || fail 'missing incompatible branch diagnosis'
! grep -q 'command not found' "$WORK_DIR/legacy.out" || fail 'incompatible source reached initialization'
# 左侧命令的环境变量不影响安装器，取源分支以右侧 bash 的环境为准。
# shellcheck disable=SC2002  # 验证真实管道两侧的环境变量作用域
CLASHCTL_UPDATE_BRANCH=legacy cat "$REPO_DIR/install.sh" | CLASHCTL_UPDATE_BRANCH=iu CLASHCTL_HOME="$WORK_DIR/iu" bash >"$WORK_DIR/iu.out" 2>&1
[ "$("$REAL_GIT" -C "$WORK_DIR/iu" branch --show-current)" = iu ] || fail 'pipeline cloned the wrong branch'
grep -q '^CLASHCTL_UPDATE_BRANCH=iu$' "$WORK_DIR/iu/.env" || fail 'pipeline did not persist selected branch'

# 控制终端与脚本 stdin 分离：交互输入和显式订阅共用 PTY 驱动。
# 继承前面设置的 Git 桩，将源码请求重定向到本地 fixture。
TEST_REPO="$REPO_DIR" TEST_WORK="$WORK_DIR" python3 -B - "$TEST_DIR/lib" <<'PTY'
import os, sys
sys.path.insert(0, sys.argv[1])
from terminal import run
work = os.environ["TEST_WORK"]
prompt = "订阅链接（回车跳过）: ".encode()

def install_in_terminal(name, args=(), subscription=None):
    home = work + "/" + name
    env = dict(os.environ, CLASHCTL_HOME=home, CLASHCTL_UPDATE_BRANCH="master",
               TERM="xterm-256color", INPUTRC="/dev/null")
    env.pop("CI", None)
    replies = []
    if subscription is not None:
        data = subscription if isinstance(subscription, bytes) else subscription.encode() + b"\n"
        replies.append((prompt, data))
    rc, output = run(["bash", "-c", 'cat "$TEST_REPO/install.sh" | bash -s -- "$@"',
                      "terminal-install", *args], env=env, replies=replies, timeout=20)
    assert rc == 0, output.decode(errors="replace")
    return home, output, bool(replies) and prompt in output

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

# 已有配置的重复安装不能再次询问或覆盖订阅，内核应正常启动。
os.remove(home + "/data/started")
home, output, _ = install_in_terminal("tty-install")
assert prompt not in output, "configured installation prompted again"
assert os.path.isfile(home + "/data/started"), "configured installation did not start the kernel"
with open(home + "/data/subscription") as saved:
    assert saved.read() == "file:///private-subscription", "repeat installation changed the subscription"

# 即便已有配置，显式 --sub 仍应添加并启用指定订阅。
home, output, _ = install_in_terminal("tty-install", ["--sub", "file:///replacement"])
assert prompt not in output, "explicit subscription prompted again"
with open(home + "/data/subscription") as saved:
    assert saved.read() == "file:///replacement", "existing configuration ignored --sub"

# 显式订阅和内核参数从管道入口传入，有控制终端时也不能再提示输入。
home, output, _ = install_in_terminal("tty-option-install",
                                     ["--kernel", "mihomo", "--sub", "file:///from-flag"])
assert prompt not in output, "flag installation prompted for a subscription"
with open(home + "/data/subscription") as saved:
    assert saved.read() == "file:///from-flag"
with open(home + "/data/download-options") as saved:
    assert saved.read().startswith("mihomo|master|")
PTY

. "$REPO_DIR/scripts/lib/shell.sh"
. "$REPO_DIR/scripts/cmd/update.sh"
. "$REPO_DIR/scripts/lib/operation-lock.sh"
gh_proxy_url() { printf '%s\n' "$1"; }
_ui_step() { :; }
_ui_error() { printf '%s\n' "$*" >&2; }
_ui_info() { printf '%s\n' "$*"; }
_ui_ok() { :; }
_ui_ok_out() { printf '%s\n' "$*"; }
CLASHCTL_UPDATE_BRANCH=master
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
# 无 Git 的真实 PATH：下载器只复制本地 tar 包，其余使用系统工具。
no_git_bin="$WORK_DIR/no-git-bin"
mkdir "$no_git_bin"
for tool in install bash cat dirname readlink mkdir mktemp rm rmdir mv tar gzip unzip sha256sum find sort xargs chmod cp head stat sleep touch grep sed awk id; do
    ln -s "$(command -v "$tool")" "$no_git_bin/$tool"
done
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
archive_source="$WORK_DIR/archive-source"
mkdir "$archive_source"
"$REAL_GIT" -C "$FIXTURE" archive HEAD | tar -x -C "$archive_source"
printf 'obsolete=true\n' >"$archive_source/scripts/obsolete.sh"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
archive_home="$WORK_DIR/archive-home"
PATH="$no_git_bin" CLASHCTL_HOME="$archive_home" CLASHCTL_UPDATE_BRANCH=legacy GH_PROXY=https://proxy.example \
    bash "$REPO_DIR/install.sh" --branch master >"$WORK_DIR/archive-install.out" 2>&1 || { cat "$WORK_DIR/archive-install.out"; fail 'curl fallback install failed'; }
[ ! -e "$archive_home/.git" ] || fail 'fallback created a Git repository'
[ "$(tail -n 1 "$archive_home/.clashctl-install")" = archive ] || fail 'archive type was not recorded'
[ -s "$archive_home/.clashctl-files" ] || fail 'archive file manifest missing'
grep -Fq 'https://proxy.example/https://github.com/nelvko/clashctl/archive/refs/heads/master.tar.gz' "$DOWNLOAD_LOG" || fail 'source archive ignored proxy or branch'
# curl 是早期必需依赖，不回退到 wget，也不创建安装目录。
mv "$no_git_bin/curl" "$WORK_DIR/saved-curl"
if PATH="$no_git_bin" CLASHCTL_HOME="$WORK_DIR/wget-home" GH_PROXY='' \
    bash "$REPO_DIR/install.sh" >"$WORK_DIR/no-curl.out" 2>&1; then
    fail 'installation without curl succeeded'
fi
grep -q '缺少依赖: curl' "$WORK_DIR/no-curl.out" || fail 'missing curl omitted early diagnosis'
[ ! -e "$WORK_DIR/wget-home" ] || fail 'missing curl created an installation'
mv "$WORK_DIR/saved-curl" "$no_git_bin/curl"
# Git 存在但失败时不能偷偷回退下载。
before_downloads=$(wc -l <"$DOWNLOAD_LOG")
ln -s "$WORK_DIR/bin/git" "$no_git_bin/git"
if PATH="$no_git_bin" FAIL_FETCH=1 CLASHCTL_HOME="$WORK_DIR/git-failed" bash "$REPO_DIR/install.sh" >"$WORK_DIR/git-failed.out" 2>&1; then fail 'Git failure succeeded'; fi
[ "$(wc -l <"$DOWNLOAD_LOG")" = "$before_downloads" ] || fail 'Git failure fell back to archive'
rm "$no_git_bin/git"
if PATH="$no_git_bin" FAIL_DOWNLOAD=1 CLASHCTL_HOME="$WORK_DIR/archive-failed" bash "$REPO_DIR/install.sh" >/dev/null 2>&1; then fail 'archive download failure succeeded'; fi
[ ! -e "$WORK_DIR/archive-failed" ] || fail 'failed download created installation'

archive_update() (
    export CLASHCTL_HOME="$archive_home" PATH="$no_git_bin"
    . "$REPO_DIR/scripts/lib/shell.sh"
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
