#!/usr/bin/env bash
# 临时安装目录和用户目录，systemctl 桩记录调用，绝不操作宿主服务。
# shellcheck disable=SC2016  # 引导文件中的变量必须原样写入
set -euo pipefail
unset CLASHCTL_HOME
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/user/.config/fish/conf.d"
export UNINSTALL_CALLS="$WORK_DIR/service.calls" UNINSTALL_ACTIVE="$WORK_DIR/active"
REAL_FISH=$(command -v fish)
REAL_ZSH=$(command -v zsh)
cat >"$WORK_DIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UNINSTALL_CALLS"
case $1 in
is-active) if [ -f "$UNINSTALL_ACTIVE" ]; then echo active; else echo inactive; exit 3; fi ;;
stop) [ "${FAIL_STOP:-0}" = 0 ] && rm -f "$UNINSTALL_ACTIVE" ;;
*) exit 0 ;;
esac
STUB
printf '#!/bin/sh\n' >"$WORK_DIR/bin/fish"
printf '#!/bin/sh\n' >"$WORK_DIR/bin/zsh"
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

setup_source() {
    local dest=$1
    mkdir -p "$dest/.git"
    cp "$REPO_DIR/"{install,uninstall}.sh "$dest/"
    cp "$REPO_DIR/.env.example" "$dest/"
    cp -a "$REPO_DIR/scripts" "$dest/"
    # 仅替换 init 探测和服务文件路径，保留真实卸载与归属检查。
    cat >>"$dest/scripts/lib/service.sh" <<'STUB'
detect_service_manager() { service_manager=systemd; }
_service_target() { printf '%s/service.unit\n' "$CLASHCTL_HOME"; }
STUB
}
setup_install() {
    setup_source "$1"
    printf '%s\ngit\n' "$1" >"$1/.clashctl-install"
}
write_rc() {
    local target=$1 rc
    for rc in .bashrc .zshrc; do
        {
            printf '# user setting\n# >>> clashctl >>>\nexport CLASHCTL_HOME=%q\n' "$target"
            printf '%s\n' '[ -s "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ] && . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"' '# <<< clashctl <<<'
        } >"$WORK_DIR/user/$rc"
    done
    printf '# clashctl shell-rc (managed by install.sh, do not edit)\nset -gx CLASHCTL_HOME '\''%s'\''\n' "$target" >"$WORK_DIR/user/.config/fish/conf.d/clashctl.fish"
}
run_uninstall() {
    HOME="$WORK_DIR/user" CLASHCTL_KERNEL=clash INIT_TYPE=systemd \
        bash "$1/uninstall.sh" --yes >"$WORK_DIR/output" 2>&1
}

# 没有安装时，源码入口只能报告未找到安装，不能加载或删除源码。
setup_source "$WORK_DIR/clone"
write_rc "$WORK_DIR/other-install"
cp -a "$WORK_DIR/user" "$WORK_DIR/user.expected"
printf 'exit 77\n' >"$WORK_DIR/clone/scripts/preflight.sh"
if run_uninstall "$WORK_DIR/clone"; then fail 'fresh source clone was accepted for uninstall'; fi
[ -f "$WORK_DIR/clone/uninstall.sh" ] || fail 'source clone was removed'
grep -q '未找到 clashctl 安装' "$WORK_DIR/output" || fail 'missing installation diagnosis'
printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=systemd\n' >"$WORK_DIR/clone/.env"
setup_install "$WORK_DIR/other-install"
if (cd "$WORK_DIR/clone" && HOME="$WORK_DIR/user" CLASHCTL_HOME="$WORK_DIR/other-install" \
    bash uninstall.sh --yes) >"$WORK_DIR/output" 2>&1; then
    fail 'source entry accepted an installation without initialization state'
fi
[ -f "$WORK_DIR/clone/.env" ] || fail 'source clone with environment was removed'
[ -f "$WORK_DIR/other-install/uninstall.sh" ] || fail 'source uninstall removed another installation'
ln -s "$WORK_DIR/clone" "$WORK_DIR/user/.clashctl"
if run_uninstall "$WORK_DIR/user/.clashctl"; then fail 'symlink to source bypassed installation check'; fi
[ -f "$WORK_DIR/clone/uninstall.sh" ] || fail 'symlink uninstall removed source'
[ ! -e "$UNINSTALL_CALLS" ] || fail 'source rejection invoked system services'
rm "$WORK_DIR/user/.clashctl"
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'source rejection changed shell integration'

