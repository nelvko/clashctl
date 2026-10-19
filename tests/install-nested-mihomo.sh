#!/usr/bin/env bash
# 现代安装的嵌套 Mihomo 原地升级：真实安装入口、源码更新、进程记录与信号。
# 仅以本地仓库替代 GitHub，并用原生测试程序替代内核；不操作宿主服务。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
command -v cc >/dev/null || fail 'cc is required for the native kernel fixture'
export REAL_GIT
REAL_GIT=$(command -v git)
export CI=1 NESTED_SOURCE="$WORK_DIR/source"
export HOME="$WORK_DIR/user" XDG_CONFIG_HOME="$WORK_DIR/user/.config"
export PATH="$WORK_DIR/bin:$PATH"
unset CLASHCTL_HOME CLASHCTL_SRC CLASHCTL_INSTALL_SOURCE CLASHCTL_UPDATE_BRANCH GH_PROXY
PIDS=() HOMES=() NATIVE_DIRS=()
UPGRADE_PID='' UPGRADE_TRANSACTION_PID=''

cleanup_hook() {
    local home pid directory
    for directory in "${NATIVE_DIRS[@]}"; do : >"$directory/release"; done
    [ -z "$UPGRADE_TRANSACTION_PID" ] || kill -TERM "$UPGRADE_TRANSACTION_PID" 2>/dev/null || true
    if [ -n "$UPGRADE_PID" ]; then
        kill -TERM "$UPGRADE_PID" 2>/dev/null || true
        wait "$UPGRADE_PID" 2>/dev/null || true
    fi
    for directory in "${NATIVE_DIRS[@]}"; do
        if [ -f "$directory/process" ]; then
            bash -c '. "$1"; _service_process_stop_recorded "$2"' \
                _ "$REPO_DIR/scripts/lib/service-process.sh" "$directory/process" >/dev/null 2>&1 || true
        fi
    done
    for home in "${HOMES[@]}"; do
        if [ -f "$home/data/mihomo.pid" ]; then
            bash -c '. "$1/scripts/lib/service-process.sh"; _service_process_stop_recorded "$1/data/mihomo.pid"' \
                _ "$home" >/dev/null 2>&1 || true
        fi
    done
    for pid in "${PIDS[@]}"; do
        # These are unreaped direct children, so their PIDs cannot have been reused.
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

mkdir -p "$WORK_DIR/bin" "$HOME" "$NESTED_SOURCE"
cat >"$WORK_DIR/kernel.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) {
            puts("Mihomo Meta v1.19.27 linux fixture");
            return 0;
        }
        if (!strcmp(argv[i], "-t")) return 0;
    }
    const char *tail = "/bin/mihomo";
    size_t size = strlen(argv[0]), tail_size = strlen(tail);
    if (getenv("NESTED_FAIL_FLAT_START") && size >= tail_size &&
        !strcmp(argv[0] + size - tail_size, tail)) return 86;
    for (;;) pause();
}
C
cc -Wall -Wextra -Werror -O2 -o "$WORK_DIR/kernel" "$WORK_DIR/kernel.c"

# Copy tracked working-tree files, including the implementation under test.
"$REAL_GIT" -C "$REPO_DIR" ls-files -z >"$WORK_DIR/source-files"
tar -C "$REPO_DIR" --null -T "$WORK_DIR/source-files" -cf - |
    tar --no-same-owner --no-same-permissions -C "$NESTED_SOURCE" -xf -
# Native-unit tests redirect only the unit path. The implementation still selects
# its real backend, dispatches service operations, and verifies /proc identities.
cat >"$NESTED_SOURCE/scripts/lib/zz-native-fixture.sh" <<'SH'
eval "$(declare -f _service_target | sed '1s/_service_target/_fixture_original_service_target/')"
_service_target() {
    if [ -n "${NESTED_UNIT_DIR:-}" ]; then
        printf '%s/mihomo.service\n' "$NESTED_UNIT_DIR"
    else
        _fixture_original_service_target
    fi
}
SH
printf 'old\n' >"$NESTED_SOURCE/fixture-version"
init_fixture_repo "$NESTED_SOURCE"
OLD_SHA=$("$REAL_GIT" -C "$NESTED_SOURCE" rev-parse HEAD)
"$REAL_GIT" -C "$NESTED_SOURCE" branch old-install
printf 'new\n' >"$NESTED_SOURCE/fixture-version"
printf 'new source file\n' >"$NESTED_SOURCE/fixture-added"
"$REAL_GIT" -C "$NESTED_SOURCE" add fixture-version fixture-added
"$REAL_GIT" -C "$NESTED_SOURCE" commit -qm updated-source
NEW_SHA=$("$REAL_GIT" -C "$NESTED_SOURCE" rev-parse HEAD)

