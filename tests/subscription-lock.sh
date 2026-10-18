#!/usr/bin/env bash
# 订阅锁随临界区退出而清理；后台组件不能释放父进程的操作锁。
# 下载后的提交失败只清理本次临时文件。
# shellcheck disable=SC2034  # 配置变量由间接调用的库函数读取。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
cleanup_hook() {
    local record pid
    for record in "$WORK_DIR"/*.pid; do
        [ -f "$record" ] || continue
        read -r pid <"$record" || continue
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

CLASH_PROFILES_LOCK="$WORK_DIR/profiles.lock"
# shellcheck source=../scripts/lib/operation-lock.sh
. "$REPO_DIR/scripts/lib/operation-lock.sh"
# shellcheck source=../scripts/lib/service-process.sh
. "$REPO_DIR/scripts/lib/service-process.sh"
# shellcheck source=../scripts/cmd/sub.sh
. "$REPO_DIR/scripts/cmd/sub.sh"
# shellcheck source=../scripts/lib/convert.sh
. "$REPO_DIR/scripts/lib/convert.sh"
# shellcheck source=../scripts/lib/service.sh
. "$REPO_DIR/scripts/lib/service.sh"

mkdir -m 0700 -- "$WORK_DIR/runtime"
_operation_lock_base() { printf '%s\n' "$WORK_DIR/runtime"; }

cat >"$WORK_DIR/daemon" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$BASHPID" >"$DAEMON_TEST_DIR/$DAEMON_NAME.pid"
: >"$DAEMON_TEST_DIR/$DAEMON_NAME.ready"
exec sleep 30
EOF
chmod 0700 -- "$WORK_DIR/daemon"
export DAEMON_TEST_DIR=$WORK_DIR DAEMON_NAME
BIN_KERNEL="$WORK_DIR/daemon"
BIN_SUBCONVERTER="$WORK_DIR/daemon"
BIN_SUBCONVERTER_CONFIG="$WORK_DIR/pref.yml"
BIN_SUBCONVERTER_LOG="$WORK_DIR/converter.log"
BIN_YQ=fixture_yq
CLASH_RESOURCES_DIR="$WORK_DIR/resources"
CLASH_CONFIG_RUNTIME="$WORK_DIR/runtime.yaml"
service_pid_path="$WORK_DIR/kernel-record"
service_log_path="$WORK_DIR/kernel.log"

# 只替换端口探测和 PID 记录；后台启动与两种锁使用真实实现。
fixture_yq() { printf '25500\n'; }
_replacement_port() { return 1; }
_service_process_record_pid() { return 1; }
_service_process_record_create() { return 0; }
wait_ready() { wait_until 200 test -e "$WORK_DIR/$DAEMON_NAME.ready"; }
# shellcheck disable=SC2317  # _start_convert 间接调用此探活替身。
curl() {
    # 启动后的首次探活仍未就绪；后续成功时必须返回 0。
    [ -n "${BIN_SUBCONVERTER_PID:-}" ] || return 1
    if [ ! -e "$WORK_DIR/delayed-health-check" ]; then
        touch "$WORK_DIR/delayed-health-check"
        return 1
    fi
    wait_ready
}
assert_daemon_releases_locks() {
    local start_fn=$1 pid operation_dir operation_owner
    operation_lock_acquire || fail 'cannot acquire lifecycle lock'
    operation_dir=$CLASHCTL_OPERATION_LOCK_DIR
    operation_owner=$(cat "$operation_dir/owner")
    _with_profiles_lock "$start_fn" || fail "$DAEMON_NAME did not start"
    wait_ready || fail "$DAEMON_NAME startup timed out"
    read -r pid <"$WORK_DIR/$DAEMON_NAME.pid"
    kill -0 "$pid" || fail "$DAEMON_NAME exited before lock check"
    [ -d "$operation_dir" ] || fail "$DAEMON_NAME released its parent lifecycle lock"
    [ "$(cat "$operation_dir/owner")" = "$operation_owner" ] ||
        fail "$DAEMON_NAME changed its parent lifecycle lock owner"
    [ ! -e "${CLASH_PROFILES_LOCK}.d" ] || fail "$DAEMON_NAME retained subscription lock"
    _with_profiles_lock true || fail "$DAEMON_NAME blocked another subscription operation"
    operation_lock_release || fail 'cannot release lifecycle lock'
    operation_lock_acquire || fail "$DAEMON_NAME retained lifecycle lock"
    operation_lock_release || fail 'cannot release lifecycle lock'
}
DAEMON_NAME=kernel
assert_daemon_releases_locks _service_nohup_start_locked
DAEMON_NAME=converter
assert_daemon_releases_locks _start_convert
unset -f curl

# 下载走真实 _sub_download；网络与元数据提交用替身，取锁使用真实 mkdir。
mkdir -p -- "$CLASH_RESOURCES_DIR"
printf 'downloaded subscription\n' >"$WORK_DIR/download"
printf 'unrelated temporary file\n' >"$CLASH_RESOURCES_DIR/.fetch.keep"
profile="$WORK_DIR/profile.yaml"
printf 'original profile\n' >"$profile"
_download_config() { cp -- "$WORK_DIR/download" "$1"; }
_errorcat() { printf '%s\n' "$*" >&2; }
_ui_emit_fd() { :; }
_logging_sub() { :; }
_sub_has() { [ "$1" = existing ]; }
_sub_url_exists() { return 1; }
_sub_get() {
    case $2 in
    url) printf 'https://fixture.invalid/sub' ;;
    path) printf '%s' "$profile" ;;
    esac
}
commit_status=0
fixture_commit() {
    [ "$commit_status" -eq 0 ] || return "$commit_status"
    /bin/mv -- "$4" "$profile"
}
_sub_add_locked() { fixture_commit "$@"; }
_sub_update_locked() { fixture_commit "$@"; }
# 用真实的锁冲突，缩短生产代码的 60 秒等待以避免测试空耗。
eval "$(declare -f _directory_lock_acquire | sed '1s/_directory_lock_acquire/_fixture_directory_lock_acquire/')"
_directory_lock_acquire() { _fixture_directory_lock_acquire "$1" 0; }
start_lock_holder() {
    bash -c '
        set -euo pipefail
        . "$1"
        lock_dir=$2
        _directory_lock_acquire "$lock_dir" 0
        lock_pid=$_DIRECTORY_LOCK_PID
        lock_token=$_DIRECTORY_LOCK_TOKEN
        trap '\''_directory_lock_release "$lock_dir" "$lock_pid" "$lock_token"'\'' EXIT
        trap '\''exit 143'\'' TERM
        : >"$3"
        while [ ! -e "$4" ]; do sleep 0.01; done
    ' _ "$REPO_DIR/scripts/lib/operation-lock.sh" "${CLASH_PROFILES_LOCK}.d" \
        "$WORK_DIR/holder.ready" "$WORK_DIR/holder.release" &
    holder_pid=$!
    printf '%s\n' "$holder_pid" >"$WORK_DIR/holder.pid"
    wait_until 200 test -e "$WORK_DIR/holder.ready" || fail 'separate process could not hold subscription lock'
}
stop_lock_holder() {
    : >"$WORK_DIR/holder.release"
    wait "$holder_pid" || fail 'subscription lock holder did not exit cleanly'
    rm -f -- "$WORK_DIR/holder.pid" "$WORK_DIR/holder.ready" "$WORK_DIR/holder.release"
    [ ! -e "${CLASH_PROFILES_LOCK}.d" ] || fail 'holder retained subscription lock'
}
run_write() {
    case $1 in
    add) sub_add --name new https://fixture.invalid/sub ;;
    update) _sub_update_one existing auto ;;
    esac
}
assert_failed_download_cleanup() {
    [ ! -e "$_SUB_DL_FILE" ] || fail 'failed write retained downloaded temporary file'
    [ "$(cat "$profile")" = 'original profile' ] || fail 'failed write changed existing profile'
    [ "$(cat "$CLASH_RESOURCES_DIR/.fetch.keep")" = 'unrelated temporary file' ] ||
        fail 'cleanup removed another operation temporary file'
}
for operation in add update; do
    start_lock_holder
    rc=0
    run_write "$operation" >"$WORK_DIR/output" 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || fail "$operation did not report lock contention"
    grep -q '另一订阅操作正在进行' "$WORK_DIR/output" || fail 'missing contention diagnostic'
    assert_failed_download_cleanup
    stop_lock_holder

    commit_status=23
    rc=0
    run_write "$operation" >"$WORK_DIR/output" 2>&1 || rc=$?
    [ "$rc" -eq 23 ] || fail "$operation lost commit failure status"
    assert_failed_download_cleanup

    commit_status=0
    run_write "$operation" >"$WORK_DIR/output" 2>&1 || fail "$operation successful write failed"
    cmp -s -- "$WORK_DIR/download" "$profile" || fail 'cleanup removed published subscription'
    [ ! -e "$_SUB_DL_FILE" ] || fail 'successful write retained temporary file'
    printf 'original profile\n' >"$profile"
done

# EXIT 清理必须保留正文状态；信号退出也应及时释放锁。
rc=0
_with_profiles_lock bash -c 'exit 42' || rc=$?
[ "$rc" -eq 42 ] || fail 'lock wrapper lost body return status'
[ ! -e "${CLASH_PROFILES_LOCK}.d" ] || fail 'failed body retained subscription lock'
rc=0
# shellcheck disable=SC2016  # 由子 Bash 展开 PPID，向持锁的包装进程发信号。
_with_profiles_lock bash -c 'kill -TERM "$PPID"' || rc=$?
[ "$rc" -eq 143 ] || fail 'subscription lock wrapper lost TERM status'
[ ! -e "${CLASH_PROFILES_LOCK}.d" ] || fail 'TERM retained subscription lock'

# mkdir 已成功但 owner 尚未发布时收到 TERM，也必须清理本次锁。
# shellcheck disable=SC2317  # 包装函数由真实取锁实现间接调用。
(
    eval "$(declare -f _directory_lock_validate | sed '1s/_directory_lock_validate/_fixture_directory_lock_validate/')"
    _directory_lock_validate() {
        _fixture_directory_lock_validate "$@" || return
        if [ "$1" = "${CLASH_PROFILES_LOCK}.d" ] && [ ! -e "$1/owner" ]; then
            kill -TERM "$BASHPID"
        fi
    }
    rc=0
    _with_profiles_lock touch "$WORK_DIR/interrupted-body-ran" || rc=$?
    [ "$rc" -eq 143 ] || fail 'TERM during lock acquisition lost its exit status'
    [ ! -e "$WORK_DIR/interrupted-body-ran" ] || fail 'TERM during acquisition still ran subscription write'
    [ ! -e "${CLASH_PROFILES_LOCK}.d" ] || fail 'TERM during acquisition retained subscription lock'
)

# EXIT 已开始清理时再收到 TERM，应完成释放并保留正文原本的失败码。
# shellcheck disable=SC2317  # 包装函数由 EXIT 清理间接调用。
(
    eval "$(declare -f _directory_lock_read_owner | sed '1s/_directory_lock_read_owner/_fixture_directory_lock_read_owner/')"
    _directory_lock_read_owner() {
        if [ "$1" = "${CLASH_PROFILES_LOCK}.d" ] && [ -e "$WORK_DIR/cleanup-body-finished" ]; then
            : >"$WORK_DIR/cleanup-signal-injected"
            kill -TERM "$BASHPID"
        fi
        _fixture_directory_lock_read_owner "$@"
    }
    cleanup_test_body() { : >"$WORK_DIR/cleanup-body-finished"; return 42; }
    rc=0
    _with_profiles_lock cleanup_test_body || rc=$?
    [ "$rc" -eq 42 ] || fail 'TERM during cleanup changed body return status'
    [ -e "$WORK_DIR/cleanup-signal-injected" ] || fail 'cleanup TERM fixture did not run'
    [ ! -e "${CLASH_PROFILES_LOCK}.d" ] || fail 'TERM interrupted subscription lock cleanup'
)

printf 'subscription-lock: ok\n'
