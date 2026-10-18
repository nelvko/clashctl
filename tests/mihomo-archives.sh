#!/usr/bin/env bash
# 本地程序与真实 gzip 走实际安装流程；网络仅用受控命令桩。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export CLASHCTL_HOME="$WORK_DIR/bootstrap" CLASHCTL_SRC=$REPO_DIR CLASHCTL_KERNEL=mihomo CLASHCTL_COLOR=never
mkdir -p "$CLASHCTL_HOME"
# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"
TEST_ARCH=x86_64 TEST_LEVEL=v3 FAIL_DOWNLOAD=0
uname() { if [ "${1:-}" = -m ]; then printf '%s\n' "$TEST_ARCH"; else command uname "$@"; fi; }
_mihomo_cpu_level() { printf '%s\n' "$TEST_LEVEL"; }
_fetch_latest_tag() { printf 'query %s\n' "$1" >>"$WORK_DIR/network"; printf 'v9.0.0\n'; }
make_program() {
    # shellcheck disable=SC2016  # 参数由生成的程序在运行时展开。
    printf '%s\n' '#!/bin/sh' '[ "${1:-}" = -v ] || exit 1' \
        "printf 'Mihomo Meta $2 linux amd64\\n'" >"$1"
    chmod 0755 "$1"
}
make_archive() {
    make_program "$WORK_DIR/program" "${3:-$2}"
    gzip -c "$WORK_DIR/program" >"$ZIP_BASE_DIR/mihomo-linux-$1-$2.gz"
}
make_program "$WORK_DIR/remote" v9.0.0
gzip -c "$WORK_DIR/remote" >"$WORK_DIR/remote.gz"
curl() {
    local output='' previous='' arg
    printf 'download\n' >>"$WORK_DIR/network"
    [ "$FAIL_DOWNLOAD" = 0 ] || return 22
    for arg in "$@"; do
        if [ "$previous" = --output ]; then output=$arg; fi
        previous=$arg
    done
    cp "$WORK_DIR/remote.gz" "$output"
    printf 200
}
setup() {
    CLASHCTL_HOME="$WORK_DIR/$1" CLASHCTL_SRC="$WORK_DIR/$1"
    BIN_BASE_DIR="$CLASHCTL_HOME/bin" ZIP_BASE_DIR="$CLASHCTL_HOME/archives"
    mkdir -p "$BIN_BASE_DIR" "$ZIP_BASE_DIR"
    BIN_KERNEL=$(bin_kernel_path)
    # shellcheck disable=SC2034  # 由 source 的下载和安装函数读取。
    ZIP_KERNEL='' ZIP_KERNEL_LOCAL=0
    TEST_ARCH=x86_64 TEST_LEVEL=v3 FAIL_DOWNLOAD=0
    : >"$WORK_DIR/network"
}
prepare() { prepare_zip kernel >"$WORK_DIR/output" 2>&1; }
assert_version() {
    [ "$(_mihomo_binary_version "$BIN_KERNEL")" = "$1" ] || fail "wrong installed version: $1"
}
assert_no_network() { [ ! -s "$WORK_DIR/network" ] || fail 'local source triggered a network request'; }

setup local
make_archive amd64-v3 v1.19.32
prepare || { cat "$WORK_DIR/output"; fail 'local archive installation failed'; }
assert_version v1.19.32
[ "$BIN_KERNEL" = "$CLASHCTL_HOME/bin/mihomo" ] || fail 'new installation is not flat'
assert_no_network
[ -f "$ZIP_BASE_DIR/mihomo-linux-amd64-v3-v1.19.32.gz" ] || fail 'local archive was removed'

# 已安装程序优先于包，重装不会被旧包降级；不查找 PATH 中的程序。
make_archive amd64-v1 v1.2.3
prepare || fail 'installed program was not reused before ambiguous archives'
assert_version v1.19.32
assert_no_network

setup occupied
mkdir "$BIN_KERNEL"
printf 'keep-parent-content\n' >"$BIN_KERNEL/other-file"
if prepare; then fail 'directory at the program path was accepted'; fi
grep -q 'mihomo 程序路径被目录占用' "$WORK_DIR/output" || fail 'missing occupied-path diagnosis'
[ "$(<"$BIN_KERNEL/other-file")" = keep-parent-content ] || fail 'occupied path contents changed'
assert_no_network

setup ambiguous
make_archive amd64-v3 v1.19.32
make_archive amd64-v1 v1.2.3
if prepare; then fail 'multiple applicable archives were silently selected'; fi
grep -q '发现多个适用' "$WORK_DIR/output" || fail 'missing multiple-archive diagnosis'
assert_no_network