cat >"$WORK_DIR/bin/git" <<'SH'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
    case $arg in
    fetch | clone) [ "${NESTED_FAIL_FETCH:-0}" = 0 ] || exit 51 ;;
    *github.com/nelvko/clashctl.git) arg=$NESTED_SOURCE ;;
    esac
    args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'Unexpected network access: %s\n' "$*" >&2
exit 91
SH
for command in sudo loginctl service rc-service sv; do
    cp "$WORK_DIR/bin/curl" "$WORK_DIR/bin/$command"
done
cat >"$WORK_DIR/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -eu
[ -n "${NESTED_UNIT_DIR:-}" ] || { printf 'Unexpected host systemctl: %s\n' "$*" >&2; exit 91; }
[ "${1:-}" != --user ] || shift
printf '%s\n' "$*" >>"$NESTED_UNIT_DIR/calls"
. "$NESTED_SOURCE/scripts/lib/service-process.sh"
record="$NESTED_UNIT_DIR/process"
case "${1:-}" in
show)
    case "$*" in
    *FragmentPath*) cat "$NESTED_UNIT_DIR/fragment" ;;
    *MainPID*) _service_process_record_pid "$record" 2>/dev/null || printf '0\n' ;;
    *) exit 92 ;;
    esac
    ;;
is-active)
    if [ "${NESTED_STATE_FAIL_AFTER_SNAPSHOT:-0}" = 1 ]; then
        [ ! -e "$NESTED_UNIT_DIR/state-snapshot" ] || exit 1
        : >"$NESTED_UNIT_DIR/state-snapshot"
    fi
    if _service_process_record_pid "$record" >/dev/null 2>&1; then
        printf 'active\n'
    elif [ -e "$NESTED_UNIT_DIR/failed" ]; then
        printf 'failed\n'
        exit 3
    else
        printf 'inactive\n'
        exit 3
    fi
    ;;
is-enabled) [ -L "$NESTED_UNIT_DIR/default.target.wants/mihomo.service" ] ;;
daemon-reload)
    if [ "${NESTED_RELOAD_FAIL_ONCE:-0}" = 1 ] && [ ! -e "$NESTED_UNIT_DIR/reload-failed" ]; then
        : >"$NESTED_UNIT_DIR/reload-failed"
        exit 66
    fi
    if [ "${NESTED_RELOAD_BLOCK:-0}" = 1 ] && [ ! -e "$NESTED_UNIT_DIR/block-seen" ]; then
        : >"$NESTED_UNIT_DIR/block-seen"
        printf '%s\n' "$PPID" >"$NESTED_UNIT_DIR/blocked.pid"
        while [ ! -e "$NESTED_UNIT_DIR/release" ]; do sleep 0.02; done
    fi
    if [ -f "$NESTED_UNIT_DIR/mihomo.service" ]; then
        cp "$NESTED_UNIT_DIR/mihomo.service" "$NESTED_UNIT_DIR/cached-unit"
        printf '%s/mihomo.service\n' "$NESTED_UNIT_DIR" >"$NESTED_UNIT_DIR/fragment"
    else
        rm -f "$NESTED_UNIT_DIR/cached-unit"
        : >"$NESTED_UNIT_DIR/fragment"
    fi
    ;;
start)
    # A real manager treats start on an already active unit as a no-op.
    if _service_process_record_pid "$record" >/dev/null 2>&1; then exit 0; fi
    line=$(sed -n 's/^ExecStart=//p' "$NESTED_UNIT_DIR/cached-unit")
    read -r -a args <<<"$line"
    "${args[@]}" >"$NESTED_UNIT_DIR/process.log" 2>&1 &
    pid=$!
    if ! _service_process_record_create "$record" "$pid" "${args[0]}" "${args[@]}"; then
        _service_process_start_failed "$record" "$pid" || true
        if [ "${NESTED_FAIL_FLAT_START:-0}" = 1 ] && [ "${args[0]}" = "$CLASHCTL_HOME/bin/mihomo" ]; then
            : >"$NESTED_UNIT_DIR/failed"
            : >"$NESTED_UNIT_DIR/start-failed"
        fi
        exit 1
    fi
    rm -f "$NESTED_UNIT_DIR/failed"
    ;;
