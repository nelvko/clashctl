#!/usr/bin/env bash
# 各套件独立运行，共用断言、临时目录与清理入口。
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)

cleanup_hook() { :; }
_test_cleanup() {
    cleanup_hook
    /usr/bin/rm -rf -- "$WORK_DIR"
}
trap _test_cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
    [ "$1" = "$2" ] || fail "$3: expected [$1], got [$2]"
}
assert_empty() { [ ! -s "$1" ] || fail "$2"; }
assert_contains() { grep -Fqs -- "$2" "$1" || fail "$3: missing [$2]"; }
assert_not_contains() {
    if grep -Fqs -- "$2" "$1"; then fail "$3: unexpectedly found [$2]"; fi
}
assert_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then fail "$2: still exists [$1]"; fi
}

wait_until() {
    local attempts=$1
    shift
    while [ "$attempts" -gt 0 ]; do
        "$@" && return 0
        sleep 0.01
        attempts=$((attempts - 1))
    done
    return 1
}

wait_for_file() {
    local file=$1 pid=$2 description=$3 attempt
    for ((attempt = 0; attempt < 300; attempt++)); do
        [ -e "$file" ] && return 0
        kill -0 "$pid" 2>/dev/null || fail "$description: process exited early"
        sleep 0.01
    done
    fail "$description: timed out"
}

make_fake_home() {
    mkdir -p "$1/"{scripts,bin,data}
    cp -r "$REPO_DIR/scripts/." "$1/scripts/"
    printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\n' >"$1/.env"
    printf '1\n' >"$1/.clashctl-format"
}

init_fixture_repo() {
    "$REAL_GIT" -C "$1" init -q -b master
    "$REAL_GIT" -C "$1" config user.email test@example.invalid
    "$REAL_GIT" -C "$1" config user.name test
    "$REAL_GIT" -C "$1" add .
    "$REAL_GIT" -C "$1" commit -qm initial
}