# 复制安装目录不授予新目录卸载权限；软链接标记也拒绝。
cp -a "$WORK_DIR/other-install" "$WORK_DIR/copied"
if run_uninstall "$WORK_DIR/copied"; then fail 'copied installation marker was accepted'; fi
[ -d "$WORK_DIR/copied" ] || fail 'copied directory was removed'
rm "$WORK_DIR/copied/.clashctl-install"
printf '%s\n' "$WORK_DIR/copied" >"$WORK_DIR/external-marker"
ln -s "$WORK_DIR/external-marker" "$WORK_DIR/copied/.clashctl-install"
if run_uninstall "$WORK_DIR/copied"; then fail 'symlink marker was accepted'; fi
# 安装器留下的未初始化目录有真实标记，仍可清理，且不加载 preflight。
setup_install "$WORK_DIR/interrupted"
printf '%s\n' "$WORK_DIR/interrupted" >"$WORK_DIR/interrupted/.clashctl-uninitialized"
printf 'exit 77\n' >"$WORK_DIR/interrupted/scripts/preflight.sh"
run_uninstall "$WORK_DIR/interrupted" || fail 'interrupted installation cleanup failed'
grep -Fq '[ OK ] 卸载完成' "$WORK_DIR/output" || fail 'interrupted uninstall did not use installer status style'
[ ! -e "$WORK_DIR/interrupted" ] || fail 'interrupted installation remains'
[ ! -e "$UNINSTALL_CALLS" ] || fail 'interrupted install cleanup invoked system services'
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'interrupted cleanup changed shell integration'

# .env 丢失不能冒充安装中断；退出前不得操作服务、引导或目录。
setup_install "$WORK_DIR/env-lost"
printf 'CLASHCTL_KERNEL=mihomo\n' >"$WORK_DIR/env-lost/.env"
rm "$WORK_DIR/env-lost/.env"
touch "$UNINSTALL_ACTIVE"
if run_uninstall "$WORK_DIR/env-lost"; then fail 'missing environment was treated as uninitialized'; fi
[[ -d "$WORK_DIR/env-lost" && -f "$UNINSTALL_ACTIVE" ]] || fail 'missing environment cleanup changed installation state'
[ ! -e "$UNINSTALL_CALLS" ] || fail 'missing environment touched services'
grep -q '.env 缺失' "$WORK_DIR/output" || fail 'missing environment has no recovery message'
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'missing environment changed shell integration'
printf '%s\n' "$WORK_DIR/other-install" >"$WORK_DIR/env-lost/.clashctl-uninitialized"
if run_uninstall "$WORK_DIR/env-lost"; then fail 'foreign initialization marker was accepted'; fi
rm "$WORK_DIR/env-lost/.clashctl-uninitialized"
printf '%s\n' "$WORK_DIR/env-lost" >"$WORK_DIR/uninitialized-marker"
ln -s "$WORK_DIR/uninitialized-marker" "$WORK_DIR/env-lost/.clashctl-uninitialized"
if run_uninstall "$WORK_DIR/env-lost"; then fail 'symlink initialization marker was accepted'; fi
rm "$UNINSTALL_ACTIVE"

# 无效 .env 不能沿用父进程内核，也不能删目录或 Shell 引导。
setup_install "$WORK_DIR/invalid"
printf 'INIT_TYPE=systemd\n' >"$WORK_DIR/invalid/.env"
if run_uninstall "$WORK_DIR/invalid"; then fail 'missing kernel was accepted'; fi
[ -d "$WORK_DIR/invalid" ] || fail 'invalid installation was removed'
[ ! -e "$UNINSTALL_CALLS" ] || fail 'invalid environment invoked system services'
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'invalid environment changed shell integration'

printf 'CLASHCTL_KERNEL=mihomo\nreturn 1\n' >"$WORK_DIR/invalid/.env"
if run_uninstall "$WORK_DIR/invalid"; then fail 'failed environment load was ignored'; fi
[ -d "$WORK_DIR/invalid" ] || fail 'failed environment load removed installation'
printf 'CLASHCTL_KERNEL=mihomo\nCLASHCTL_HOME=%q\n' "$WORK_DIR/other-install" >"$WORK_DIR/invalid/.env"
if run_uninstall "$WORK_DIR/invalid"; then fail 'environment redirected uninstall to another directory'; fi
[ ! -e "$UNINSTALL_CALLS" ] || fail 'invalid environment touched a service'