stop)
    [ ! -e "$record" ] || _service_process_stop_recorded "$record"
    rm -f "$record" "$NESTED_UNIT_DIR/failed"
    ;;
enable)
    mkdir -p "$NESTED_UNIT_DIR/default.target.wants"
    ln -sf ../mihomo.service "$NESTED_UNIT_DIR/default.target.wants/mihomo.service"
    ;;
disable) rm -f "$NESTED_UNIT_DIR/default.target.wants/mihomo.service" ;;
*) exit 93 ;;
esac
SH
chmod +x "$WORK_DIR/bin/"*

# shellcheck source=../scripts/lib/service-process.sh
. "$REPO_DIR/scripts/lib/service-process.sh"
# shellcheck source=../scripts/lib/operation-lock.sh
. "$REPO_DIR/scripts/lib/operation-lock.sh"

make_nested_install() {
    local method=$1 home=$2
    HOMES+=("$home")
    if [ "$method" = git ]; then
        "$REAL_GIT" clone -q --no-hardlinks --branch old-install "$NESTED_SOURCE" "$home"
    else
        mkdir -p "$home"
        "$REAL_GIT" -C "$NESTED_SOURCE" archive "$OLD_SHA" |
            tar --no-same-owner --no-same-permissions -xf - -C "$home"
        ( . "$REPO_DIR/install.sh"; _source_manifest "$home" ) >"$home/.clashctl-files"
    fi
    chmod 0700 "$home"
    install -d -m 0700 "$home/data" "$home/data/profiles" "$home/bin" "$home/bin/mihomo" "$home/archives" \
        "$home/resources/dist" "$home/resources/proxies" "$home/resources/rules"
    install -m 0755 "$WORK_DIR/kernel" "$home/bin/mihomo/mihomo"
    printf '%s\n%s\n' "$home" "$method" >"$home/.clashctl-install"
    chmod 0600 "$home/.clashctl-install"
    cat >"$home/.env" <<'ENV'
CLASHCTL_KERNEL=mihomo
INIT_TYPE=nohup
CLASHCTL_UPDATE_BRANCH=master
GH_PROXY=''
CLASHCTL_DOWNLOAD_TIMEOUT=0
CLASHCTL_SUB_UA=fixture
PRESERVE_CUSTOM_OPTION='custom value'
ENV
    chmod 0600 "$home/.env"
    cat >"$home/data/config.yaml" <<'YAML'
proxies:
  - name: saved-node
    type: direct
proxy-groups:
  - name: saved-group
    type: select
    proxies: [saved-node, DIRECT]
rules:
  - MATCH,saved-group
YAML
    cat >"$home/data/mixin.yaml" <<'YAML'
mixed-port: 0
external-controller: 127.0.0.1:0
secret: preserved-secret
tun:
  enable: false
YAML
    cp "$home/data/config.yaml" "$home/data/runtime.yaml"
    cp "$home/data/config.yaml" "$home/data/profiles/saved.yaml"
    PROFILE_PATH="$home/data/profiles/saved.yaml" yq -n \
        '.use = "saved" | .profiles = [{"name": "saved", "path": strenv(PROFILE_PATH), "url": "https://fixture.invalid/sub"}]' \
        >"$home/data/profiles.yaml"
    printf 'private user data\n' >"$home/data/untouched"
    printf 'cached ui\n' >"$home/resources/dist/index.html"
    printf 'cached database\n' >"$home/resources/cache.db"
    printf 'cached proxies\n' >"$home/resources/proxies/keep.yaml"
    printf 'cached rules\n' >"$home/resources/rules/keep.yaml"
    printf 'cached archive\n' >"$home/archives/keep"
    chmod 0600 "$home/data/"*.yaml "$home/data/profiles/saved.yaml" "$home/data/untouched"
}

start_nested_kernel() {
    local home=$1
    "$home/bin/mihomo/mihomo" -d "$home/resources" -f "$home/data/runtime.yaml" \
        >"$home/data/mihomo.log" 2>&1 &
    STARTED_PID=$!
    PIDS+=("$STARTED_PID")
    _service_process_record_create "$home/data/mihomo.pid" "$STARTED_PID" \
        "$home/bin/mihomo/mihomo" "$home/bin/mihomo/mihomo" \
        -d "$home/resources" -f "$home/data/runtime.yaml" || fail 'could not record the nested kernel'
}