setup compatible
TEST_LEVEL=v1
make_archive amd64-v3 v1.19.32
make_archive arm64 v1.19.32
make_archive 386 v1.19.32
make_archive amd64-v1 v1.2.3
prepare || fail 'compatible CPU fallback was not selected'
assert_version v1.2.3
assert_no_network

for spec in 'i686 386' 'aarch64 arm64' 'armv7l armv7' 'x86_64 amd64'; do
    read -r arch variant <<<"$spec"
    setup "$arch"
    TEST_ARCH=$arch
    make_archive "$variant" v1.19.32
    prepare || fail "archive for $arch was not selected"
    assert_version v1.19.32
    assert_no_network
done

# 下载 URL 与本地包选择共用架构映射，缓存名仍保留系统原始架构。
(
    _download_archive() { printf '%s\n' "$2" >>"$WORK_DIR/urls"; }
    for spec in 'x86_64 amd64-v3 amd64 linux64' 'i686 386 386 linux32' \
        'aarch64 arm64 arm64 aarch64' 'armv7l armv7 arm armv7'; do
        read -r arch kernel_arch yq_arch sub_arch <<<"$spec"
        setup "remote-$arch"
        TEST_ARCH=$arch
        : >"$WORK_DIR/urls"
        download_zip mihomo yq subconverter ui >"$WORK_DIR/output" 2>&1 || fail "download selection failed for $arch"
        printf '%s\n' \
            "https://github.com/MetaCubeX/mihomo/releases/download/v9.0.0/mihomo-linux-$kernel_arch-v9.0.0.gz" \
            "https://github.com/mikefarah/yq/releases/download/v9.0.0/yq_linux_$yq_arch.tar.gz" \
            "https://github.com/$SUBCONVERTER_REPO/releases/download/v9.0.0/subconverter_$sub_arch.tar.gz" \
            'https://github.com/Zephyruso/zashboard/releases/download/v9.0.0/dist.zip' >"$WORK_DIR/expected-urls"
        cmp -s "$WORK_DIR/expected-urls" "$WORK_DIR/urls" || fail "incorrect asset URLs for $arch"
    done
    setup unknown
    if download_zip clash >"$WORK_DIR/output" 2>&1; then fail 'unsupported clash component accepted'; fi
    grep -q '未知依赖组件：clash' "$WORK_DIR/output" || fail 'unknown component was not diagnosed'
)

setup invalid
printf broken >"$ZIP_BASE_DIR/mihomo-linux-amd64-v3-v1.19.32.gz"
ln -s "$WORK_DIR/remote.gz" "$ZIP_BASE_DIR/mihomo-linux-amd64-v1-v1.2.3.gz"
cp "$WORK_DIR/remote.gz" "$ZIP_BASE_DIR/mihomo-linux-amd64-v2-v1.3.0.gz.part"
prepare || fail 'invalid or incomplete local packages blocked remote fallback'
assert_version v9.0.0
[ "$(wc -l <"$WORK_DIR/network")" -eq 2 ] || fail 'remote fallback did not query and download once'

setup content-mismatch
printf '#!/bin/sh\nexit 1\n' >"$BIN_KERNEL"
chmod 0755 "$BIN_KERNEL"
cp "$BIN_KERNEL" "$WORK_DIR/previous"
make_archive amd64-v3 v1.19.32 v1.2.3
if prepare; then fail 'filename and executable version mismatch was accepted'; fi
cmp -s "$BIN_KERNEL" "$WORK_DIR/previous" || fail 'invalid local package replaced the previous program'
assert_no_network

setup wrong-program
printf 'not an executable\n' | gzip >"$ZIP_BASE_DIR/mihomo-linux-amd64-v3-v1.19.32.gz"
if prepare; then fail 'gzip with no runnable mihomo was accepted'; fi
[ ! -e "$BIN_KERNEL" ] || fail 'unusable program was installed'
assert_no_network

setup no-path-probe
mkdir "$WORK_DIR/path-bin"
make_program "$WORK_DIR/path-bin/mihomo" v1.2.3
PATH="$WORK_DIR/path-bin:$PATH" prepare || fail 'normal download fallback failed'
assert_version v9.0.0
[ -s "$WORK_DIR/network" ] || fail 'unexpected PATH binary reuse'

setup download-failure
FAIL_DOWNLOAD=1
if prepare; then fail 'failed download was ignored'; fi
grep -Fq "$CLASHCTL_HOME/archives/" "$WORK_DIR/output" || fail 'manual download hint omitted actual directory'
grep -q '手动下载安装包:' "$WORK_DIR/output" || fail 'manual download hint omitted its heading'
grep -q '重新执行原命令' "$WORK_DIR/output" || fail 'manual download hint omitted next step'
if grep -q '<安装目录>\|mihomo-file\|mihomo-version' "$WORK_DIR/output"; then fail 'hint includes unsupported input'; fi

printf 'mihomo-archives: ok\n'