# 正常安装：使用 .env 的 mihomo 而非父进程 clash；停服务失败时全部保留。
setup_install "$WORK_DIR/installed"
printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=systemd\n' >"$WORK_DIR/installed/.env"
printf 'ExecStart=%s/bin/mihomo -d %s/resources -f %s/data/runtime.yaml\n' "$WORK_DIR/installed" "$WORK_DIR/installed" "$WORK_DIR/installed" >"$WORK_DIR/installed/service.unit"
write_rc "$WORK_DIR/installed"
touch "$UNINSTALL_ACTIVE"
if FAIL_STOP=1 run_uninstall "$WORK_DIR/installed"; then fail 'failed service stop was ignored'; fi
grep -q '卸载中止，已保留安装目录' "$WORK_DIR/output" || fail 'failed stop omitted retained-directory result'
! grep -q '删除安装目录' "$WORK_DIR/output" || fail 'failed stop reached deletion step'
[ -f "$WORK_DIR/installed/service.unit" ] || fail 'failed stop removed service definition'
grep -q '# >>> clashctl >>>' "$WORK_DIR/user/.bashrc" || fail 'failed stop removed shell integration'
CLASHCTL_HOME="$WORK_DIR/other-install" run_uninstall "$WORK_DIR/installed" || { cat "$WORK_DIR/output"; fail 'installed cleanup failed'; }
grep -Fq '[ OK ] 卸载完成' "$WORK_DIR/output" || fail 'initialized uninstall did not use installer status style'
[ ! -d "$WORK_DIR/installed" ] || fail 'installation directory remains'
[ ! -e "$UNINSTALL_ACTIVE" ] || fail 'service was not stopped'
grep -q '^stop mihomo$' "$UNINSTALL_CALLS" || fail 'uninstall did not use stored kernel'
! grep -q clash "$UNINSTALL_CALLS" || fail 'uninstall used inherited kernel'
for rc in .bashrc .zshrc; do
    [ "$(cat "$WORK_DIR/user/$rc")" = '# user setting' ] || fail 'owned shell integration was not removed cleanly'
done
[ ! -e "$WORK_DIR/user/.config/fish/conf.d/clashctl.fish" ] || fail 'owned fish integration remains'

# 旧更新器可能只替换脚本；仍须按旧二进制路径确认服务归属后卸载。
for kernel in clash mihomo; do
    retired_home="$WORK_DIR/retired-$kernel"
    setup_install "$retired_home"
    printf 'CLASHCTL_KERNEL=%s\nINIT_TYPE=systemd\n' "$kernel" >"$retired_home/.env"
    mkdir -p "$retired_home/bin/$kernel"
    write_rc "$retired_home"
    touch "$UNINSTALL_ACTIVE"
    printf 'ExecStart=%s/bin/%s/%s -d %s/resources -f /foreign/runtime.yaml\n' \
        "$retired_home" "$kernel" "$kernel" "$retired_home" >"$retired_home/service.unit"
    if run_uninstall "$retired_home"; then fail 'retired layout bypassed foreign unit protection'; fi
    [ -f "$UNINSTALL_ACTIVE" ] || fail 'foreign unit protection stopped the service'
    printf 'ExecStart=%s/bin/%s/%s -d %s/resources -f %s/data/runtime.yaml\n' \
        "$retired_home" "$kernel" "$kernel" "$retired_home" "$retired_home" >"$retired_home/service.unit"
    if FAIL_STOP=1 run_uninstall "$retired_home"; then fail 'retired layout ignored stop failure'; fi
    [ -f "$retired_home/service.unit" ] || fail 'failed retired stop removed the unit'
    run_uninstall "$retired_home" || { cat "$WORK_DIR/output"; fail 'retired layout could not be uninstalled'; }
    [ ! -e "$retired_home" ] && [ ! -e "$UNINSTALL_ACTIVE" ] || fail 'retired layout cleanup was incomplete'
done