snapshot_data() {
    python3 - "$1" <<'PY'
import hashlib
import json
from pathlib import Path
import stat
import sys

home = Path(sys.argv[1])
files = [home / '.env', home / '.clashctl-install']
for relative in ['data', 'archives', 'resources/dist', 'resources/proxies', 'resources/rules']:
    files.extend(p for p in (home / relative).rglob('*') if p.is_file()
                 and not p.name.endswith(('.pid', '.log')) and '.lock.d' not in str(p))
files.append(home / 'resources/cache.db')
print(json.dumps({str(p.relative_to(home)): [hashlib.sha256(p.read_bytes()).hexdigest(),
                 stat.S_IMODE(p.stat().st_mode)] for p in files}, sort_keys=True))
PY
}

run_upgrade() {
    local method=$1 home=$2
    if [ "$method" = git ]; then
        CLASHCTL_HOME="$home" bash "$REPO_DIR/install.sh" --home "$home" --branch master
    else
        CLASHCTL_HOME="$home" bash "$NESTED_SOURCE/install.sh" --local --home "$home"
    fi
}

assert_recorded_kernel() {
    local home=$1 layout=$2 pid expected
    pid=$(_service_process_record_pid "$home/data/mihomo.pid") || fail "$layout kernel is not running"
    expected=$(_service_process_values_argv_hex "$home/bin/$layout" -d "$home/resources" -f "$home/data/runtime.yaml")
    _service_process_snapshot "$pid" "$home/bin/$layout" "$expected" || fail "$layout kernel has an unexpected identity"
}

assert_original_source() {
    local method=$1 home=$2
    [ "$(cat "$home/fixture-version")" = old ] || fail 'failure retained updated source'
    assert_absent "$home/fixture-added" 'failure retained a newly added source file'
    if [ "$method" = git ]; then
        assert_eq "$OLD_SHA" "$("$REAL_GIT" -C "$home" rev-parse HEAD)" 'rollback Git revision'
        assert_eq refs/heads/old-install "$("$REAL_GIT" -C "$home" symbolic-ref HEAD)" 'rollback Git reference'
        [ -z "$("$REAL_GIT" -C "$home" status --porcelain --untracked-files=no)" ] || fail 'rollback left tracked modifications'
    else
        (cd "$home" && sha256sum --status -c .clashctl-files) || fail 'rollback did not restore the archive manifest'
    fi
}

assert_restored_report() {
    local output=$1
    if ! grep -Fq '升级未完成，已恢复原安装及服务状态' "$output" || grep -Fq '无法完整恢复' "$output"; then
        cat "$output" >&2
        fail 'completed rollback did not report successful restoration'
    fi
}

for scenario in git-running archive-stopped; do
    method=${scenario%%-*}
    home="$WORK_DIR/$scenario"
    make_nested_install "$method" "$home"
    if [ "$scenario" = git-running ]; then start_nested_kernel "$home"; fi
    snapshot_data "$home" >"$WORK_DIR/$scenario.before"
    binary_hash=$(sha256sum "$home/bin/mihomo/mihomo" | cut -d ' ' -f1)
    run_upgrade "$method" "$home" >"$WORK_DIR/$scenario.out" 2>&1 || {
        cat "$WORK_DIR/$scenario.out" >&2; fail "$scenario upgrade failed"
    }
    if [ ! -f "$home/bin/mihomo" ] || [ ! -x "$home/bin/mihomo" ]; then fail 'upgrade did not flatten the kernel'; fi
    assert_eq "$binary_hash" "$(sha256sum "$home/bin/mihomo" | cut -d ' ' -f1)" 'preserved kernel bytes'
    assert_eq new "$(cat "$home/fixture-version")" 'updated source'
    [ -f "$home/fixture-added" ] || fail 'upgrade did not apply the complete source update'
    snapshot_data "$home" >"$WORK_DIR/$scenario.after"
    cmp "$WORK_DIR/$scenario.before" "$WORK_DIR/$scenario.after" || fail 'upgrade changed user data'
    if [ "$method" = git ]; then
        assert_eq "$NEW_SHA" "$("$REAL_GIT" -C "$home" rev-parse HEAD)" 'updated Git revision'
        assert_recorded_kernel "$home" mihomo
    else
        assert_absent "$home/data/mihomo.pid" 'stopped upgrade started a kernel'
        (cd "$home" && sha256sum --status -c .clashctl-files) || fail 'upgrade did not update the archive manifest'
    fi
