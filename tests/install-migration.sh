#!/usr/bin/env bash
# 安装侧元数据与 Shell 迁移：真实 yq、重复执行和旧默认目录识别。
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
SOURCE_REPO=$REPO_DIR
mkdir -p "$WORK_DIR/user"
# 元数据转换保持名称唯一、当前选择及订阅路径，重复运行不再改文件。
export CLASHCTL_HOME="$WORK_DIR/metadata" CLASHCTL_SRC="$SOURCE_REPO" HOME="$WORK_DIR/user"
mkdir -p "$CLASHCTL_HOME/data/profiles"
. "$REPO_DIR/install.sh"
. "$REPO_DIR/scripts/install-migration.sh"
. "$REPO_DIR/scripts/lib/common.sh"
cat >"$CLASH_PROFILES_META" <<'YAML'
use: 2
profiles:
  - id: 1
    name: example.invalid
    url: https://example.invalid/a
    path: /preserved/a.yaml
  - id: 2
    url: https://example.invalid/b
    path: /preserved/b.yaml
YAML
_install_migrate_profiles || fail 'numeric index migration failed'
assert_eq example.invalid-2 "$("$BIN_YQ" '.use' "$CLASH_PROFILES_META")" 'current subscription'
assert_eq /preserved/b.yaml "$("$BIN_YQ" '.profiles[1].path' "$CLASH_PROFILES_META")" 'subscription path'
assert_eq false "$("$BIN_YQ" '.profiles[0] | has("id")' "$CLASH_PROFILES_META")" 'removed legacy id'
cp -p "$CLASH_PROFILES_META" "$WORK_DIR/profiles.expected"
_install_migrate_profiles || fail 'repeated metadata migration failed'
cmp "$WORK_DIR/profiles.expected" "$CLASH_PROFILES_META" || fail 'repeated migration changed metadata'

# A failed ID mapping must leave the original file untouched for a safe retry.
printf 'use: 99\nprofiles: [{id: 1, url: "https://example.invalid/a"}]\n' >"$CLASH_PROFILES_META"
cp -p "$CLASH_PROFILES_META" "$WORK_DIR/profiles.invalid"
if _install_migrate_profiles; then fail 'missing selected ID was silently discarded'; fi
cmp "$WORK_DIR/profiles.invalid" "$CLASH_PROFILES_META" || fail 'failed metadata conversion modified the original'
yq -i '.use = 1' "$CLASH_PROFILES_META"
_install_migrate_profiles || fail 'metadata migration could not retry'

printf 'export CLASHCTL_HOME=%q\n. $CLASHCTL_HOME/scripts/cmd/clashctl.sh\n# keep\n' "$CLASHCTL_HOME" >"$HOME/.bashrc"
printf '# no trailing newline' >"$HOME/.zshrc"
mkdir -p "$HOME/.config/fish/conf.d"
CLASHCTL_CMD_DIR="$REPO_DIR/scripts/cmd"
{
    printf '%s\n' "$CLASHCTL_FISH_MANAGED_MARKER"
    _fish_home_export
    printf '# historical embedded wrappers\n'
} >"$HOME/.config/fish/conf.d/clashctl.fish"
_install_migrate_shell_rc || fail 'legacy shell integration migration failed'
grep -Fq '# >>> clashctl >>>' "$HOME/.bashrc" || fail 'legacy shell integration was not converted'
grep -Fq '# keep' "$HOME/.bashrc" || fail 'shell migration removed user content'
assert_eq '# no trailing newline' "$(cat "$HOME/.zshrc")" 'unrelated shell configuration'
assert_eq 21 "$(wc -c <"$HOME/.zshrc" | tr -d ' ')" 'unrelated shell bytes'
cp "$HOME/.bashrc" "$WORK_DIR/bashrc.expected"
cp "$HOME/.config/fish/conf.d/clashctl.fish" "$WORK_DIR/fish.expected"
assert_not_contains "$WORK_DIR/fish.expected" '# historical embedded wrappers' 'Fish wrappers were not migrated'
assert_contains "$WORK_DIR/fish.expected" 'function clashoff' 'Fish wrappers missing'
_install_migrate_shell_rc || fail 'repeated shell migration failed'
cmp "$WORK_DIR/bashrc.expected" "$HOME/.bashrc" || fail 'repeated shell migration changed configuration'
cmp "$WORK_DIR/fish.expected" "$HOME/.config/fish/conf.d/clashctl.fish" || fail 'repeated Fish migration changed configuration'

