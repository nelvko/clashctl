#!/usr/bin/env bash
# 后端替身由 service_state 间接调用。
# shellcheck disable=SC2317
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
CHILD_PID=''
KEEPER_PID=''
KEEPER_RELEASE="$WORK_DIR/keeper-release"
cleanup() {
    if [ -n "$CHILD_PID" ]; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    if [ -n "$KEEPER_PID" ]; then
        : >"$KEEPER_RELEASE"
        wait "$KEEPER_PID" 2>/dev/null || true
    fi
    command rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../scripts/lib/operation-lock.sh
. "$REPO_DIR/scripts/lib/operation-lock.sh"
# shellcheck source=../scripts/lib/service-process.sh
. "$REPO_DIR/scripts/lib/service-process.sh"
# shellcheck source=../scripts/lib/service.sh
. "$REPO_DIR/scripts/lib/service.sh"
export CLASHCTL_KERNEL=mihomo
BIN_KERNEL="$WORK_DIR/mihomo"
CLASH_RESOURCES_DIR="$WORK_DIR/resources"
CLASH_CONFIG_RUNTIME="$WORK_DIR/runtime.yaml"
service_pid_path="$WORK_DIR/mihomo.pid"
QUERY_LOG="$WORK_DIR/queries"
STUB_OUTPUT=''
STUB_RC=0

# 首次检测各原生管理器必须成功；容器识别替身避免依赖宿主 PID 1。
(
    _is_root() { return 0; }
    grep() { return 1; }
    for manager_pair in systemd:systemd openrc-init:openrc init:sysvinit runit:runit; do
        INIT_TYPE=${manager_pair%%:*}
        service_manager=''
        detect_service_manager || fail "first detection failed: $INIT_TYPE"
        [ "$service_manager" = "${manager_pair#*:}" ] || fail "wrong manager: $INIT_TYPE"
    done
)
detect_service_manager() { :; }
_is_root() { return 0; }

# 任何非只读调用均报错，并保留调用记录供断言检查。
native_query() {
    printf '%s\n' "$*" >>"$QUERY_LOG"
    case "$*" in
    'systemctl is-active mihomo' | 'service mihomo status' | \
        'rc-service mihomo status' | 'sv status mihomo') ;;
    *) printf 'unexpected service operation\n' >&2; return 97 ;;
    esac
    printf '%s' "$STUB_OUTPUT"
    return "$STUB_RC"
}
systemctl() { native_query systemctl "$@"; }
service() { native_query service "$@"; }
rc-service() { native_query rc-service "$@"; }
sv() { native_query sv "$@"; }

assert_state() {
    local expected=$1 label=$2 output rc=0
    output=$(service_state 2>/dev/null) || rc=$?
    if [ "$expected" = unknown ]; then
        [ "$rc" -ne 0 ] || fail "$label: query failure returned success"
        [ -z "$output" ] || fail "$label: query failure printed $output"
    else
        [ "$rc" -eq 0 ] || fail "$label: query returned $rc"
        [ "$output" = "$expected" ] || fail "$label: expected $expected, got $output"
    fi
}

service_manager=systemd
STUB_OUTPUT=active STUB_RC=0 assert_state running 'systemd active'
STUB_OUTPUT=reloading STUB_RC=0 assert_state running 'systemd reloading'
STUB_OUTPUT=refreshing STUB_RC=0 assert_state running 'systemd refreshing'
STUB_OUTPUT=inactive STUB_RC=3 assert_state stopped 'systemd inactive'
STUB_OUTPUT=failed STUB_RC=3 assert_state failed 'systemd failed'
STUB_OUTPUT=unknown STUB_RC=4 assert_state unknown 'systemd missing unit'
STUB_OUTPUT=inactive STUB_RC=1 assert_state unknown 'systemd inconsistent error'
STUB_OUTPUT=activating STUB_RC=3 assert_state starting 'systemd starting'
STUB_OUTPUT=deactivating STUB_RC=3 assert_state stopping 'systemd stopping'
STUB_OUTPUT='' STUB_RC=1 assert_state unknown 'systemd communication failure'
STUB_OUTPUT=unexpected STUB_RC=0 assert_state unknown 'systemd unexpected output'