done

# A failed source download must leave even the original process identity untouched.
home="$WORK_DIR/fetch-failed"
make_nested_install git "$home"
start_nested_kernel "$home"
old_pid=$STARTED_PID
cp "$home/data/mihomo.pid" "$WORK_DIR/fetch.record"
snapshot_data "$home" >"$WORK_DIR/fetch.before"
if NESTED_FAIL_FETCH=1 run_upgrade git "$home" >"$WORK_DIR/fetch.out" 2>&1; then
    fail 'failed source download was accepted'
fi
cmp "$WORK_DIR/fetch.record" "$home/data/mihomo.pid" || fail 'source failure restarted the original process'
assert_eq "$old_pid" "$(_service_process_record_pid "$home/data/mihomo.pid")" 'source failure PID'
assert_original_source git "$home"
snapshot_data "$home" >"$WORK_DIR/fetch.after"
cmp "$WORK_DIR/fetch.before" "$WORK_DIR/fetch.after" || fail 'source failure changed user data'

# Service restart is outside the update helper, so both installation methods need
# an outer rollback after the updated flat kernel fails to start.
for method in git archive; do
    home="$WORK_DIR/start-failed-$method"
    make_nested_install "$method" "$home"
    start_nested_kernel "$home"
    snapshot_data "$home" >"$WORK_DIR/start-$method.before"
    if NESTED_FAIL_FLAT_START=1 run_upgrade "$method" "$home" >"$WORK_DIR/start-$method.out" 2>&1; then
        fail "$method startup failure was accepted"
    fi
    assert_restored_report "$WORK_DIR/start-$method.out"
    [ -f "$home/bin/mihomo/mihomo" ] || {
        cat "$WORK_DIR/start-$method.out" >&2; fail 'startup failure did not restore the nested binary'
    }
    assert_recorded_kernel "$home" mihomo/mihomo
    assert_original_source "$method" "$home"
    snapshot_data "$home" >"$WORK_DIR/start-$method.after"
    cmp "$WORK_DIR/start-$method.before" "$WORK_DIR/start-$method.after" || fail 'startup failure changed user data'
done

# Unknown files in the nested directory and a valid record for a foreign
# executable must be rejected before moving files or signalling any process.
for scenario in unsafe foreign; do
    home="$WORK_DIR/$scenario"
    make_nested_install archive "$home"
    start_nested_kernel "$home"
    own_pid=$STARTED_PID
    if [ "$scenario" = unsafe ]; then
        printf 'user file\n' >"$home/bin/mihomo/keep"
    else
        install -m 0755 "$WORK_DIR/kernel" "$WORK_DIR/foreign-kernel"
        "$WORK_DIR/foreign-kernel" -d "$home/resources" -f "$home/data/runtime.yaml" &
        foreign_pid=$!
        PIDS+=("$foreign_pid")
        _service_process_record_create "$home/data/mihomo.pid" "$foreign_pid" \
            "$WORK_DIR/foreign-kernel" "$WORK_DIR/foreign-kernel" \
            -d "$home/resources" -f "$home/data/runtime.yaml" || fail 'could not record the foreign process'
    fi
    cp "$home/data/mihomo.pid" "$WORK_DIR/$scenario.record"
    if run_upgrade archive "$home" >"$WORK_DIR/$scenario.out" 2>&1; then fail "$scenario installation was accepted"; fi
    kill -0 "$own_pid" || fail "$scenario rejection stopped the original nested process"
    cmp "$WORK_DIR/$scenario.record" "$home/data/mihomo.pid" || fail "$scenario rejection changed the process record"
    [ "$scenario" != foreign ] || kill -0 "$foreign_pid" || fail 'upgrade signalled a foreign process'
    assert_original_source archive "$home"
done

