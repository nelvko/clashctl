#!/usr/bin/env bash
# 现代安装的嵌套 Mihomo 原地升级：真实安装入口、源码更新、进程记录与信号。
# 仅以本地仓库替代 GitHub，并用原生测试程序替代内核；不操作宿主服务。
set -euo pipefail
umask 022

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
command -v cc >/dev/null || fail 'cc is required for the native kernel fixture'
export REAL_GIT REAL_YQ
REAL_GIT=$(command -v git)
REAL_YQ=$(command -v yq)
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
        for kernel in mihomo clash; do
            if [ -f "$home/data/$kernel.pid" ]; then
                bash -c '. "$1/scripts/lib/service-process.sh"; _service_process_stop_recorded "$2"' \
                    _ "$home" "$home/data/$kernel.pid" >/dev/null 2>&1 || true
            fi
        done
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
cp "$REPO_DIR/scripts/"{install-common.sh,install-migration.sh} "$NESTED_SOURCE/scripts/"
# Native-unit tests redirect only the unit path. The implementation still selects
# its real backend, dispatches service operations, and verifies /proc identities.
cat >"$NESTED_SOURCE/scripts/lib/zz-native-fixture.sh" <<'SH'
eval "$(declare -f _service_target | sed '1s/_service_target/_fixture_original_service_target/')"
_service_target() {
    if [ -n "${NESTED_UNIT_DIR:-}" ]; then
        printf '%s/%s.service\n' "$NESTED_UNIT_DIR" "$CLASHCTL_KERNEL"
    else
        _fixture_original_service_target
    fi
}
if [ "${NESTED_FORBID_SERVICE:-0}" = 1 ]; then
    detect_service_manager() { printf 'flat upgrade queried services\n' >&2; return 90; }
    service_stop_checked() { return 90; }
fi
SH
printf 'old\n' >"$NESTED_SOURCE/fixture-version"
init_fixture_repo "$NESTED_SOURCE"
OLD_SHA=$("$REAL_GIT" -C "$NESTED_SOURCE" rev-parse HEAD)
"$REAL_GIT" -C "$NESTED_SOURCE" branch old-install
# 目标版本移动私有安装模块；旧版快照仍使用原路径。
# 保留 operation-lock.sh，真实已发布的旧 update 会检查这个文件。
python3 - "$NESTED_SOURCE" <<'RELAYOUT'
from pathlib import Path
import sys
source = Path(sys.argv[1])
renames = {
    'scripts/install-common.sh': 'scripts/upgrade-private/common.sh',
    'scripts/install-migration.sh': 'scripts/upgrade-private/migrate.sh',
}
for script in [source / 'install.sh', *(source / 'scripts').rglob('*.sh')]:
    text = script.read_text()
    for old, new in renames.items():
        text = text.replace(old, new)
    script.write_text(text)
for old, new in renames.items():
    destination = source / new
    destination.parent.mkdir(parents=True, exist_ok=True)
    (source / old).rename(destination)
RELAYOUT
printf 'new\n' >"$NESTED_SOURCE/fixture-version"
printf 'new source file\n' >"$NESTED_SOURCE/fixture-added"
"$REAL_GIT" -C "$NESTED_SOURCE" add -A
"$REAL_GIT" -C "$NESTED_SOURCE" commit -qm updated-source
NEW_SHA=$("$REAL_GIT" -C "$NESTED_SOURCE" rev-parse HEAD)

cat >"$WORK_DIR/bin/git" <<'SH'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
    case $arg in
    fetch | clone) [ "${NESTED_FAIL_FETCH:-0}" = 0 ] || exit 51 ;;
    *github.com/nelvko/clashctl.git | *github.com/nelvko/clash-for-linux-install.git) arg=$NESTED_SOURCE ;;
    esac
    args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