service_manager=sysvinit
STUB_RC=0 assert_state running 'SysV running'
STUB_RC=1 assert_state stopped 'SysV dead PID file'
STUB_RC=2 assert_state stopped 'SysV dead lock file'
STUB_RC=3 assert_state stopped 'SysV stopped'
STUB_RC=4 assert_state unknown 'SysV unknown status'
STUB_RC=126 assert_state unknown 'SysV permission denied'
STUB_RC=127 assert_state unknown 'SysV missing command'

service_manager=openrc
STUB_RC=0 assert_state running 'OpenRC running'
STUB_RC=3 assert_state stopped 'OpenRC stopped'
STUB_RC=4 assert_state stopping 'OpenRC stopping'
STUB_RC=8 assert_state starting 'OpenRC starting'
STUB_RC=16 assert_state stopped 'OpenRC inactive'
STUB_RC=32 assert_state failed 'OpenRC crashed'
STUB_RC=1 assert_state unknown 'OpenRC query failure'
STUB_RC=126 assert_state unknown 'OpenRC permission denied'
STUB_RC=127 assert_state unknown 'OpenRC missing command'

service_manager=runit
STUB_OUTPUT='run: mihomo: (pid 1234) 5s' STUB_RC=0 assert_state running 'runit running'
STUB_OUTPUT='down: mihomo: 5s' STUB_RC=0 assert_state stopped 'runit stopped'
STUB_OUTPUT='run: mihomo: (pid 1234) 5s' STUB_RC=1 assert_state unknown 'runit failed query'
STUB_OUTPUT='fail: mihomo: unable to change to service directory' STUB_RC=1 assert_state unknown 'runit missing service'
STUB_OUTPUT='unexpected' STUB_RC=0 assert_state unknown 'runit unexpected output'
STUB_OUTPUT='' STUB_RC=126 assert_state unknown 'runit permission denied'
STUB_OUTPUT='' STUB_RC=127 assert_state unknown 'runit missing command'

# 真正缺少管理器工具时也应返回未知，不能被当作停止。
mkdir "$WORK_DIR/empty-bin"
(
    unset -f systemctl service rc-service sv
    for service_manager in systemd sysvinit openrc runit; do
        PATH="$WORK_DIR/empty-bin" assert_state unknown "$service_manager unavailable executable"
    done
)
if grep -Ev '^(systemctl is-active mihomo|service mihomo status|rc-service mihomo status|sv status mihomo)$' "$QUERY_LOG"; then
    fail 'status invoked a service mutation'
fi

service_manager=invalid
assert_state unknown 'unsupported manager'
(
    detect_service_manager() { return 1; }
    assert_state unknown 'manager detection failure'
)

service_manager='nohup'
assert_state stopped 'nohup missing record'
printf 'malformed\n' >"$service_pid_path"
assert_state unknown 'nohup malformed record'
[ "$(cat "$service_pid_path")" = malformed ] || fail 'malformed record was modified'
[ ! -e "${service_pid_path}.lock" ] || fail 'status acquired a process lock'
rm "$service_pid_path"
ln -s "$WORK_DIR/absent" "$service_pid_path"
assert_state unknown 'nohup symlink record'
[ -L "$service_pid_path" ] || fail 'symlink record was removed'
rm "$service_pid_path"

# Python 的 -d 接受后续脚本，脚本接收 -f 参数，便于复现内核的完整 argv。
BIN_KERNEL=$(command -v python3)
printf 'import time\ntime.sleep(30)\n' >"$CLASH_RESOURCES_DIR"
"$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" >/dev/null &
CHILD_PID=$!
_service_process_record_create "$service_pid_path" "$CHILD_PID" "$BIN_KERNEL" \
    "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" || fail 'could not create process record'
before=$(sha256sum "$service_pid_path")
assert_state running 'nohup matching process'
[ "$(sha256sum "$service_pid_path")" = "$before" ] || fail 'running record was modified'
kill -0 "$CHILD_PID" || fail 'status stopped the recorded process'
(
    _service_process_record_matches_loaded() { return 1; }
    _service_process_stat() { return 1; }
    assert_state unknown 'nohup process permission failure'
)
BIN_KERNEL="$WORK_DIR/another-install/mihomo" assert_state unknown 'nohup foreign command record'
sed -i 's/^starttime=.*/starttime=0/' "$service_pid_path"
before=$(sha256sum "$service_pid_path")
assert_state stopped 'nohup reused PID'
[ "$(sha256sum "$service_pid_path")" = "$before" ] || fail 'stale record was removed'
kill -0 "$CHILD_PID" || fail 'status stopped a reused PID'
kill "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=''
assert_state stopped 'nohup exited process'