# Preflight rejection must not restart the original process, write through a
# resources symlink, or take ownership of another subscription operation's lock.
for scenario in resources-symlink invalid-base profiles-busy; do
    home="$WORK_DIR/$scenario"
    make_nested_install archive "$home"
    start_nested_kernel "$home"
    old_pid=$STARTED_PID
    case $scenario in
    resources-symlink)
        external="$WORK_DIR/external-resources"
        mv "$home/resources" "$external"
        printf 'external sentinel\n' >"$external/sentinel"
        ln -s "$external" "$home/resources"
        tar -cf "$WORK_DIR/external.before.tar" -C "$external" .
        ;;
    invalid-base) printf 'mode: rule\n' >"$home/data/config.yaml" ;;
    profiles-busy)
        held_lock="$home/data/profiles.lock.d"
        _directory_lock_acquire "$held_lock" 0 || fail 'could not hold the subscription lock'
        held_pid=$_DIRECTORY_LOCK_PID held_token=$_DIRECTORY_LOCK_TOKEN
        cp "$held_lock/owner" "$WORK_DIR/profiles.owner"
        ;;
    esac
    cp "$home/data/mihomo.pid" "$WORK_DIR/$scenario.record"
    snapshot_data "$home" >"$WORK_DIR/$scenario.before"
    if run_upgrade archive "$home" >"$WORK_DIR/$scenario.out" 2>&1; then fail "$scenario preflight was accepted"; fi
    assert_eq "$old_pid" "$(_service_process_record_pid "$home/data/mihomo.pid")" "$scenario original PID"
    cmp "$WORK_DIR/$scenario.record" "$home/data/mihomo.pid" || fail "$scenario rejection rewrote the process record"
    assert_original_source archive "$home"
    snapshot_data "$home" >"$WORK_DIR/$scenario.after"
    cmp "$WORK_DIR/$scenario.before" "$WORK_DIR/$scenario.after" || fail "$scenario rejection changed user data"
    if [ "$scenario" = resources-symlink ]; then
        [ -L "$home/resources" ] || fail 'preflight replaced the resources symlink'
        tar -df "$WORK_DIR/external.before.tar" -C "$external" || fail 'preflight changed external resources'
    elif [ "$scenario" = profiles-busy ]; then
        cmp "$WORK_DIR/profiles.owner" "$held_lock/owner" || fail 'migration changed another operation lock owner'
        assert_eq 700 "$(stat -c %a "$held_lock")" 'retained subscription lock permissions'
        _directory_lock_release "$held_lock" "$held_pid" "$held_token" || fail 'could not release the retained subscription lock'
    fi
done

# Retain systemd's cached fragment even when the file disappears: a migration
# which unregisters the old unit and then treats that cache as foreign must fail.
make_native_install() {
    local home=$1 directory=$2
    make_nested_install archive "$home"
    install -d -m 0700 "$directory" "$directory/default.target.wants"
    NATIVE_DIRS+=("$directory")
    if [ "$(id -u)" -eq 0 ]; then NATIVE_BACKEND=systemd; else NATIVE_BACKEND=systemd-user; fi
    sed -i "s/^INIT_TYPE=.*/INIT_TYPE=$NATIVE_BACKEND/" "$home/.env"
    cat >"$directory/mihomo.service" <<UNIT
[Unit]
Description=Preserve this custom service

[Service]
Type=simple
ExecStart=$home/bin/mihomo/mihomo -d $home/resources -f $home/data/runtime.yaml
Restart=always
Environment="KEEP=custom value"
MemoryMax=128M

[Install]
WantedBy=default.target
UNIT
    chmod 0640 "$directory/mihomo.service"
    cp -p "$directory/mihomo.service" "$directory/original-unit"
    cp "$directory/mihomo.service" "$directory/cached-unit"
    printf '%s/mihomo.service\n' "$directory" >"$directory/fragment"
    ln -s ../mihomo.service "$directory/default.target.wants/mihomo.service"
    : >"$directory/calls"
}

assert_native_running() {
    local home=$1 directory=$2 layout=$3 pid expected
    pid=$(_service_process_record_pid "$directory/process") || fail 'native fixture kernel is not running'
    expected=$(_service_process_values_argv_hex "$home/bin/$layout" -d "$home/resources" -f "$home/data/runtime.yaml")
    _service_process_snapshot "$pid" "$home/bin/$layout" "$expected" || fail 'native service has an unexpected process identity'
}

assert_native_settings() {
    local directory=$1 expected=$2
    cmp "$expected" "$directory/mihomo.service" || fail 'native unit custom settings changed'
    assert_eq 640 "$(stat -c %a "$directory/mihomo.service")" 'native unit permissions'
    assert_eq ../mihomo.service "$(readlink "$directory/default.target.wants/mihomo.service")" 'native service autostart link'
    if grep -qE '^(enable|disable)( |$)' "$directory/calls"; then fail 'migration changed native autostart state'; fi
}