*github.com/nelvko/*/archive/refs/heads/*)
    destination=''
    while [ "$#" -gt 0 ]; do
        case $1 in -o) destination=$2; shift ;; esac
        shift
    done
    "$REAL_GIT" -C "$NESTED_SOURCE" archive --prefix=source/ HEAD | gzip >"$destination"
    exit
    ;;
esac
printf 'Unexpected network access: %s\n' "$*" >&2
exit 91
SH
for command in sudo loginctl service rc-service sv; do
    cp "$WORK_DIR/bin/curl" "$WORK_DIR/bin/$command"
done
cat >"$WORK_DIR/bin/yq" <<'SH'
#!/usr/bin/env bash
[ "${NESTED_NO_SYSTEM_YQ:-0}" = 0 ] || exit 127
exec "$REAL_YQ" "$@"
SH
export NESTED_CRONTAB="$WORK_DIR/crontab"
: >"$NESTED_CRONTAB"
cat >"$WORK_DIR/bin/crontab" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
-l) cat "$NESTED_CRONTAB" ;;
-r) : >"$NESTED_CRONTAB" ;;
*) cp "$1" "$NESTED_CRONTAB" ;;
esac
SH
cat >"$WORK_DIR/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -eu
[ -n "${NESTED_UNIT_DIR:-}" ] || { printf 'Unexpected host systemctl: %s\n' "$*" >&2; exit 91; }
[ "${1:-}" != --user ] || shift
printf '%s\n' "$*" >>"$NESTED_UNIT_DIR/calls"
. "$NESTED_SOURCE/scripts/lib/service-process.sh"
record="$NESTED_UNIT_DIR/process"
kernel=${CLASHCTL_KERNEL:-mihomo}
for argument in "$@"; do
    if [ "$argument" = --value ]; then
        printf "systemctl: unrecognized option '--value'\n" >&2
        exit 64
    fi
    case $argument in mihomo | mihomo.service) kernel=mihomo ;; clash | clash.service) kernel=clash ;; esac
done
case "${1:-}" in
show)
    case "$*" in
    *FragmentPath*)
        fragment=$(cat "$NESTED_UNIT_DIR/fragment")
        if [ "${fragment##*/}" != "$kernel.service" ]; then fragment=''; fi
        printf 'FragmentPath=%s\n' "$fragment"
        ;;
    *MainPID*)
        pid=$(_service_process_record_pid "$record" 2>/dev/null) || pid=0
        printf 'MainPID=%s\n' "$pid"
        ;;
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
is-enabled) [ -L "$NESTED_UNIT_DIR/default.target.wants/$kernel.service" ] ;;
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
    if [ -f "$NESTED_UNIT_DIR/$kernel.service" ]; then
        cp "$NESTED_UNIT_DIR/$kernel.service" "$NESTED_UNIT_DIR/cached-unit"
        printf '%s/%s.service\n' "$NESTED_UNIT_DIR" "$kernel" >"$NESTED_UNIT_DIR/fragment"
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
        kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
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
    ln -sf ../"$kernel".service "$NESTED_UNIT_DIR/default.target.wants/$kernel.service"
    ;;
disable) rm -f "$NESTED_UNIT_DIR/default.target.wants/$kernel.service" ;;
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
if (home / 'resources/cache.db').is_file():
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
    [ -f "$home/scripts/install-common.sh" ] && [ -f "$home/scripts/install-migration.sh" ] ||
        fail 'rollback lost the original private modules'
    assert_absent "$home/scripts/upgrade-private/common.sh" 'rollback retained the target private common module'
    assert_absent "$home/scripts/upgrade-private/migrate.sh" 'rollback retained the target private migration module'
    if [ "$method" = git ]; then
        assert_eq "$OLD_SHA" "$("$REAL_GIT" -C "$home" rev-parse HEAD)" 'rollback Git revision'
        assert_eq refs/heads/old-install "$("$REAL_GIT" -C "$home" symbolic-ref HEAD)" 'rollback Git reference'
        [ -z "$("$REAL_GIT" -C "$home" status --porcelain --untracked-files=no)" ] || fail 'rollback left tracked modifications'
    else
        (cd "$home" && sha256sum --status -c .clashctl-files) || fail 'rollback did not restore the archive manifest'
    fi
}

assert_relocated_modules() {
    local home=$1
    assert_absent "$home/scripts/install-common.sh" 'update retained the old private common module'
    assert_absent "$home/scripts/install-migration.sh" 'update retained the old private migration module'
    [ -f "$home/scripts/upgrade-private/common.sh" ] && [ -f "$home/scripts/upgrade-private/migrate.sh" ] ||
        fail 'update did not deploy the relocated private modules'
}

