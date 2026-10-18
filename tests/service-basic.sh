#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
export CLASHCTL_HOME="$WORK_DIR/home" CLASHCTL_SRC="$REPO_DIR" CLASHCTL_KERNEL=mihomo INIT_TYPE=systemd
. "$REPO_DIR/scripts/lib/common.sh"
. "$REPO_DIR/scripts/lib/operation-lock.sh"
. "$REPO_DIR/scripts/lib/service-process.sh"
. "$REPO_DIR/scripts/lib/service.sh"
# 所有服务操作都限制在临时目录，不调用宿主 init。
_service_target() { printf '%s/unit.service\n' "$WORK_DIR"; }
systemctl() { :; }
service_enable() { touch "$WORK_DIR/enabled"; }
service_disable() { rm -f "$WORK_DIR/enabled"; }
service_is_active() { [ -f "$WORK_DIR/active" ]; }
service_stop() { rm -f "$WORK_DIR/active"; }
_service_unregister() { :; }

printf 'foreign unit\n' >"$WORK_DIR/unit.service"
if install_service >/dev/null 2>&1; then fail 'installer took over a foreign service'; fi
[ "$(cat "$WORK_DIR/unit.service")" = 'foreign unit' ] || fail 'foreign service changed'
if uninstall_service >/dev/null 2>&1; then fail 'uninstaller removed a foreign service'; fi
rm "$WORK_DIR/unit.service"
install_service || fail 'service installation failed'
# shellcheck disable=SC2031  # BIN_KERNEL 由上面的 common.sh 在当前 shell 中初始化。
grep -Fq "ExecStart=$BIN_KERNEL" "$WORK_DIR/unit.service" || fail 'service executable path is wrong'
[ ! -f "$WORK_DIR/enabled" ] || fail 'service was enabled before configuration'
service_enable
touch "$WORK_DIR/active"
uninstall_service || fail 'service uninstall failed'
[ ! -e "$WORK_DIR/active" ] || fail 'service was not stopped'
[ ! -e "$WORK_DIR/enabled" ] || fail 'service was not disabled'
[ ! -e "$WORK_DIR/unit.service" ] || fail 'service definition was not removed'
# runit 必须在配置就绪后加入监督目录，sv up 才能找到服务。
(
    service_manager=runit
    detect_service_manager() { :; }
    _require_base_config() { return 1; }
    if service_start >/dev/null 2>&1; then fail 'runit started without main config'; fi
    [ ! -f "$WORK_DIR/enabled" ] || fail 'runit enabled before main config'
    _require_base_config() { return 0; }
    _valid_config() { return 1; }
    if service_start >/dev/null 2>&1; then fail 'runit started without valid runtime'; fi
    [ ! -f "$WORK_DIR/enabled" ] || fail 'runit enabled before runtime validation'
    _valid_config() { return 0; }
    # shellcheck disable=SC2317  # 由 service_start 间接调用
    sv() { [ -f "$WORK_DIR/enabled" ]; }
    service_start || fail 'runit did not register before starting'
)
# root 启动失败直接返回，不能再尝试 sudo 特权启动。
(
    _is_root() { return 0; }
    service_start() { return 7; }
    _require_base_config() { fail 'root start revalidated before sudo fallback'; }
    rc=0
    service_sudo_start || rc=$?
    [ "$rc" = 7 ] || fail 'root start did not preserve failure status'
)
# 旧更新器留下的内核仅可清理，普通和特权启动入口都必须先拒绝。
for kernel in clash mihomo; do
    for start in service_start service_sudo_start; do
        (
            CLASHCTL_KERNEL=$kernel
            BIN_KERNEL="$WORK_DIR/retired-$kernel/mihomo"
            [ "$kernel" != mihomo ] || mkdir -p "$BIN_KERNEL"
            _require_base_config() { touch "$WORK_DIR/start-side-effect"; return 1; }
            systemctl() { touch "$WORK_DIR/start-side-effect"; return 1; }
            sudo() { touch "$WORK_DIR/start-side-effect"; return 1; }
            if "$start" >"$WORK_DIR/retired-start.out" 2>&1; then fail 'retired kernel/layout was started'; fi
            [ ! -e "$WORK_DIR/start-side-effect" ] || fail 'retired start reached setup or service operations'
            grep -Eq '安装器|旧版安装' "$WORK_DIR/retired-start.out" || fail 'retired start omitted recovery instructions'
        )
    done
done
printf 'service-basic: ok\n'