# TUN 停止只经现有特权接口；拒绝提权时保留目录和引导，允许重试。
setup_install "$WORK_DIR/tun"
printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\n' >"$WORK_DIR/tun/.env"
cat >>"$WORK_DIR/tun/scripts/lib/service.sh" <<'STUB'
detect_service_manager() { service_manager=nohup; }
_service_target() { return 1; }
_service_privileged_marker_exists() { [ -f "$UNINSTALL_ACTIVE" ]; }
service_is_active() { _service_privileged_marker_exists; }
service_stop() { return 0; }
service_sudo_stop() {
    printf 'privileged-stop\n' >>"$UNINSTALL_CALLS"
    [ "${FAIL_PRIVILEGED_STOP:-0}" = 0 ] || return 1
    rm -f "$UNINSTALL_ACTIVE"
}
STUB
write_rc "$WORK_DIR/tun"
touch "$UNINSTALL_ACTIVE"
if FAIL_PRIVILEGED_STOP=1 run_uninstall "$WORK_DIR/tun"; then fail 'privileged stop failure was ignored'; fi
[[ -d "$WORK_DIR/tun" && -f "$UNINSTALL_ACTIVE" ]] || fail 'failed privileged stop removed installation'
grep -q '# >>> clashctl >>>' "$WORK_DIR/user/.bashrc" || fail 'failed privileged stop removed shell integration'
run_uninstall "$WORK_DIR/tun" || fail 'privileged uninstall failed'
[[ ! -d "$WORK_DIR/tun" && ! -e "$UNINSTALL_ACTIVE" ]] || fail 'privileged uninstall retained installation or process'
grep -q '^privileged-stop$' "$UNINSTALL_CALLS" || fail 'privileged stop was not used'

# --yes 也披露删除范围；父 Shell 代理不会被子进程改变，缓存归属不明时报告并保留。
setup_install "$WORK_DIR/messages"
printf 'CLASHCTL_KERNEL=mihomo\n' >"$WORK_DIR/messages/.env"
mkdir -p "$WORK_DIR/cache/clashctl"
printf 'foreign-cache\n' >"$WORK_DIR/cache/clashctl/proxy.fish"
http_proxy=http://127.0.0.1:7890 XDG_CACHE_HOME="$WORK_DIR/cache" run_uninstall "$WORK_DIR/messages" || fail 'uninstall with proxy failed'
grep -q '将删除订阅、自定义配置、程序和日志' "$WORK_DIR/output" || fail 'missing data deletion notice'
grep -q 'unset http_proxy' "$WORK_DIR/output" || fail 'missing parent shell cleanup command'
grep -q '清除当前终端代理（bash）' "$WORK_DIR/output" || fail 'proxy hint did not identify caller shell'
! grep -q 'set -e http_proxy' "$WORK_DIR/output" || fail 'bash uninstall displayed fish commands'
grep -Fq "$WORK_DIR/cache/clashctl/proxy.fish" "$WORK_DIR/output" || fail 'residual cache was not reported'
[ "$(cat "$WORK_DIR/cache/clashctl/proxy.fish")" = foreign-cache ] || fail 'unowned cache was changed'

# 无代理时不提示清理；安装配置里设置代理也不能误报当前终端状态。
setup_install "$WORK_DIR/no-proxy"
printf 'CLASHCTL_KERNEL=mihomo\nhttp_proxy=http://config-only.example\n' >"$WORK_DIR/no-proxy/.env"
NO_PROXY=localhost run_uninstall "$WORK_DIR/no-proxy" || fail 'uninstall without inherited proxy failed'
! grep -q '清除当前终端代理' "$WORK_DIR/output" || fail 'proxy-free shell received cleanup instructions'
[ "$(tail -n 1 "$WORK_DIR/output")" = '[ OK ] 卸载完成' ] || fail 'proxy-free uninstall did not end with completion'