assert_restored_report() {
    local output=$1
    if ! grep -Fq '已恢复' "$output" || grep -Fq '无法完整恢复' "$output"; then
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
    assert_relocated_modules "$home"
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

# An initialized reinstall failure must not make the next retry start a stopped core.
home="$WORK_DIR/archive-stopped"
printf '# >>> clashctl >>>\n' >"$HOME/.bashrc"
if run_upgrade archive "$home" >"$WORK_DIR/completed-retry.out" 2>&1; then fail 'broken Shell configuration was accepted'; fi
assert_absent "$home/.clashctl-incomplete" 'refresh failure converted an initialized installation into a fresh retry'
assert_absent "$home/data/mihomo.pid" 'failed refresh started a stopped service'
printf '# preserved user settings\n' >"$HOME/.bashrc"
run_upgrade archive "$home" >"$WORK_DIR/completed-retry.out" 2>&1 || { cat "$WORK_DIR/completed-retry.out"; fail 'initialized installation could not retry'; }
assert_absent "$home/data/mihomo.pid" 'refresh retry started a stopped service'

# 新 update 在源码部署流程内调用迁移，覆盖已有脚本已加载的 Shell。
for method in git archive; do
    home="$WORK_DIR/new-update-$method"
    make_nested_install "$method" "$home"
    yq -i '.use = 1 | .profiles[0].id = 1 | del(.profiles[0].name)' "$home/data/profiles.yaml"
    [ "$method" != git ] || start_nested_kernel "$home"
    CLASHCTL_HOME="$home" CLASHCTL_SRC="$home" bash -c '
        . "$CLASHCTL_SRC/scripts/preflight.sh" &&
        . "$CLASHCTL_SRC/scripts/cmd/update.sh" && _update_scripts
    ' >"$WORK_DIR/new-update.out" 2>&1 || { cat "$WORK_DIR/new-update.out"; fail "new $method update did not migrate"; }
    assert_eq 1 "$(cat "$home/.clashctl-format")" 'new update format'
    assert_relocated_modules "$home"
    assert_eq fixture.invalid "$(yq '.use' "$home/data/profiles.yaml")" 'new update selected subscription'
    if [ "$method" = git ]; then assert_recorded_kernel "$home" mihomo;
    else assert_absent "$home/data/mihomo.pid" 'new update started a stopped service'; fi
done

# Flat installations do not execute a kernel, inspect services or copy the whole home.
# This includes an unhealthy core/configuration and a missing bin directory.
for condition in running broken missing-bin; do
    home="$WORK_DIR/flat-$condition"
    make_nested_install archive "$home"
    mv "$home/bin/mihomo/mihomo" "$WORK_DIR/flat-kernel"
    rmdir "$home/bin/mihomo"
    mv "$WORK_DIR/flat-kernel" "$home/bin/mihomo"
    if [ "$condition" = running ]; then
        "$home/bin/mihomo" -d "$home/resources" -f "$home/data/runtime.yaml" &
        flat_pid=$!
        PIDS+=("$flat_pid")
        _service_process_record_create "$home/data/mihomo.pid" "$flat_pid" "$home/bin/mihomo" \
            "$home/bin/mihomo" -d "$home/resources" -f "$home/data/runtime.yaml"
    else
        printf 'invalid: [\n' >"$home/data/config.yaml"
        chmod 0644 "$home/bin/mihomo"
        if [ "$condition" = missing-bin ]; then rm -f "$home/bin/mihomo"; rmdir "$home/bin"; fi
    fi
    snapshot_data "$home" >"$WORK_DIR/flat.before"
    NESTED_FORBID_SERVICE=1 CLASHCTL_HOME="$home" CLASHCTL_SRC="$home" bash -c '
        cp() {
            for arg in "$@"; do [ "$arg" != "$CLASHCTL_HOME" ] || return 94; done
            command cp "$@"
        }
        . "$CLASHCTL_SRC/scripts/preflight.sh" && . "$CLASHCTL_SRC/scripts/cmd/update.sh" && _update_scripts
    ' >"$WORK_DIR/flat.out" 2>&1 || { cat "$WORK_DIR/flat.out"; fail "flat $condition update failed"; }
    snapshot_data "$home" >"$WORK_DIR/flat.after"
    cmp "$WORK_DIR/flat.before" "$WORK_DIR/flat.after" || fail 'flat upgrade changed existing data'
    assert_eq 1 "$(cat "$home/.clashctl-format")" 'flat completion marker'
    assert_eq 600 "$(stat -c %a "$home/.clashctl-format")" 'marker permissions'
    [ "$condition" != running ] || assert_eq "$flat_pid" "$(_service_process_record_pid "$home/data/mihomo.pid")" 'flat running PID'
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
for scenario in resources-symlink invalid-base invalid-selection profiles-busy; do
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
    invalid-selection) yq -i '.use = 99 | .profiles[0].id = 1 | del(.profiles[0].name)' "$home/data/profiles.yaml" ;;
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