# 旧默认目录中的嵌套布局应引导使用原目录，而不是要求卸载重装。
home="$HOME/clashctl"
mkdir "$home"
cp -R "$SOURCE_REPO/scripts" "$home/"
cp "$SOURCE_REPO/"{install.sh,uninstall.sh,.env.example} "$home/"
printf '%s\ngit\n' "$home" >"$home/.clashctl-install"
chmod 0600 "$home/.clashctl-install"
printf 'CLASHCTL_KERNEL=mihomo\n' >"$home/.env"
mkdir -p "$home/bin/mihomo"
if env -u CLASHCTL_HOME bash "$REPO_DIR/install.sh" >"$WORK_DIR/default.out" 2>&1; then fail 'default-home check unexpectedly installed'; fi
grep -Fq -- "--home $home" "$WORK_DIR/default.out" || { cat "$WORK_DIR/default.out"; fail 'nested default home was misclassified'; }
if grep -q '卸载' "$WORK_DIR/default.out"; then fail 'supported default home requested uninstall'; fi
printf 'CLASHCTL_KERNEL=clash\n' >"$home/.env"
cp "$home/.env" "$WORK_DIR/kernel-option.expected"
if bash "$REPO_DIR/install.sh" --home "$home" --kernel mihomo >"$WORK_DIR/kernel-option.out" 2>&1; then
    fail 'reinstallation accepted a different kernel'
fi
assert_contains "$WORK_DIR/kernel-option.out" '已有安装不支持切换内核' 'kernel change diagnosis'
cmp "$WORK_DIR/kernel-option.expected" "$home/.env" || fail 'kernel option changed the old configuration'
# TERM during the old updater bridge's lock acquisition must allow a retry.
bridge_home="$WORK_DIR/bridge"
export BRIDGE_LOCK_BASE="$WORK_DIR/bridge-locks"
mkdir -p "$bridge_home/scripts/lib"
mkdir -m 0700 "$BRIDGE_LOCK_BASE"
cp "$REPO_DIR/scripts/install-common.sh" "$bridge_home/scripts/"
cp "$REPO_DIR/scripts/lib/operation-lock.sh" "$bridge_home/scripts/lib/"
cat >>"$bridge_home/scripts/lib/operation-lock.sh" <<'SH'
_operation_lock_base() { printf '%s\n' "$BRIDGE_LOCK_BASE"; }
eval "$(declare -f _directory_lock_acquire_inner | sed '1s/_directory_lock_acquire_inner/_fixture_acquire_inner/')"
_directory_lock_acquire_inner() {
    _fixture_acquire_inner "$@" || return
    [ "${BRIDGE_SIGNAL:-}" != TERM ] || kill -TERM "$BASHPID"
}
SH
printf '1\n' >"$bridge_home/.clashctl-format"
rc=0
BRIDGE_SIGNAL=TERM CLASHCTL_HOME="$bridge_home" bash -c '. "$1"; _install_bridge' \
    _ "$REPO_DIR/scripts/install-migration.sh" || rc=$?
assert_eq 143 "$rc" 'bridge acquisition signal status'
assert_absent "$BRIDGE_LOCK_BASE/clashctl-operation-$EUID/operation.lock.d" 'interrupted bridge lock'
CLASHCTL_HOME="$bridge_home" bash -c '. "$1"; _install_bridge' \
    _ "$REPO_DIR/scripts/install-migration.sh" || fail 'interrupted bridge could not retry'