# 真实 Zsh/Fish 调用 Bash 卸载器时，只显示对应的清理命令。
for caller in zsh fish; do
    caller_home="$WORK_DIR/caller-$caller"
    mkdir -p "$caller_home"
    setup_install "$WORK_DIR/proxy-$caller"
    printf 'CLASHCTL_KERNEL=mihomo\n' >"$WORK_DIR/proxy-$caller/.env"
    caller_exe=$REAL_ZSH
    caller_args=(-f -c)
    caller_script='bash "$UNINSTALL_TEST_SCRIPT" --yes; uninstall_result=$?; true; exit "$uninstall_result"'
    if [ "$caller" = fish ]; then
        caller_exe=$REAL_FISH
        caller_args=(--no-config --private -c)
        caller_script='bash "$UNINSTALL_TEST_SCRIPT" --yes; set -l uninstall_result $status; true; exit $uninstall_result'
    fi
    HOME="$caller_home" http_proxy=http://127.0.0.1:7890 \
        UNINSTALL_TEST_SCRIPT="$WORK_DIR/proxy-$caller/uninstall.sh" \
        "$caller_exe" "${caller_args[@]}" "$caller_script" \
        >"$WORK_DIR/proxy-$caller.out" 2>&1 ||
        { cat "$WORK_DIR/proxy-$caller.out"; fail "$caller uninstall failed"; }
    grep -q "清除当前终端代理（$caller）" "$WORK_DIR/proxy-$caller.out" || fail 'proxy hint used wrong shell'
    if [ "$caller" = fish ]; then
        grep -q 'set -e http_proxy' "$WORK_DIR/proxy-$caller.out" || fail 'fish erase command missing'
        ! grep -q 'unset http_proxy' "$WORK_DIR/proxy-$caller.out" || fail 'fish uninstall displayed bash commands'
    else
        grep -q 'unset http_proxy' "$WORK_DIR/proxy-$caller.out" || fail 'zsh unset command missing'
        ! grep -q 'set -e http_proxy' "$WORK_DIR/proxy-$caller.out" || fail 'zsh uninstall displayed fish commands'
    fi
done

# 无法识别调用 Shell 时，保留两种清理命令供用户选择。
setup_install "$WORK_DIR/proxy-unknown"
printf 'CLASHCTL_KERNEL=mihomo\n' >"$WORK_DIR/proxy-unknown/.env"
mkdir -p "$WORK_DIR/caller-unknown"
HOME="$WORK_DIR/caller-unknown" SHELL=/bin/sh http_proxy=http://127.0.0.1:7890 \
    python3 - "$WORK_DIR/proxy-unknown/uninstall.sh" >"$WORK_DIR/proxy-unknown.out" 2>&1 <<'PY'
import subprocess, sys
raise SystemExit(subprocess.run(["bash", sys.argv[1], "--yes"]).returncode)
PY
grep -q 'bash/zsh: unset http_proxy' "$WORK_DIR/proxy-unknown.out" || fail 'unknown shell omitted bash cleanup'
grep -q 'fish: set -e http_proxy' "$WORK_DIR/proxy-unknown.out" || fail 'unknown shell omitted fish cleanup'

# 拒绝额外参数、EOF 和默认否，不能因 --yes 在首位而忽略误拼参数。
setup_install "$WORK_DIR/cancelled"
printf '%s\n' "$WORK_DIR/cancelled" >"$WORK_DIR/cancelled/.clashctl-uninitialized"
if bash "$WORK_DIR/cancelled/uninstall.sh" --yes --typo >"$WORK_DIR/output" 2>&1; then fail 'extra argument was ignored'; fi
if bash "$WORK_DIR/cancelled/uninstall.sh" </dev/null >"$WORK_DIR/output" 2>&1; then fail 'EOF confirmed uninstall'; fi
if printf '\n' | bash "$WORK_DIR/cancelled/uninstall.sh" >"$WORK_DIR/output" 2>&1; then fail 'empty input confirmed uninstall'; fi
grep -q '已取消卸载' "$WORK_DIR/output" || fail 'declining uninstall did not report cancellation'
[ -d "$WORK_DIR/cancelled" ] || fail 'cancelled uninstall removed installation'

# 已初始化的旧安装也不能清理指向其他安装的引导。
setup_install "$WORK_DIR/old"
printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=systemd\n' >"$WORK_DIR/old/.env"
write_rc "$WORK_DIR/other-install"
run_uninstall "$WORK_DIR/old" || fail 'old installation cleanup failed'
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'old installation removed other installation integration'
# Shell 清理失败也必须保留目录，不能报告成功。
setup_install "$WORK_DIR/rc-failed"
printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=systemd\n' >"$WORK_DIR/rc-failed/.env"
printf '\nrevoke_rc() { return 1; }\n' >>"$WORK_DIR/rc-failed/scripts/preflight.sh"
if run_uninstall "$WORK_DIR/rc-failed"; then fail 'failed shell cleanup was ignored'; fi
grep -q '卸载中止，已保留安装目录' "$WORK_DIR/output" || fail 'failed shell cleanup omitted retained-directory result'
[ -d "$WORK_DIR/rc-failed" ] || fail 'failed shell cleanup removed installation'
! grep -q '卸载完成' "$WORK_DIR/output" || fail 'failed shell cleanup reported success'