# A stopped or failed service can migrate offline despite an unusable core/config.
for state in stopped failed; do
    home="$WORK_DIR/offline-$state"
    directory="$WORK_DIR/offline-$state-unit"
    make_native_install "$home" "$directory"
    [ "$state" != failed ] || : >"$directory/failed"
    rm "$directory/default.target.wants/mihomo.service"
    chmod 0644 "$home/bin/mihomo/mihomo"
    printf 'invalid: [\n' >"$home/data/runtime.yaml"
    NESTED_UNIT_DIR="$directory" run_upgrade archive "$home" >"$WORK_DIR/offline.out" 2>&1 || {
        cat "$WORK_DIR/offline.out"; fail "offline $state migration failed";
    }
    assert_absent "$directory/process" 'offline migration started a core'
    assert_absent "$directory/default.target.wants/mihomo.service" 'offline migration enabled autostart'
    assert_eq 644 "$(stat -c %a "$home/bin/mihomo")" 'offline core mode'
    assert_not_contains "$directory/calls" 'start mihomo' 'offline migration tried to start a core'
    [ "$state" != failed ] || [ -f "$directory/failed" ] || fail 'offline migration cleared the failed state'
done

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
assert_eq 1 "$(cat "$home/.clashctl-format")" 'fresh installation format'

# Reinstall can repair a missing core without treating a stopped installation as fresh.
_service_process_stop_recorded "$home/data/mihomo.pid"
rm -f "$home/data/mihomo.pid" "$home/bin/mihomo"
run_upgrade archive "$home" >"$WORK_DIR/repair.out" 2>&1 || { cat "$WORK_DIR/repair.out"; fail 'missing core repair failed'; }
[ -x "$home/bin/mihomo" ] || fail 'reinstall did not restore the missing core'
assert_absent "$home/data/mihomo.pid" 'core repair started a stopped service'
assert_absent "$home/.clashctl-incomplete" 'core repair marked an initialized installation incomplete'

# Reinstall repairs yq after the previously borrowed system copy is removed.
kernel_hash=$(sha256sum "$home/bin/mihomo" | cut -d ' ' -f1)
snapshot_data "$home" >"$WORK_DIR/yq-repair.before"
mkdir "$WORK_DIR/yq-package"
cp "$REAL_YQ" "$WORK_DIR/yq-package/yq_linux_fixture"
tar -czf "$home/archives/yq-v4.53.3-$(uname -m).tar.gz" -C "$WORK_DIR/yq-package" yq_linux_fixture
NESTED_NO_SYSTEM_YQ=1 run_upgrade archive "$home" >"$WORK_DIR/yq-repair.out" 2>&1 || {
    cat "$WORK_DIR/yq-repair.out"; fail 'reinstall did not repair missing yq';
}
"$home/bin/yq" --version | grep -q 'mikefarah.*v4\.' || fail 'reinstall left yq unavailable'
assert_eq "$kernel_hash" "$(sha256sum "$home/bin/mihomo" | cut -d ' ' -f1)" 'yq repair kernel bytes'
assert_absent "$home/data/mihomo.pid" 'yq repair started a stopped service'
assert_absent "$home/.clashctl-incomplete" 'yq repair marked an initialized installation incomplete'
rm "$home/archives/yq-v4.53.3-$(uname -m).tar.gz"
snapshot_data "$home" >"$WORK_DIR/yq-repair.after"
cmp "$WORK_DIR/yq-repair.before" "$WORK_DIR/yq-repair.after" || fail 'yq repair changed existing user data'