home="$WORK_DIR/native-running"
directory="$WORK_DIR/native-running-unit"
make_native_install "$home" "$directory"
NESTED_UNIT_DIR="$directory" systemctl start mihomo
snapshot_data "$home" >"$WORK_DIR/native.before"
NESTED_UNIT_DIR="$directory" run_upgrade archive "$home" >"$WORK_DIR/native.out" 2>&1 || {
    cat "$WORK_DIR/native.out" >&2; fail 'native service migration failed'
}
sed "s#$home/bin/mihomo/mihomo#$home/bin/mihomo#g" "$directory/original-unit" >"$directory/expected-unit"
assert_native_settings "$directory" "$directory/expected-unit"
assert_native_running "$home" "$directory" mihomo
snapshot_data "$home" >"$WORK_DIR/native.after"
cmp "$WORK_DIR/native.before" "$WORK_DIR/native.after" || fail 'native upgrade changed user data'

# A failed reload must restore both the original unit and the original running
# or stopped state. Failure is one-shot so rollback can reload the restored unit.
for state in running stopped; do
    home="$WORK_DIR/native-reload-$state"
    directory="$WORK_DIR/native-reload-$state-unit"
    make_native_install "$home" "$directory"
    if [ "$state" = running ]; then NESTED_UNIT_DIR="$directory" systemctl start mihomo; fi
    : >"$directory/calls"
    snapshot_data "$home" >"$WORK_DIR/native-reload-$state.before"
    if NESTED_UNIT_DIR="$directory" NESTED_RELOAD_FAIL_ONCE=1 run_upgrade archive "$home" \
        >"$WORK_DIR/native-reload-$state.out" 2>&1; then fail 'native daemon-reload failure was accepted'; fi
    assert_restored_report "$WORK_DIR/native-reload-$state.out"
    [ -e "$directory/reload-failed" ] || fail 'native migration did not reach daemon-reload'
    assert_native_settings "$directory" "$directory/original-unit"
    assert_original_source archive "$home"
    [ -f "$home/bin/mihomo/mihomo" ] || fail 'reload failure did not restore nested layout'
    if [ "$state" = running ]; then
        assert_native_running "$home" "$directory" mihomo/mihomo
    else
        assert_absent "$directory/process" 'reload rollback started a previously stopped native service'
        assert_not_contains "$directory/calls" 'start mihomo' 'reload rollback started a previously stopped native service'
    fi
    snapshot_data "$home" >"$WORK_DIR/native-reload-$state.after"
    cmp "$WORK_DIR/native-reload-$state.before" "$WORK_DIR/native-reload-$state.after" || fail 'native rollback changed user data'
done

# Native managers retain a failed state after an unsuccessful start. Recovery
# must explicitly stop that failed unit before restoring its old executable.
home="$WORK_DIR/native-start-failed"
directory="$WORK_DIR/native-start-failed-unit"
make_native_install "$home" "$directory"
NESTED_UNIT_DIR="$directory" systemctl start mihomo
snapshot_data "$home" >"$WORK_DIR/native-start-failed.before"
if NESTED_UNIT_DIR="$directory" NESTED_FAIL_FLAT_START=1 run_upgrade archive "$home" \
    >"$WORK_DIR/native-start-failed.out" 2>&1; then fail 'native startup failure was accepted'; fi
assert_restored_report "$WORK_DIR/native-start-failed.out"
[ -e "$directory/start-failed" ] || fail 'native startup failure injection was not reached'
assert_absent "$directory/failed" 'rollback retained the failed native service state'
assert_native_settings "$directory" "$directory/original-unit"
assert_original_source archive "$home"
assert_native_running "$home" "$directory" mihomo/mihomo
snapshot_data "$home" >"$WORK_DIR/native-start-failed.after"
cmp "$WORK_DIR/native-start-failed.before" "$WORK_DIR/native-start-failed.after" || fail 'native startup rollback changed user data'