assert_absent "$BRIDGE_LOCK_BASE/clashctl-operation-$EUID/operation.lock.d" 'retried bridge lock'
# A user unit may still reference a removed system yq after local yq repair.
(
    . "$REPO_DIR/scripts/lib/service.sh"
    service_manager=systemd-user
    unit="$WORK_DIR/yq.service"
    unit_path=$unit
    BIN_YQ="$CLASHCTL_HOME/bin/yq"
    _service_target() { printf '%s\n' "$unit_path"; }
    systemctl() {
        [ "$*" = '--user daemon-reload' ] || fail "unexpected service operation: $*"
        if [ "${FAIL_YQ_RELOAD:-0}" = 1 ] && [ ! -e "$WORK_DIR/yq-reload-failed" ]; then
            touch "$WORK_DIR/yq-reload-failed"
            return 1
        fi
    }
    printf 'ExecStart=%s -d %s -f %s\nExecCondition=/usr/bin/yq -e '\''.tun.enable != true'\'' %s\nEnvironment=CUSTOM=preserved\n' \
        "$BIN_KERNEL" "$CLASH_RESOURCES_DIR" "$CLASH_CONFIG_RUNTIME" "$CLASH_CONFIG_RUNTIME" >"$unit"
    chmod 0640 "$unit"
    cp -p "$unit" "$WORK_DIR/yq-unit.before"
    if FAIL_YQ_RELOAD=1 _install_refresh_yq_condition; then fail 'yq unit reload failure was accepted'; fi
    cmp "$unit" "$WORK_DIR/yq-unit.before" || fail 'yq unit rollback changed the original'
    _install_refresh_yq_condition || fail 'yq unit repair could not retry'
    assert_contains "$unit" "ExecCondition=$BIN_YQ -e '.tun.enable != true' $CLASH_CONFIG_RUNTIME" 'repaired yq condition'
    assert_eq 640 "$(stat -c %a "$unit")" 'repaired unit mode'
    grep -v '^ExecCondition=' "$WORK_DIR/yq-unit.before" >"$WORK_DIR/yq-unit.other-before"
    grep -v '^ExecCondition=' "$unit" >"$WORK_DIR/yq-unit.other-after"
    cmp "$WORK_DIR/yq-unit.other-before" "$WORK_DIR/yq-unit.other-after" || fail 'yq repair changed custom unit settings'
    cp "$unit" "$WORK_DIR/yq-unit.expected"
    _install_refresh_yq_condition || fail 'repeated yq unit repair failed'
    cmp "$unit" "$WORK_DIR/yq-unit.expected" || fail 'repeated yq unit repair changed the unit'
)