# 已有 Clash 的升级只转换布局，不下载或替换内核。
for state in running stopped; do
    home="$WORK_DIR/clash-$state"
    make_nested_install archive "$home"
    mv "$home/bin/mihomo" "$home/bin/clash"
    mv "$home/bin/clash/mihomo" "$home/bin/clash/clash"
    sed -i 's/CLASHCTL_KERNEL=mihomo/CLASHCTL_KERNEL=clash/' "$home/.env"
    binary_hash=$(sha256sum "$home/bin/clash/clash" | cut -d ' ' -f1)
    if [ "$state" = running ]; then
        "$home/bin/clash/clash" -d "$home/resources" -f "$home/data/runtime.yaml" &
        PIDS+=("$!")
        _service_process_record_create "$home/data/clash.pid" "${PIDS[-1]}" "$home/bin/clash/clash" \
            "$home/bin/clash/clash" -d "$home/resources" -f "$home/data/runtime.yaml" || fail 'could not record Clash'
    fi
    run_upgrade archive "$home" >"$WORK_DIR/clash.out" 2>&1 || { cat "$WORK_DIR/clash.out"; fail 'Clash migration failed'; }
    assert_eq "$binary_hash" "$(sha256sum "$home/bin/clash" | cut -d ' ' -f1)" 'Clash kernel bytes'
    assert_contains "$home/.env" CLASHCTL_KERNEL=clash 'Clash kernel choice'
    assert_absent "$home/bin/mihomo" 'Clash migration installed Mihomo'
    if [ "$state" = running ]; then
        _service_process_record_pid "$home/data/clash.pid" >/dev/null || fail 'Clash service was lost'
    else
        assert_absent "$home/data/clash.pid" 'stopped Clash was started'
    fi
    snapshot_data "$home" >"$WORK_DIR/clash-data.before"
    CLASHCTL_HOME="$home" bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl update' \
        >"$WORK_DIR/clash-update.out" 2>&1 || { cat "$WORK_DIR/clash-update.out"; fail 'existing Clash script update failed'; }
    run_upgrade archive "$home" >"$WORK_DIR/clash-repeat.out" 2>&1 || { cat "$WORK_DIR/clash-repeat.out"; fail 'existing Clash reinstall failed'; }
    assert_eq "$binary_hash" "$(sha256sum "$home/bin/clash" | cut -d ' ' -f1)" 'repeated Clash kernel bytes'
    snapshot_data "$home" >"$WORK_DIR/clash-data.after"
    cmp "$WORK_DIR/clash-data.before" "$WORK_DIR/clash-data.after" || fail 'Clash update or reinstall changed user data'
    if [ "$state" = running ]; then
        _service_process_record_pid "$home/data/clash.pid" >/dev/null || fail 'repeated Clash install lost running service'
    else
        assert_absent "$home/data/clash.pid" 'repeated Clash install started a stopped service'
        mv "$home/bin/clash" "$WORK_DIR/saved-clash"
        if run_upgrade archive "$home" >"$WORK_DIR/clash-missing.out" 2>&1; then fail 'missing Clash kernel was silently replaced'; fi
        assert_contains "$WORK_DIR/clash-missing.out" '请恢复原 Clash 内核文件后重试' 'missing Clash repair diagnostic'
        assert_absent "$home/bin/mihomo" 'missing Clash repair switched kernels'
        assert_absent "$home/bin/clash" 'missing Clash repair downloaded a kernel'
        assert_absent "$home/.clashctl-incomplete" 'missing Clash repair changed completion state'
        CLASHCTL_HOME="$home" bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl update' \
            >"$WORK_DIR/clash-update.out" 2>&1 || { cat "$WORK_DIR/clash-update.out"; fail 'missing Clash blocked script updates'; }
        snapshot_data "$home" >"$WORK_DIR/clash-data.after"
        cmp "$WORK_DIR/clash-data.before" "$WORK_DIR/clash-data.after" || fail 'missing Clash repair changed user data'
        mv "$WORK_DIR/saved-clash" "$home/bin/clash"
        # 安装中断后从已安装的脚本离线重试：无 format 标记也只复用现有文件。
        rm "$home/.clashctl-format"
        : >"$home/.clashctl-incomplete"
        CLASHCTL_HOME="$home" NESTED_FAIL_FETCH=1 bash "$home/install.sh" --home "$home" \
            >"$WORK_DIR/clash-resume.out" 2>&1 || { cat "$WORK_DIR/clash-resume.out"; fail 'offline Clash resume failed'; }
        assert_eq "$binary_hash" "$(sha256sum "$home/bin/clash" | cut -d ' ' -f1)" 'offline Clash resume kernel bytes'
        assert_absent "$home/.clashctl-incomplete" 'offline Clash resume did not finish'
    fi
done