# Python 父进程暂不 wait，保留一个真正的僵尸进程供只读状态查询验证。
cat >"$WORK_DIR/keeper.py" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

child = subprocess.Popen([sys.argv[1], "-d", sys.argv[2], "-f", sys.argv[3]])
Path(sys.argv[4]).write_text(str(child.pid))
while not os.path.exists(sys.argv[5]):
    time.sleep(0.01)
child.terminate()
child.wait()
PY
python3 "$WORK_DIR/keeper.py" "$BIN_KERNEL" "$CLASH_RESOURCES_DIR" "$CLASH_CONFIG_RUNTIME" \
    "$WORK_DIR/zombie-pid" "$KEEPER_RELEASE" &
KEEPER_PID=$!
for ((attempt = 0; attempt < 100; attempt++)); do
    [ ! -s "$WORK_DIR/zombie-pid" ] || break
    sleep 0.01
done
[ -s "$WORK_DIR/zombie-pid" ] || fail 'zombie fixture did not start'
zombie_pid=$(cat "$WORK_DIR/zombie-pid")
_service_process_record_create "$service_pid_path" "$zombie_pid" "$BIN_KERNEL" \
    "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" || fail 'could not record zombie fixture'
kill "$zombie_pid"
zombie_stat=''
for ((attempt = 0; attempt < 100; attempt++)); do
    IFS= read -r zombie_stat <"/proc/$zombie_pid/stat" || fail 'zombie fixture disappeared'
    zombie_stat=${zombie_stat##*) }
    [ "${zombie_stat%% *}" != Z ] || break
    sleep 0.01
done
[ "${zombie_stat%% *}" = Z ] || fail 'fixture did not retain a zombie'
before=$(sha256sum "$service_pid_path")
assert_state stopped 'nohup zombie process'
[ "$(sha256sum "$service_pid_path")" = "$before" ] || fail 'zombie record was removed'
: >"$KEEPER_RELEASE"
wait "$KEEPER_PID"
KEEPER_PID=''

# 特权记录是非 root 不可读的安全标记；查询不能调用 sudo 或尝试清理它。
(
    _is_root() { return 1; }
    _service_record_state() { printf '%s\n' "$LOCAL_STATE"; return "$LOCAL_RC"; }
    _service_state_path_absent() {
        case "$1" in
        /run/clashctl) [ "$RUNTIME_PRESENT" -eq 0 ] ;;
        "$WORK_DIR/privileged.process") [ "$RECORD_PRESENT" -eq 0 ] ;;
        *) fail 'unexpected privileged path' ;;
        esac
    }
    _service_privileged_record_path() { printf '%s/privileged.process\n' "$WORK_DIR"; }
    _service_privileged_runtime_is_secure() { [ "$RUNTIME_SECURE" -eq 1 ]; }
    _service_privileged_record_is_secure() { [ "$RECORD_SECURE" -eq 1 ]; }
    sudo() { fail 'status requested sudo'; }
    LOCAL_STATE=stopped LOCAL_RC=0 RUNTIME_PRESENT=0 RECORD_PRESENT=0 RUNTIME_SECURE=1 RECORD_SECURE=1
    assert_state stopped 'nohup absent privileged runtime'
    RUNTIME_PRESENT=1 assert_state stopped 'nohup absent privileged marker'
    RUNTIME_PRESENT=1 RECORD_PRESENT=1 assert_state running 'nohup privileged marker'
    RUNTIME_PRESENT=1 RUNTIME_SECURE=0 assert_state unknown 'nohup insecure privileged runtime'
    RUNTIME_PRESENT=1 RECORD_PRESENT=1 RECORD_SECURE=0 assert_state unknown 'nohup insecure privileged marker'
    LOCAL_STATE='' LOCAL_RC=1 assert_state unknown 'nohup local record failure'
    LOCAL_STATE='' LOCAL_RC=1 RUNTIME_PRESENT=1 RECORD_PRESENT=1 assert_state running 'nohup secure marker with local failure'
)

printf 'service-state: ok\n'