# 首批 update 已使用 name 模型，但其旧交互 Shell 仍以 flock 写 data/。
# 只在真实历史 rename 临界区加入屏障；迁移必须先等它完成再备份。
writer_pids=() writer_release_paths=()
cleanup_hook() {
    local path pid
    for path in "${writer_release_paths[@]}"; do touch "$path"; done
    for pid in "${writer_pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}
export MIGRATION_SOURCE="$WORK_DIR/current-source" MIGRATION_REPO=$REPO_DIR
mkdir -p "$MIGRATION_SOURCE/scripts"
cat >"$MIGRATION_SOURCE/scripts/preflight.sh" <<'SH'
CLASHCTL_SRC=$MIGRATION_REPO
. "$MIGRATION_REPO/scripts/preflight.sh" || return 1
CLASHCTL_SRC=$MIGRATION_SOURCE
detect_service_manager() {
    [ -n "${RECOVERY_MANAGER:-}" ] || { printf 'flat migration queried a service\n' >&2; return 93; }
    service_manager=$RECOVERY_MANAGER
    service_log_path="$CLASHCTL_HOME/data/mihomo.log"
}
_service_privileged_marker_exists() { [ "${RECOVERY_HELPER:-0}" = 1 ]; }
_is_tun_enabled() { return 1; }
journalctl() { printf '%s\n' "$*"; }
SH
for revision in 67ce07f a33e3c3; do
    export CLASHCTL_HOME="$WORK_DIR/current-$revision" CLASHCTL_SRC=$MIGRATION_SOURCE
    export CLASHCTL_KERNEL=mihomo
    export WRITER_HOME=$CLASHCTL_HOME WRITER_BARRIER="$WORK_DIR/writer-$revision"
    mkdir -m 0700 -p "$CLASHCTL_HOME/"{data,resources,bin} "$WRITER_BARRIER"
    git -C "$REPO_DIR" show "$revision:scripts/cmd/sub.sh" >"$WRITER_BARRIER/sub.sh"
    cat >"$CLASHCTL_HOME/data/profiles.yaml" <<'YAML'
use: old
profiles: [{name: old, url: "https://example.invalid/sub", path: /preserved/profile.yaml}]
YAML
    export CLASH_PROFILES_META="$CLASHCTL_HOME/data/profiles.yaml"
    export CLASH_PROFILES_LOCK="$CLASHCTL_HOME/data/profiles.lock" CLASH_PROFILES_LOG="$CLASHCTL_HOME/data/profiles.log"
    export BIN_YQ
    bash --noprofile --norc -i >"$WRITER_BARRIER/output" 2>&1 <<'SH' &
. "$WRITER_BARRIER/sub.sh"
eval "$(declare -f _sub_rename_locked | sed '1s/_sub_rename_locked/_historical_rename_locked/')"
_sub_rename_locked() {
    touch "$WRITER_BARRIER/ready"
    while [ ! -e "$WRITER_BARRIER/release" ]; do sleep 0.01; done
    _historical_rename_locked "$@"
    printf '%s\n' "$?" >"$WRITER_BARRIER/result"
}
_okcat() { printf '%s\n' "$*"; }
_errorcat() { printf '%s\n' "$*" >&2; return 1; }
clashsub rename old new
SH
    writer_pid=$!
    writer_pids+=("$writer_pid")
    writer_release_paths+=("$WRITER_BARRIER/release")
    wait_until 300 test -f "$WRITER_BARRIER/ready" || fail 'historical rename did not take flock'
    if flock -n "$CLASH_PROFILES_LOCK" true; then fail 'historical writer did not hold flock'; fi
    _install_maintenance_wait "$CLASHCTL_HOME" 0 || fail 'hidden writer was unexpectedly visible in argv'
    _INSTALL_MAINTENANCE_ACTIVE=true # No real crontab is involved in this fixture.
    mkdir "$WRITER_BARRIER/busy" "$WRITER_BARRIER/failed" "$WRITER_BARRIER/retry" "$WRITER_BARRIER/repeat"
    (
        eval "$(declare -f _install_legacy_profiles_lock_acquire | sed '1s/_install_legacy_profiles_lock_acquire/_original_profiles_lock_acquire/')"
        _install_legacy_profiles_lock_acquire() { _original_profiles_lock_acquire "$1" "$2" 0; }
        _install_migrate_current "$MIGRATION_SOURCE" '' '' "$WRITER_BARRIER/busy" true
    ) >"$WRITER_BARRIER/busy.out" 2>&1 && fail 'migration bypassed a busy historical flock'
    assert_absent "$WRITER_BARRIER/busy/profiles-before" 'busy migration captured a stale snapshot'
    assert_eq old "$(yq '.use' "$CLASH_PROFILES_META")" 'busy migration changed subscription'
    assert_absent "$CLASH_PROFILES_LOCK.d" 'busy migration leaked its directory lock'
    (
        wait_until 300 test -f "$WRITER_BARRIER/acquiring" || exit 1
        [ ! -e "$WRITER_BARRIER/failed/profiles-before" ] || exit 1
        touch "$WRITER_BARRIER/release"
    ) &
    release_pid=$!
    writer_pids+=("$release_pid")
    (
        eval "$(declare -f _install_legacy_profiles_lock_acquire | sed '1s/_install_legacy_profiles_lock_acquire/_original_profiles_lock_acquire/')"
        _install_legacy_profiles_lock_acquire() {
            touch "$WRITER_BARRIER/acquiring"
            _original_profiles_lock_acquire "$@"
        }
        _install_migration_finish() {
            [ "$(yq '.use' "$CLASH_PROFILES_META")" = new ] || exit 94
            if flock -n "$CLASH_PROFILES_LOCK" true; then exit 95; fi
            return 86
        }
        eval "$(declare -f _install_migration_restore_file | sed '1s/_install_migration_restore_file/_original_migration_restore_file/')"
        _install_migration_restore_file() {
            # A second writer must remain excluded throughout failure recovery.
            if flock -n "$CLASH_PROFILES_LOCK" true; then exit 96; fi
            _original_migration_restore_file "$@"
        }
        _install_migrate_current "$MIGRATION_SOURCE" '' '' "$WRITER_BARRIER/failed" true
    ) >"$WRITER_BARRIER/failed.out" 2>&1 && fail 'migration accepted an injected finish failure'
    release_rc=0 writer_rc=0
    wait "$release_pid" || release_rc=$?
    writer_pids=("$writer_pid")
    [ "$release_rc" -eq 0 ] || fail 'migration did not wait before taking its metadata snapshot'
    wait "$writer_pid" || writer_rc=$?
    writer_pids=()
    [ "$writer_rc" -eq 0 ] || fail 'historical rename failed'
    assert_eq 0 "$(cat "$WRITER_BARRIER/result")" 'historical rename result'
    assert_eq new "$(yq '.use' "$CLASH_PROFILES_META")" 'migration rollback lost a successful historical rename'
    assert_contains "$CLASH_PROFILES_LOG" '[old] → [new]' 'historical rename success log'
    assert_absent "$CLASHCTL_HOME/.clashctl-format" 'failed migration wrote its marker'
    assert_absent "$CLASH_PROFILES_LOCK.d" 'failed migration leaked its directory lock'
    flock -n "$CLASH_PROFILES_LOCK" true || fail 'failed migration leaked flock'
    _install_migrate_current "$MIGRATION_SOURCE" '' '' "$WRITER_BARRIER/retry" true || fail 'migration could not retry'
    cp "$CLASH_PROFILES_META" "$WRITER_BARRIER/expected"
    _install_migrate_current "$MIGRATION_SOURCE" '' '' "$WRITER_BARRIER/repeat" true || fail 'repeated migration failed'
    cmp "$WRITER_BARRIER/expected" "$CLASH_PROFILES_META" || fail 'repeated migration changed metadata'
    assert_eq 1 "$(cat "$CLASHCTL_HOME/.clashctl-format")" 'retried migration marker'
    flock -n "$CLASH_PROFILES_LOCK" true || fail 'successful migration leaked flock'
done
(
    legacy_profiles_fd=''
    _install_legacy_profiles_lock_acquire "$CLASHCTL_HOME" current
    held_fd=$legacy_profiles_fd
    service_start() { [ ! -e "/proc/$BASHPID/fd/$held_fd" ]; }
    service_sudo_start() { service_start; }
    _install_migration_start_service false || fail 'normal service inherited migration flock'
    _install_migration_start_service true || fail 'privileged service inherited migration flock'
    if flock -n "$CLASH_PROFILES_LOCK" true; then fail 'service handoff released the parent migration flock'; fi
    _install_legacy_profiles_lock_release
    flock -n "$CLASH_PROFILES_LOCK" true || fail 'migration flock could not be released'
    PATH='' _install_legacy_profiles_lock_acquire "$CLASHCTL_HOME" current || fail 'migration added a flock dependency'
    rm "$CLASH_PROFILES_LOCK"
    _install_legacy_profiles_lock_acquire "$CLASHCTL_HOME" current || fail 'missing historical lock blocked migration'
    assert_absent "$CLASH_PROFILES_LOCK" 'migration created an unnecessary historical lock'
)
# Recovery uses the existing backend dispatch, including user TUN helper logs.
export CLASHCTL_SRC=$MIGRATION_SOURCE
mkdir -p "$CLASHCTL_HOME/scripts"
cp "$MIGRATION_SOURCE/scripts/preflight.sh" "$CLASHCTL_HOME/scripts/preflight.sh"
assert_eq '-u mihomo -n 50' "$(RECOVERY_MANAGER=systemd _install_recovery log)" 'systemd recovery log'
assert_eq '--user -u mihomo -n 50' "$(RECOVERY_MANAGER=systemd-user _install_recovery log)" 'user service recovery log'
printf 'local service log\n' >"$CLASHCTL_HOME/data/mihomo.log"
assert_eq 'local service log' "$(RECOVERY_MANAGER=nohup _install_recovery log)" 'nohup recovery log'
assert_eq 'local service log' "$(RECOVERY_MANAGER=systemd-user RECOVERY_HELPER=1 _install_recovery log)" 'user TUN helper recovery log'
printf 'install-migration: ok\n'