# Losing the manager connection after the initial snapshot must not be mistaken
# for a stopped service, followed by replacing a still-running executable.
home="$WORK_DIR/native-state-failed"
directory="$WORK_DIR/native-state-failed-unit"
make_native_install "$home" "$directory"
NESTED_UNIT_DIR="$directory" systemctl start mihomo
old_pid=$(_service_process_record_pid "$directory/process")
cp "$directory/process" "$directory/original-process"
: >"$directory/calls"
snapshot_data "$home" >"$WORK_DIR/state-failed.before"
if NESTED_UNIT_DIR="$directory" NESTED_STATE_FAIL_AFTER_SNAPSHOT=1 run_upgrade archive "$home" \
    >"$WORK_DIR/state-failed.out" 2>&1; then fail 'failed native state query was treated as a stopped service'; fi
cmp "$directory/original-process" "$directory/process" || fail 'failed native state query changed the original process record'
assert_eq "$old_pid" "$(_service_process_record_pid "$directory/process")" 'native state failure original PID'
assert_native_running "$home" "$directory" mihomo/mihomo
assert_native_settings "$directory" "$directory/original-unit"
assert_original_source archive "$home"
snapshot_data "$home" >"$WORK_DIR/state-failed.after"
cmp "$WORK_DIR/state-failed.before" "$WORK_DIR/state-failed.after" || fail 'failed native state query changed user data'
assert_not_contains "$directory/calls" 'stop mihomo' 'failed native state query stopped an unconfirmed service'

# Deliver TERM after the unit has been rewritten but before reload completes.
# The cached ExecStart remains old until reload, as with a native manager.
home="$WORK_DIR/native-signal"
directory="$WORK_DIR/native-signal-unit"
make_native_install "$home" "$directory"
NESTED_UNIT_DIR="$directory" systemctl start mihomo
snapshot_data "$home" >"$WORK_DIR/signal.before"
NESTED_UNIT_DIR="$directory" NESTED_RELOAD_BLOCK=1 run_upgrade archive "$home" \
    >"$WORK_DIR/signal.out" 2>&1 &
UPGRADE_PID=$!
wait_until 1000 test -s "$directory/blocked.pid" || fail 'signal fixture did not reach daemon-reload'
read -r UPGRADE_TRANSACTION_PID <"$directory/blocked.pid"
kill -TERM "$UPGRADE_TRANSACTION_PID"
: >"$directory/release"
rc=0
wait "$UPGRADE_PID" || rc=$?
UPGRADE_PID='' UPGRADE_TRANSACTION_PID=''
[ "$rc" -ne 0 ] || fail 'interrupted native migration returned success'
assert_restored_report "$WORK_DIR/signal.out"
assert_native_settings "$directory" "$directory/original-unit"
assert_original_source archive "$home"
assert_native_running "$home" "$directory" mihomo/mihomo
snapshot_data "$home" >"$WORK_DIR/signal.after"
cmp "$WORK_DIR/signal.before" "$WORK_DIR/signal.after" || fail 'signal rollback changed user data'
assert_absent "$home/data/profiles.lock.d" 'signal rollback leaked the subscription lock'
lock_base=$(_operation_lock_base "$EUID")
assert_absent "$lock_base/clashctl-operation-$EUID/operation.lock.d" 'signal rollback leaked the lifecycle lock'

# A flat fresh installation still follows its normal initialization path and
# obtains its lifecycle lock after the interrupted migration has released it.
home="$WORK_DIR/fresh"
HOMES+=("$home")
install -d -m 0700 "$home" "$home/archives"
case $(uname -m) in
x86_64) arch=amd64-v1 ;;
aarch64) arch=arm64 ;;
armv7*) arch=armv7 ;;
i?86) arch=386 ;;
*) fail 'unsupported architecture for the offline kernel fixture' ;;
esac
gzip -c "$WORK_DIR/kernel" >"$home/archives/mihomo-linux-$arch-v1.19.27.gz"
INIT_TYPE=nohup CLASHCTL_HOME="$home" bash "$NESTED_SOURCE/install.sh" --local --home "$home" --service nohup \
    >"$WORK_DIR/fresh.out" 2>&1 || { cat "$WORK_DIR/fresh.out" >&2; fail 'normal fresh installation failed'; }
[ -f "$home/bin/mihomo" ] || fail 'fresh installation did not use the flat layout'
assert_recorded_kernel "$home" mihomo
assert_absent "$home/.clashctl-incomplete" 'fresh installation was left incomplete'
printf 'install-nested-mihomo: ok (uid=%s)\n' "$(id -u)"