# 源码入口：显式环境变量优先于默认目录，只加载目标安装中的配置与库。
default_home="$WORK_DIR/user/.clashctl"
custom_home="$WORK_DIR/custom-install"
for target in "$default_home" "$custom_home"; do
    setup_install "$target"
    printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=systemd\n' >"$target/.env"
done
if CLASHCTL_HOME="$WORK_DIR/missing" run_uninstall "$WORK_DIR/clone"; then fail 'invalid explicit target fell back to default'; fi
if CLASHCTL_HOME="$WORK_DIR/clone" run_uninstall "$WORK_DIR/clone"; then fail 'source directory was accepted as explicit installation'; fi
if CLASHCTL_HOME="$default_home" run_uninstall "$WORK_DIR/copied"; then fail 'invalid local marker fell back to another installation'; fi
[[ -d "$default_home" && -d "$custom_home" ]] || fail 'invalid selection removed an installation'
ln -s "$custom_home" "$WORK_DIR/custom-link"
if printf 'n\n' | HOME="$WORK_DIR/user" CLASHCTL_HOME="$WORK_DIR/custom-link" \
    bash "$WORK_DIR/clone/uninstall.sh" >"$WORK_DIR/output" 2>&1; then
    fail 'declining detected installation still uninstalled it'
fi
grep -Fq "$custom_home" "$WORK_DIR/output" || fail 'confirmation did not show physical installation path'
[ -d "$custom_home" ] || fail 'declined installation was deleted'
CLASHCTL_HOME="$WORK_DIR/custom-link" run_uninstall "$WORK_DIR/clone" || { cat "$WORK_DIR/output"; fail 'explicit installation discovery failed'; }
[ ! -d "$custom_home" ] || fail 'explicit installation remains'
[ -d "$default_home" ] || fail 'explicit selection removed default installation'
run_uninstall "$WORK_DIR/clone" || { cat "$WORK_DIR/output"; fail 'default installation discovery failed'; }
[ ! -d "$default_home" ] || fail 'default installation remains'
[[ -f "$WORK_DIR/clone/.env" && -f "$WORK_DIR/clone/uninstall.sh" ]] || fail 'source installation discovery modified source'

# 空恢复目录不增加提示；有旧备份或失败现场时保留并说明清理路径。
recovery_home="$WORK_DIR/.clashctl-backups"
mkdir -m 0700 "$recovery_home" "$recovery_home/backups" "$recovery_home/failed"
setup_install "$WORK_DIR/empty-recovery"
printf '%s\n' "$WORK_DIR/empty-recovery" >"$WORK_DIR/empty-recovery/.clashctl-uninitialized"
run_uninstall "$WORK_DIR/empty-recovery" || fail 'uninstall with empty recovery directories failed'
! grep -q '恢复资料已保留' "$WORK_DIR/output" || fail 'empty recovery directory received cleanup hint'
mkdir "$recovery_home/backups/old-install" "$recovery_home/failed/new-install"
printf 'old subscription\n' >"$recovery_home/backups/old-install/config.yaml"
printf 'failed custom config\n' >"$recovery_home/failed/new-install/config.yaml"
setup_install "$WORK_DIR/with-recovery"
printf '%s\n' "$WORK_DIR/with-recovery" >"$WORK_DIR/with-recovery/.clashctl-uninitialized"
run_uninstall "$WORK_DIR/with-recovery" || fail 'uninstall with recovery data failed'
[ ! -e "$WORK_DIR/with-recovery" ] || fail 'uninstall retained runtime installation'
grep -qx 'old subscription' "$recovery_home/backups/old-install/config.yaml" || fail 'uninstall deleted old backup'
grep -qx 'failed custom config' "$recovery_home/failed/new-install/config.yaml" || fail 'uninstall deleted failure data'
grep -Fq "恢复资料已保留，确认无需回退后可手动清理：$recovery_home" "$WORK_DIR/output" ||
    fail 'uninstall did not identify recovery data'

printf 'uninstall-scope: ok\n'