# 真实已发布的旧 updater：源码落位后、业务加载前完成迁移。
# 首版只测试 Bash；非 Bash 转发是后续发布才引入的功能。
for historical in 67ce07f:git:bash 67ce07f:archive:bash a33e3c3:git:zsh \
    59229ff:archive:zsh 59229ff:archive:fish d072528:git:bash cb609e8:archive:bash; do
        IFS=: read -r revision method updater_shell <<<"$historical"
        home="$WORK_DIR/old-$revision-$method-$updater_shell"
        make_nested_install "$method" "$home"
        while IFS= read -r -d '' source_file; do rm -f -- "$home/$source_file"; done <"$WORK_DIR/source-files"
        rm -rf "$home/scripts"
        rm -f "$home/fixture-version" "$home/fixture-added"
        "$REAL_GIT" -C "$REPO_DIR" archive "$revision" | tar --no-same-owner --no-same-permissions -xf - -C "$home"
        if [ "$method" = git ]; then
            "$REAL_GIT" -C "$home" add -A
            "$REAL_GIT" -C "$home" -c user.name=test -c user.email=test@example.invalid commit -qm historical-source
        else
            old_source="$WORK_DIR/source-$revision-$method-$updater_shell"
            mkdir "$old_source"
            "$REAL_GIT" -C "$REPO_DIR" archive "$revision" | tar --no-same-owner --no-same-permissions -xf - -C "$old_source"
            ( . "$REPO_DIR/install.sh"; _source_manifest "$old_source" ) >"$home/.clashctl-files"
        fi
        yq -i '.use = 1 | .profiles[0].id = 1 | del(.profiles[0].name)' "$home/data/profiles.yaml"
        start_nested_kernel "$home"
        binary_hash=$(sha256sum "$home/bin/mihomo/mihomo" | cut -d ' ' -f1)
        if [ "$revision-$method" = cb609e8-archive ]; then
            if NESTED_FAIL_FLAT_START=1 CLASHCTL_HOME="$home" bash -c '
                . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 97
                if clashctl update; then exit 98; fi
                clashctl status && clashctl log && clashctl off || exit 99
                printf "recovery-commands-ok\n"
                exit 1
            ' >"$WORK_DIR/bridge-failed.out" 2>&1; then fail 'old update bridge failure reported success'; fi
            assert_contains "$WORK_DIR/bridge-failed.out" recovery-commands-ok 'failed bridge disabled diagnostics'
            assert_absent "$home/.clashctl-format" 'failed bridge marked completion'
            [ -f "$home/bin/mihomo/mihomo" ] || fail 'failed bridge lost the original layout'
            assert_eq 1 "$(yq '.use' "$home/data/profiles.yaml")" 'failed bridge restored numeric selection'
            assert_eq new "$(cat "$home/fixture-version")" 'failed bridge retained the already deployed source'
            assert_recorded_kernel "$home" mihomo/mihomo
            # Zsh 只加载安装函数以保留诊断命令，不能误执行安装入口或留下跳过迁移的开关。
            NESTED_FAIL_FLAT_START=1 CLASHCTL_HOME="$home" zsh -c '
                if . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; then exit 97; fi
                [ "${CLASHCTL_INSTALL_RUNNING:-}" != 1 ] || exit 98
                clashctl status && clashctl log && clashctl off
            ' >"$WORK_DIR/bridge-zsh.out" 2>&1 || {
                cat "$WORK_DIR/bridge-zsh.out"; fail 'failed bridge lost Zsh diagnostics';
            }
            assert_absent "$home/.clashctl-format" 'failed Zsh bridge marked completion'
            assert_recorded_kernel "$home" mihomo/mihomo
            # 使用已落位的新版安装器重试，不再次依赖旧 updater。
            CLASHCTL_HOME="$home" bash "$home/install.sh" --home "$home" >"$WORK_DIR/bridge-retry.out" 2>&1 || {
                cat "$WORK_DIR/bridge-retry.out"; fail 'failed old bridge could not retry';
            }
        fi
        writer_pid='' watcher_pid=''
        if [ "$revision-$method" = 67ce07f-archive ]; then
            # This process represents an already loaded flock-era subscription command.
            # The disk lock library has already changed by the time the bridge runs.
            export LEGACY_WRITER_HOME="$home" LEGACY_WRITER_READY="$WORK_DIR/writer-ready" LEGACY_WRITER_RELEASE="$WORK_DIR/writer-release"
            clashsub() {
                : >"$LEGACY_WRITER_READY"
                while [ ! -e "$LEGACY_WRITER_RELEASE" ]; do sleep 0.01; done
                yq -i '.profiles[0].url = "https://fixture.invalid/sub?old-writer-finished"' "$LEGACY_WRITER_HOME/data/profiles.yaml"
            }
            export -f clashsub
            bash -c 'clashsub update' &
            writer_pid=$!
            PIDS+=("$writer_pid")
            wait_until 300 test -e "$LEGACY_WRITER_READY" || fail 'old subscription fixture did not start'
            printf "0 0 */2 * * /bin/bash -i -c 'clashsub update'\n" >"$NESTED_CRONTAB"
            (
                trap ': >"$LEGACY_WRITER_RELEASE"' EXIT
                wait_until 1000 test ! -s "$NESTED_CRONTAB" || fail 'bridge did not pause legacy cron'
                [ -d "$home/bin/mihomo" ] && [ ! -e "$home/.clashctl-format" ] || fail 'bridge migrated before draining the old writer'
                kill -0 "$writer_pid" || fail 'bridge killed the old writer'
            ) >"$WORK_DIR/writer-watcher.out" 2>&1 &
            watcher_pid=$!
            PIDS+=("$watcher_pid")
        fi
        case $updater_shell in
        fish) old_command=(fish --no-config -c 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; and clashctl update; and clashctl sub list') ;;
        *) old_command=("$updater_shell" -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl update && clashctl sub list') ;;
        esac
        PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$home" "${old_command[@]}" >"$WORK_DIR/old-update.out" 2>&1 || { cat "$WORK_DIR/old-update.out"; fail "old update failed: $revision $method"; }
        if [ -n "$writer_pid" ]; then
            wait "$watcher_pid" || { cat "$WORK_DIR/writer-watcher.out"; fail 'old-writer protection failed'; }
            wait "$writer_pid" || fail 'old subscription writer failed'
            assert_eq 'https://fixture.invalid/sub?old-writer-finished' "$(yq '.profiles[0].url' "$home/data/profiles.yaml")" 'drained subscription data'
            assert_contains "$NESTED_CRONTAB" 'clashsub update' 'old cron was not restored'
            : >"$NESTED_CRONTAB"
            unset -f clashsub
        fi
        assert_eq 1 "$(cat "$home/.clashctl-format")" 'old update completed migration'
        assert_relocated_modules "$home"
        assert_eq fixture.invalid "$(yq '.use' "$home/data/profiles.yaml")" 'old update preserved selected subscription'
        assert_eq "$binary_hash" "$(sha256sum "$home/bin/mihomo" | cut -d ' ' -f1)" 'old update kernel bytes'
        assert_recorded_kernel "$home" mihomo
        # 正常重载不依赖安装脚本，业务命令也不写元数据。
        cp "$home/data/profiles.yaml" "$WORK_DIR/expected-profiles"
        mv "$home/install.sh" "$home/install.hidden"
        mv "$home/scripts/upgrade-private/common.sh" "$home/scripts/upgrade-private/common.hidden"
        mv "$home/scripts/upgrade-private/migrate.sh" "$home/scripts/upgrade-private/migrate.hidden"
        for shell in bash zsh fish; do
            case $shell in
            fish) command=(fish --no-config -c 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; clashctl sub list') ;;
            *) command=("$shell" -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl sub list') ;;
            esac
            CLASHCTL_HOME="$home" "${command[@]}" >"$WORK_DIR/reload.out" 2>&1 || { cat "$WORK_DIR/reload.out"; fail "$shell normal reload required migration"; }
        done
        cmp "$WORK_DIR/expected-profiles" "$home/data/profiles.yaml" || fail 'normal reload changed metadata'
        mv "$home/install.hidden" "$home/install.sh"
        mv "$home/scripts/upgrade-private/common.hidden" "$home/scripts/upgrade-private/common.sh"
        mv "$home/scripts/upgrade-private/migrate.hidden" "$home/scripts/upgrade-private/migrate.sh"
done
# A real old incomplete installation must receive the new installation module before retrying.
home="$WORK_DIR/old-incomplete"
make_nested_install archive "$home"
while IFS= read -r -d '' source_file; do rm -f -- "$home/$source_file"; done <"$WORK_DIR/source-files"
rm -rf "$home/scripts"
rm -f "$home/fixture-version" "$home/fixture-added"
"$REAL_GIT" -C "$REPO_DIR" archive cb609e8 | tar --no-same-owner --no-same-permissions -xf - -C "$home"
old_source="$WORK_DIR/source-incomplete"
mkdir "$old_source"
"$REAL_GIT" -C "$REPO_DIR" archive cb609e8 | tar --no-same-owner --no-same-permissions -xf - -C "$old_source"
( . "$REPO_DIR/install.sh"; _source_manifest "$old_source" ) >"$home/.clashctl-files"
: >"$home/.clashctl-incomplete"
binary_hash=$(sha256sum "$home/bin/mihomo/mihomo" | cut -d ' ' -f1)
CLASHCTL_HOME="$home" bash "$REPO_DIR/install.sh" --home "$home" >"$WORK_DIR/old-incomplete.out" 2>&1 || {
    cat "$WORK_DIR/old-incomplete.out"; fail 'old incomplete installation could not upgrade and retry';
}
assert_eq "$binary_hash" "$(sha256sum "$home/bin/mihomo" | cut -d ' ' -f1)" 'incomplete retry kernel bytes'
assert_absent "$home/.clashctl-incomplete" 'old incomplete installation could not finish'
assert_recorded_kernel "$home" mihomo

# 没有脚本 update 的旧 master 通过重新运行安装器升级。
for state in running stopped retry; do
    home="$WORK_DIR/legacy-$state"
    make_nested_install archive "$home"
    mv "$home/bin/mihomo/mihomo" "$WORK_DIR/legacy-kernel"
    rmdir "$home/bin/mihomo"
    mv "$WORK_DIR/legacy-kernel" "$home/bin/mihomo"
    rm -rf "$home/scripts"
    for path in scripts/cmd scripts/lib scripts/init uninstall.sh; do
        "$REAL_GIT" -C "$REPO_DIR" archive 7310fb4 "$path" | tar --no-same-owner --no-same-permissions -xf - -C "$home"
    done
    rm "$home/install.sh" "$home/.clashctl-install" "$home/.clashctl-files"
    yq -i '.use = 1 | .profiles[0].id = 1 | del(.profiles[0].name)' "$home/data/profiles.yaml"
    OLD_DIR="^${home//./\\.}/data/profiles/" NEW_DIR="$home/resources/profiles/" \
        yq -i '.profiles[].path |= sub(strenv(OLD_DIR); strenv(NEW_DIR))' "$home/data/profiles.yaml"
    rm -rf "$home/resources/profiles"
    mv "$home/data/"* "$home/resources/"
    rmdir "$home/data"
    printf 'export CLASHCTL_HOME=%q\n. $CLASHCTL_HOME/scripts/cmd/clashctl.sh\n# personal setting\n' "$home" >"$HOME/.bashrc"
    binary_hash=$(sha256sum "$home/bin/mihomo" | cut -d ' ' -f1)
    if [ "$state" != stopped ]; then
        "$home/bin/mihomo" -d "$home/resources" -f "$home/resources/runtime.yaml" &
        PIDS+=("$!")
    fi
    if [ "$state" = retry ]; then
        # Shell 转换失败发生在服务已切换之后；必须恢复旧数据路径及旧进程参数。
        printf '# >>> clashctl >>>\n' >>"$HOME/.bashrc"
        if run_upgrade archive "$home" >"$WORK_DIR/legacy.out" 2>&1; then fail 'legacy shell failure was accepted'; fi
        assert_restored_report "$WORK_DIR/legacy.out"
        [ -f "$home/resources/profiles.yaml" ] || fail 'legacy rollback lost original metadata'
        assert_absent "$home/data" 'legacy rollback retained mixed layout'
        assert_absent "$home/.clashctl-format" 'legacy failure wrote format marker'
        sed -i '/# >>> clashctl >>>/d' "$HOME/.bashrc"
    fi
    run_upgrade archive "$home" >"$WORK_DIR/legacy.out" 2>&1 || { cat "$WORK_DIR/legacy.out"; fail "legacy $state migration failed"; }
    assert_eq "$binary_hash" "$(sha256sum "$home/bin/mihomo" | cut -d ' ' -f1)" 'legacy kernel bytes'
    assert_eq fixture.invalid "$(yq '.use' "$home/data/profiles.yaml")" 'legacy selected subscription'
    assert_eq "$home/data/profiles/saved.yaml" "$(yq '.profiles[0].path' "$home/data/profiles.yaml")" 'legacy profile path'
    assert_contains "$home/data/mixin.yaml" preserved-secret 'legacy Mixin'
    assert_contains "$HOME/.bashrc" '# personal setting' 'legacy shell user content'
    assert_contains "$HOME/.bashrc" '# >>> clashctl >>>' 'legacy shell managed block'
    assert_eq 0 "$(yq '.profiles // [] | length' "$home/resources/profiles.yaml")" 'source template contains old user records'
    if [ "$state" != stopped ]; then assert_recorded_kernel "$home" mihomo;
    else assert_absent "$home/data/mihomo.pid" 'legacy stopped service was started'; fi
    # 重复安装保留停止状态，不重新初始化已完成的安装。
    if [ "$state" = stopped ]; then
        run_upgrade archive "$home" >"$WORK_DIR/repeated.out" 2>&1 || { cat "$WORK_DIR/repeated.out"; fail 'repeated legacy install failed'; }
        assert_absent "$home/data/mihomo.pid" 'repeated legacy install started a stopped service'
    fi
done
printf 'install-nested-mihomo: ok (uid=%s)\n' "$(id -u)"
