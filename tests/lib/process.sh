#!/usr/bin/env bash
# 保留子进程供 /proc 查询；调用方决定何时记录身份、发送信号。
CHILD_PID='' KEEPER_PID=''
KEEPER_RELEASE="$WORK_DIR/keeper-release"
cleanup_hook() {
    if [ -n "$CHILD_PID" ]; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    if [ -n "$KEEPER_PID" ]; then
        : >"$KEEPER_RELEASE"
        wait "$KEEPER_PID" 2>/dev/null || true
    fi
}

start_keeper() {
    python3 - "$WORK_DIR/zombie-pid" "$KEEPER_RELEASE" "$@" <<'PY' &
import os
from pathlib import Path
import subprocess
import sys
import time

child = subprocess.Popen(sys.argv[3:])
Path(sys.argv[1]).write_text(str(child.pid))
while not os.path.exists(sys.argv[2]):
    time.sleep(0.01)
child.terminate()
child.wait()
PY
    KEEPER_PID=$!
    wait_until 100 test -s "$WORK_DIR/zombie-pid" || fail 'zombie fixture did not start'
    zombie_pid=$(cat "$WORK_DIR/zombie-pid")
}

process_is_zombie() {
    local zombie_stat
    IFS= read -r zombie_stat <"/proc/$1/stat" || fail 'zombie fixture disappeared'
    zombie_stat=${zombie_stat##*) }
    [ "${zombie_stat%% *}" = Z ]
}
