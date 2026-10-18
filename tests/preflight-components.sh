#!/usr/bin/env bash
# shellcheck disable=SC2317  # 校验器与命令桩由 source 的函数间接调用。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

assert_mode() {
    local expected=$1 path=$2 description=$3 actual
    actual=$(stat -c %a -- "$path") || fail "$description: cannot stat [$path]"
    assert_eq "$expected" "$actual" "$description"
}

assert_owned_tree() {
    local root=$1 description=$2 foreign
    foreign=$(find "$root" ! -user "$(id -u)" -print -quit)
    [ -z "$foreign" ] || fail "$description: foreign-owned path [$foreign]"
}

assert_public_tree_modes() {
    local root=$1 description=$2 invalid
    invalid=$(find "$root" \
        \( \( -type d ! -perm 0755 \) -o \( -type f ! -perm 0644 \) \) \
        -print -quit)
    [ -z "$invalid" ] || fail "$description: unexpected mode on [$invalid]"
}

assert_no_stages() {
    local staged
    staged=$(find "$CLASHCTL_HOME" -name '.components.*' -print -quit)
    [ -z "$staged" ] || fail "component staging directory was retained: [$staged]"
}

assert_external_untouched() {
    local root=$1 description=$2 unexpected

    assert_eq outside-unchanged "$(<"$root/sentinel")" "$description sentinel"
    assert_mode 700 "$root" "$description external directory mode"
    unexpected=$(find "$root" -mindepth 1 -maxdepth 1 ! -name sentinel -print -quit)
    [ -z "$unexpected" ] || fail "$description: unexpected external path [$unexpected]"
}

export CLASHCTL_SRC=$REPO_DIR
export CLASHCTL_HOME="$WORK_DIR/bootstrap"
export CLASHCTL_KERNEL=mihomo
export CLASHCTL_COLOR=never
mkdir -p -- "$CLASHCTL_HOME"

# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"

ARCHIVE_DIR="$WORK_DIR/archives"
SOURCE_DIR="$WORK_DIR/archive-sources"
mkdir -p -- "$ARCHIVE_DIR" "$SOURCE_DIR"

printf 'new-kernel\n' >"$SOURCE_DIR/kernel"
gzip -c -- "$SOURCE_DIR/kernel" >"$ARCHIVE_DIR/kernel.gz"

mkdir -p -- "$SOURCE_DIR/yq"
printf 'new-yq\n' >"$SOURCE_DIR/yq/yq_linux_amd64"
printf 'manual page\n' >"$SOURCE_DIR/yq/yq.1"
printf '#!/bin/sh\n' >"$SOURCE_DIR/yq/install-man-page.sh"
chmod 0777 "$SOURCE_DIR/yq/yq_linux_amd64" "$SOURCE_DIR/yq/install-man-page.sh"
chmod 0666 "$SOURCE_DIR/yq/yq.1"
tar --create --gzip --file "$ARCHIVE_DIR/yq.tar.gz" --numeric-owner \
    --owner=1001 --group=1001 --directory "$SOURCE_DIR/yq" .

mkdir -p -- "$SOURCE_DIR/converter/subconverter/config"
printf 'new-converter\n' >"$SOURCE_DIR/converter/subconverter/subconverter"
printf 'server:\n  port: 25500\n' >"$SOURCE_DIR/converter/subconverter/pref.example.yml"
printf 'fresh-rule\n' >"$SOURCE_DIR/converter/subconverter/config/fresh.ini"
chmod -R 0777 "$SOURCE_DIR/converter/subconverter"
tar --create --gzip --file "$ARCHIVE_DIR/subconverter.tar.gz" --numeric-owner \
    --owner=1001 --group=1001 --directory "$SOURCE_DIR/converter" .

mkdir -p -- "$SOURCE_DIR/ui/dist/assets"
printf '<html>new-ui</html>\n' >"$SOURCE_DIR/ui/dist/index.html"
printf 'new-assets\n' >"$SOURCE_DIR/ui/dist/assets/app.js"
chmod -R 0777 "$SOURCE_DIR/ui/dist"
python3 - "$SOURCE_DIR/ui" "$ARCHIVE_DIR/ui.zip" <<'PYZIP'
import pathlib
import sys
import zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'w') as archive:
    for path in root.rglob('*'):
        archive.write(path, path.relative_to(root))
PYZIP

mkdir -p -- "$SOURCE_DIR/invalid/subconverter"
printf 'invalid-converter\n' >"$SOURCE_DIR/invalid/subconverter/subconverter"
chmod 0777 "$SOURCE_DIR/invalid/subconverter/subconverter"
tar --create --gzip --file "$ARCHIVE_DIR/subconverter-invalid.tar.gz" --numeric-owner \
    --owner=1001 --group=1001 --directory "$SOURCE_DIR/invalid" .

printf 'unsafe-member\n' >"$SOURCE_DIR/extraction-failure"
tar --create --gzip --file "$ARCHIVE_DIR/subconverter-extraction-failure.tar.gz" \
    --transform='s|^extraction-failure$|../extraction-failure|' \
    --directory "$SOURCE_DIR" extraction-failure

tar --numeric-owner --list --verbose --file "$ARCHIVE_DIR/yq.tar.gz" |
    grep -E '1001/1001' >/dev/null ||
    fail 'synthetic yq archive does not contain numeric owner 1001:1001'
tar --numeric-owner --list --verbose --file "$ARCHIVE_DIR/subconverter.tar.gz" |
    grep -E '1001/1001' >/dev/null ||
    fail 'synthetic subconverter archive does not contain numeric owner 1001:1001'

# `unzip_zip`（已 source）通过这些全局变量读取测试归档。
# shellcheck disable=SC2034
ZIP_KERNEL="$ARCHIVE_DIR/kernel.gz"
# shellcheck disable=SC2034
ZIP_YQ="$ARCHIVE_DIR/yq.tar.gz"
# shellcheck disable=SC2034
ZIP_SUBCONVERTER="$ARCHIVE_DIR/subconverter.tar.gz"
# shellcheck disable=SC2034
ZIP_UI="$ARCHIVE_DIR/ui.zip"

archive_link="$WORK_DIR/archive-link.tar.gz"
ln -s "$ARCHIVE_DIR/yq.tar.gz" "$archive_link"
if _archive_is_valid "$archive_link"; then
    fail 'archive cache accepted a symlink file'
fi

guard_root="$WORK_DIR/directory-guards"
mkdir -p -- "$guard_root"

archives_home="$guard_root/archives-home"
archives_external="$guard_root/archives-external"
mkdir -p -- "$archives_home" "$archives_external"
chmod 0700 "$archives_external"
printf 'outside-unchanged\n' >"$archives_external/sentinel"
ln -s "$archives_external" "$archives_home/archives"
# shellcheck disable=SC2034
ZIP_BASE_DIR="$archives_home/archives"
rc=0
download_zip yq >"$guard_root/archives.stdout" 2>"$guard_root/archives.stderr" || rc=$?
assert_eq 1 "$rc" 'symlink archive directory rejection status'
assert_contains "$guard_root/archives.stderr" '依赖缓存目录无法安全使用' \
    'symlink archive directory diagnostic'
if grep -Eq '加速代理|下载经由|直连' "$guard_root/archives.stderr"; then
    fail 'direct download printed a redundant channel hint'
fi
rc=0
GH_PROXY=https://proxy.example download_zip yq >"$guard_root/proxy.stdout" 2>"$guard_root/proxy.stderr" || rc=$?
assert_eq 1 "$rc" 'proxied symlink archive directory rejection status'
if grep -q '加速代理:' "$guard_root/proxy.stderr"; then
    fail 'proxy hint appeared before a component download started'
fi
assert_external_untouched "$archives_external" 'symlink archive directory rejection'

bin_home="$guard_root/bin-home"
bin_external="$guard_root/bin-external"
mkdir -p -- "$bin_home/resources" "$bin_external"
chmod 0700 "$bin_external"
printf 'outside-unchanged\n' >"$bin_external/sentinel"
ln -s "$bin_external" "$bin_home/bin"
CLASHCTL_HOME=$bin_home
BIN_BASE_DIR="$bin_home/bin"
BIN_KERNEL="$BIN_BASE_DIR/mihomo"
BIN_YQ="$BIN_BASE_DIR/yq"
BIN_SUBCONVERTER_DIR="$BIN_BASE_DIR/subconverter"
BIN_SUBCONVERTER="$BIN_SUBCONVERTER_DIR/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
CLASH_RESOURCES_DIR="$bin_home/resources"
rc=0
unzip_zip >"$guard_root/bin.stdout" 2>"$guard_root/bin.stderr" || rc=$?
assert_eq 1 "$rc" 'symlink component directory rejection status'
assert_contains "$guard_root/bin.stderr" '运行组件目录无法安全使用' \
    'symlink component directory diagnostic'
assert_external_untouched "$bin_external" 'symlink component directory rejection'

resources_home="$guard_root/resources-home"
resources_external="$guard_root/resources-external"
mkdir -p -- "$resources_home/bin" "$resources_external"
chmod 0700 "$resources_external"
printf 'outside-unchanged\n' >"$resources_external/sentinel"
ln -s "$resources_external" "$resources_home/resources"
CLASHCTL_HOME=$resources_home
BIN_BASE_DIR="$resources_home/bin"
BIN_KERNEL="$BIN_BASE_DIR/mihomo"
BIN_YQ="$BIN_BASE_DIR/yq"
BIN_SUBCONVERTER_DIR="$BIN_BASE_DIR/subconverter"
BIN_SUBCONVERTER="$BIN_SUBCONVERTER_DIR/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
CLASH_RESOURCES_DIR="$resources_home/resources"
rc=0
unzip_zip >"$guard_root/resources.stdout" 2>"$guard_root/resources.stderr" || rc=$?
assert_eq 1 "$rc" 'symlink resource directory rejection status'
assert_contains "$guard_root/resources.stderr" '资源目录无法安全使用' \
    'symlink resource directory diagnostic'
assert_external_untouched "$resources_external" 'symlink resource directory rejection'

# 后续缓存废弃测试中的归档均由安装器管理。
# shellcheck disable=SC2034
ZIP_BASE_DIR=$ARCHIVE_DIR

outside_cache="$WORK_DIR/outside-cache.tar.gz"
printf 'outside-cache\n' >"$outside_cache"
rc=0
_managed_cache_file_discard "$outside_cache" || rc=$?
assert_eq 2 "$rc" 'outside cache discard rejection status'
assert_eq outside-cache "$(<"$outside_cache")" 'outside cache discard rejection'

linked_cache="$ARCHIVE_DIR/linked-cache.tar.gz"
ln -s "$outside_cache" "$linked_cache"
rc=0
_managed_cache_file_discard "$linked_cache" || rc=$?
assert_eq 2 "$rc" 'symlink cache discard rejection status'
[ -L "$linked_cache" ] || fail 'symlink cache discard removed the managed link'
assert_eq outside-cache "$(<"$outside_cache")" 'symlink cache discard target preservation'

if [ "$(id -u)" -eq 0 ]; then
    foreign_cache="$ARCHIVE_DIR/foreign-cache.tar.gz"
    printf 'foreign-cache\n' >"$foreign_cache"
    chown 1001:1001 -- "$foreign_cache"
    rc=0
    _managed_cache_file_discard "$foreign_cache" || rc=$?
    assert_eq 2 "$rc" 'foreign-owned cache discard rejection status'
    assert_eq foreign-cache "$(<"$foreign_cache")" 'foreign-owned cache preservation'
fi

configure_home() {
    CLASHCTL_HOME="$WORK_DIR/$1/home"
    BIN_BASE_DIR="$CLASHCTL_HOME/bin"
    BIN_KERNEL="$BIN_BASE_DIR/mihomo"
    BIN_YQ="$BIN_BASE_DIR/yq"
    BIN_SUBCONVERTER_DIR="$BIN_BASE_DIR/subconverter"
    BIN_SUBCONVERTER="$BIN_SUBCONVERTER_DIR/subconverter"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    CLASH_RESOURCES_DIR="$CLASHCTL_HOME/resources"
    mkdir -p -- "$BIN_BASE_DIR" "$BIN_SUBCONVERTER_DIR" "$CLASH_RESOURCES_DIR/dist"
}

seed_existing_components() {
    printf 'old-kernel\n' >"$BIN_KERNEL"
    printf 'old-yq\n' >"$BIN_YQ"
    printf 'legacy-manpage\n' >"$BIN_BASE_DIR/yq.1"
    printf 'legacy-installer\n' >"$BIN_BASE_DIR/install-man-page.sh"
    printf 'old-converter\n' >"$BIN_SUBCONVERTER"
    printf 'old-config\n' >"$BIN_SUBCONVERTER_CONFIG"
    printf 'stale-rule\n' >"$BIN_SUBCONVERTER_DIR/stale.ini"
    printf '<html>old-ui</html>\n' >"$CLASH_RESOURCES_DIR/dist/index.html"
    printf 'stale-ui\n' >"$CLASH_RESOURCES_DIR/dist/stale.js"
    chmod 0755 "$BIN_KERNEL" "$BIN_YQ" "$BIN_SUBCONVERTER"
    chmod 0600 "$BIN_SUBCONVERTER_CONFIG"

    if [ "$(id -u)" -eq 0 ]; then
        chown -R 1001:1001 -- "$BIN_SUBCONVERTER_DIR" "$CLASH_RESOURCES_DIR/dist"
        chown 1001:1001 -- "$BIN_YQ" "$BIN_BASE_DIR/yq.1" \
            "$BIN_BASE_DIR/install-man-page.sh"
        assert_eq 1001 "$(stat -c %u -- "$BIN_SUBCONVERTER_DIR")" \
            'foreign-owned existing converter test precondition'
    fi
}

configure_home replace
seed_existing_components
stdout_file="$WORK_DIR/replace.stdout"
stderr_file="$WORK_DIR/replace.stderr"
unzip_zip >"$stdout_file" 2>"$stderr_file" ||
    fail "component installation failed: $(<"$stderr_file")"

assert_eq new-kernel "$(<"$BIN_KERNEL")" 'kernel replacement'
assert_eq new-yq "$(<"$BIN_YQ")" 'yq replacement'
assert_eq new-converter "$(<"$BIN_SUBCONVERTER")" 'subconverter replacement'
assert_eq fresh-rule "$(<"$BIN_SUBCONVERTER_DIR/config/fresh.ini")" \
    'subconverter archive content'
assert_eq '<html>new-ui</html>' "$(<"$CLASH_RESOURCES_DIR/dist/index.html")" \
    'Web UI archive content'
assert_eq legacy-manpage "$(<"$BIN_BASE_DIR/yq.1")" 'unrelated legacy manual is untouched'
assert_eq legacy-installer "$(<"$BIN_BASE_DIR/install-man-page.sh")" 'unrelated legacy installer is untouched'
assert_absent "$BIN_SUBCONVERTER_DIR/stale.ini" 'stale subconverter cleanup'
assert_absent "$CLASH_RESOURCES_DIR/dist/stale.js" 'stale Web UI cleanup'

assert_owned_tree "$BIN_KERNEL" 'kernel ownership'
assert_owned_tree "$BIN_YQ" 'yq ownership'
assert_owned_tree "$BIN_SUBCONVERTER_DIR" 'subconverter ownership'
assert_owned_tree "$CLASH_RESOURCES_DIR/dist" 'Web UI ownership'
assert_mode 755 "$BIN_KERNEL" 'kernel mode'
assert_mode 755 "$BIN_YQ" 'yq mode'
assert_mode 755 "$BIN_SUBCONVERTER_DIR" 'subconverter directory mode'
assert_mode 755 "$BIN_SUBCONVERTER" 'subconverter executable mode'
assert_mode 600 "$BIN_SUBCONVERTER_CONFIG" 'subconverter runtime config mode'
assert_mode 644 "$BIN_SUBCONVERTER_DIR/config/fresh.ini" 'subconverter data mode'
assert_public_tree_modes "$CLASH_RESOURCES_DIR/dist" 'Web UI modes'
assert_no_stages
assert_contains "$stderr_file" '运行组件已安装' 'successful component installation output'

# yq 最终落位校验失败，只恢复 yq；此前成功的内核保留，后续组件不处理。
configure_home single-rollback
seed_existing_components
real_file_verifier=$(declare -f _component_file_is_safe)
(
    eval "${real_file_verifier/_component_file_is_safe/_original_file_verifier}"
    _component_file_is_safe() {
        [ "$1" != "$BIN_YQ" ] && _original_file_verifier "$@"
    }
    rc=0
    unzip_zip >"$WORK_DIR/single-rollback.out" 2>&1 || rc=$?
    assert_eq 1 "$rc" 'failed final verification status'
    assert_eq new-kernel "$(<"$BIN_KERNEL")" 'earlier installed kernel remains'
    assert_eq old-yq "$(<"$BIN_YQ")" 'failed yq restored previous component'
    assert_eq old-converter "$(<"$BIN_SUBCONVERTER")" 'later converter remains untouched'
    assert_no_stages
)
# 恢复失败必须保留备份；不能随暂存目录一起删除。
(
    eval "${real_file_verifier/_component_file_is_safe/_original_file_verifier}"
    _component_file_is_safe() {
        [ "$1" != "$BIN_YQ" ] && _original_file_verifier "$@"
    }
    function /bin/mv() {
        case "$3" in */previous) return 1 ;; esac
        command /bin/mv "$@"
    }
    rc=0
    _install_component yq "$ZIP_YQ" >"$WORK_DIR/restore-failure.out" 2>&1 || rc=$?
    assert_eq 1 "$rc" 'restore failure status'
    backup=$(find "$BIN_BASE_DIR" -path '*/.components.*/previous' -print -quit)
    [ -n "$backup" ] || fail 'failed restore deleted backup'
    assert_eq old-yq "$(<"$backup")" 'failed restore kept original data'
    assert_contains "$WORK_DIR/restore-failure.out" '已保留暂存目录' 'restore failure diagnosis'
)
# 无旧文件时，落位后失败应清除失败候选文件。
configure_home fresh-rollback
rm -f "$BIN_YQ"
(
    eval "${real_file_verifier/_component_file_is_safe/_original_file_verifier}"
    _component_file_is_safe() {
        [ "$1" != "$BIN_YQ" ] && _original_file_verifier "$@"
    }
    if _install_component yq "$ZIP_YQ" >/dev/null 2>&1; then fail 'invalid new yq accepted'; fi
    assert_absent "$BIN_YQ" 'failed new component cleanup'
    assert_no_stages
)
# 单独补装 UI 不访问 bin；单独安装内核不访问 resources。
(
    configure_home isolated-ui
    rm -rf "$BIN_BASE_DIR"
    ln -s "$bin_external" "$BIN_BASE_DIR"
    ZIP_KERNEL='' ZIP_YQ='' ZIP_SUBCONVERTER=
    unzip_zip >/dev/null || fail 'UI-only install touched binary directory'
    assert_external_untouched "$bin_external" 'UI-only install'
)
(
    configure_home isolated-kernel
    rm -rf "$CLASH_RESOURCES_DIR"
    ln -s "$resources_external" "$CLASH_RESOURCES_DIR"
    ZIP_YQ='' ZIP_SUBCONVERTER='' ZIP_UI=
    unzip_zip >/dev/null || fail 'kernel-only install touched resources directory'
    assert_external_untouched "$resources_external" 'kernel-only install'
)

configure_home invalid-layout
seed_existing_components
# shellcheck disable=SC2034
ZIP_SUBCONVERTER="$ARCHIVE_DIR/subconverter-invalid.tar.gz"
stderr_file="$WORK_DIR/invalid-layout.stderr"
rc=0
unzip_zip >"$WORK_DIR/invalid-layout.stdout" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'invalid subconverter layout failure status'
assert_contains "$stderr_file" 'subconverter 归档结构无效' \
    'invalid subconverter layout diagnostic'
assert_contains "$stderr_file" '已废弃布局无效的依赖缓存：subconverter' \
    'invalid subconverter cache discard diagnostic'
assert_contains "$stderr_file" '安装器将重新下载该组件' \
    'invalid subconverter cache retry diagnostic'
assert_absent "$ZIP_SUBCONVERTER" 'invalid subconverter layout cache discard'
assert_eq new-kernel "$(<"$BIN_KERNEL")" 'invalid layout kept completed kernel'
assert_eq new-yq "$(<"$BIN_YQ")" 'invalid layout kept completed yq'
assert_eq old-converter "$(<"$BIN_SUBCONVERTER")" \
    'invalid layout preserved subconverter'
assert_eq '<html>old-ui</html>' "$(<"$CLASH_RESOURCES_DIR/dist/index.html")" \
    'invalid layout preserved Web UI'
assert_no_stages

configure_home extraction-failure
seed_existing_components
# shellcheck disable=SC2034
ZIP_SUBCONVERTER="$ARCHIVE_DIR/subconverter-extraction-failure.tar.gz"
stderr_file="$WORK_DIR/extraction-failure.stderr"
rc=0
unzip_zip >"$WORK_DIR/extraction-failure.stdout" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'subconverter extraction failure status'
assert_contains "$stderr_file" '准备 subconverter 失败' \
    'subconverter extraction failure diagnostic'
[ -f "$ZIP_SUBCONVERTER" ] || fail 'non-layout failure removed managed cache'
assert_eq new-kernel "$(<"$BIN_KERNEL")" 'extraction failure kept completed kernel'
assert_eq new-yq "$(<"$BIN_YQ")" 'extraction failure kept completed yq'
assert_eq old-converter "$(<"$BIN_SUBCONVERTER")" \
    'extraction failure preserved subconverter'
assert_eq '<html>old-ui</html>' "$(<"$CLASH_RESOURCES_DIR/dist/index.html")" \
    'extraction failure preserved Web UI'
assert_no_stages

# ── 版本解析优先级：最新查询 > 内置钉版（用户钉版通道已移除）──
# 计数走文件：桩经 $( ) 子 shell 调用，变量副作用无法传回父 shell
latest_query_log="$WORK_DIR/latest-queries"
: >"$latest_query_log"
_fetch_latest_tag() {
    printf 'x' >>"$latest_query_log"
    [ "${LATEST_QUERY_RC:-0}" -eq 0 ] && printf 'v1.2.3-latest\n' || return 1
}
resolve_out="$WORK_DIR/resolve.out"

# 未钉版：查询最新并采用
: >"$resolve_out"
: >"$latest_query_log"
VERSION_MIHOMO=
CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=0
_resolve_version VERSION_MIHOMO MetaCubeX/mihomo >>"$resolve_out" 2>&1
assert_eq v1.2.3-latest "$VERSION_MIHOMO" 'latest is used when unpinned'
assert_eq 1 "$(wc -c <"$latest_query_log")" 'unpinned triggers exactly one latest query'
assert_contains "$resolve_out" '最新版本' 'latest source is labeled'

# 查询失败：回退内置钉版，且整批只警告一次
: >"$resolve_out"
: >"$latest_query_log"
LATEST_QUERY_RC=1
VERSION_MIHOMO='' VERSION_YQ=
CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=0
_resolve_version VERSION_MIHOMO MetaCubeX/mihomo >>"$resolve_out" 2>&1
_resolve_version VERSION_YQ mikefarah/yq >>"$resolve_out" 2>&1
assert_eq "$DEFAULT_VERSION_MIHOMO" "$VERSION_MIHOMO" 'query failure falls back to built-in pin'
assert_contains "$resolve_out" '内置版本' 'fallback source is labeled'
assert_eq 1 "$(grep -c '无法查询部分组件' "$resolve_out")" \
    'fallback warning fires exactly once per batch'
unset LATEST_QUERY_RC

# ── _fetch_latest_tag 双通道回退：设 GH_PROXY 时代理优先、直连兜底 ──
# （上方测试用桩覆盖了真函数；子 shell 重源 preflight.sh 恢复，PATH 前置假 curl。
#   加速前缀对 api.github.com 支持不一：ghfast.top 403、gh-proxy.org 200，故须都试）
tag_curl_dir="$WORK_DIR/tag-curl-bin"
mkdir -p -- "$tag_curl_dir"
cat >"$tag_curl_dir/curl" <<'SCRIPT'
#!/usr/bin/env bash
# 假 curl：按 URL 前缀区分通道；BODY 为空代表该通道失败（--fail 语义）
url=${*: -1}
printf '%s\n' "$url" >>"${TAG_URL_LOG:?}"
case $url in
"$TAG_PROXY_PREFIX"*)
    [ -n "${TAG_PROXY_BODY:-}" ] || exit 22
    printf '%s' "$TAG_PROXY_BODY"
    ;;
https://api.github.com/*)
    [ -n "${TAG_DIRECT_BODY:-}" ] || exit 22
    printf '%s' "$TAG_DIRECT_BODY"
    ;;
*)
    exit 0
    ;;
esac
SCRIPT
chmod +x "$tag_curl_dir/curl"
tag_url_log="$WORK_DIR/tag-urls"
tag_query() {
    (
        # BODY 等变量须显式导出：假 curl 是独立进程，只看得见环境变量
        # shellcheck disable=SC2030  # PATH 仅在此查询子 shell 中替换。
        export PATH="$tag_curl_dir:$PATH" TAG_URL_LOG=$tag_url_log \
            TAG_PROXY_PREFIX=https://ghfast.top/ \
            TAG_PROXY_BODY=${TAG_PROXY_BODY-} TAG_DIRECT_BODY=${TAG_DIRECT_BODY-}
        # shellcheck source=../scripts/preflight.sh
        . "$REPO_DIR/scripts/preflight.sh"
        _fetch_latest_tag "$1"
    )
}
tag_body='{"tag_name": "v1.2.3", "name": "release"}'

# 未设代理：仅直连一次
: >"$tag_url_log"
unset GH_PROXY TAG_PROXY_BODY
TAG_DIRECT_BODY=$tag_body
assert_eq v1.2.3 "$(tag_query mikefarah/yq)" 'direct channel resolves the latest tag'
assert_eq 1 "$(wc -l <"$tag_url_log")" 'without proxy exactly one URL is queried'
case $(<"$tag_url_log") in
https://api.github.com/*) ;;
*) fail 'tag query without proxy did not hit api.github.com directly' ;;
esac

# 代理支持 api：代理优先命中即止（不再试直连）
: >"$tag_url_log"
export GH_PROXY=https://ghfast.top/
TAG_PROXY_BODY='{"tag_name": "v9.9.9"}' TAG_DIRECT_BODY=$tag_body
assert_eq v9.9.9 "$(tag_query MetaCubeX/mihomo)" 'proxy channel resolves the latest tag'
assert_eq 1 "$(wc -l <"$tag_url_log")" 'proxy hit stops before trying direct'
case $(<"$tag_url_log") in
https://ghfast.top/*) ;;
*) fail 'tag query with proxy did not try the proxy channel first' ;;
esac

# 代理不支持 api（403 → --fail 非零）：回退直连
: >"$tag_url_log"
TAG_PROXY_BODY='' TAG_DIRECT_BODY=$tag_body
assert_eq v1.2.3 "$(tag_query MetaCubeX/mihomo)" \
    'direct fallback resolves the tag when the proxy rejects api.github.com'
assert_eq 2 "$(wc -l <"$tag_url_log")" 'proxy failure falls through to direct'
case $(<"$tag_url_log") in
https://ghfast.top/*$'\n'https://api.github.com/*) ;;
*) fail 'tag query did not try proxy first then direct' ;;
esac

# 代理 200 但正文无 tag_name：视作失败继续直连（不采纳空结果）
: >"$tag_url_log"
TAG_PROXY_BODY='{"message": "rate limited"}' TAG_DIRECT_BODY=$tag_body
assert_eq v1.2.3 "$(tag_query MetaCubeX/mihomo)" \
    'unparseable proxy body falls through to direct'
assert_eq 2 "$(wc -l <"$tag_url_log")" 'unparseable proxy body retries over direct'

# 双通道皆败：返回非零（调用方回退内置钉版）
TAG_PROXY_BODY='' TAG_DIRECT_BODY=
tag_rc=0 tag_out=$(tag_query MetaCubeX/mihomo) || tag_rc=$?
[ "$tag_rc" -ne 0 ] || fail 'tag query succeeded with both channels failing'
[ -z "$tag_out" ] || fail 'failed tag query still printed a tag'
unset GH_PROXY TAG_PROXY_BODY TAG_DIRECT_BODY

# ── 系统 yq 复用：版本门（mikefarah v4 才兼容）与下载跳过 ──
fake_bin="$WORK_DIR/fake-path-bin"
mkdir -p -- "$fake_bin"

make_fake_yq() {
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" >"$fake_bin/yq"
    chmod 0755 -- "$fake_bin/yq"
}

make_fake_yq 'yq (https://github.com/mikefarah/yq/) version v4.53.6'
# shellcheck disable=SC2031  # 上面的 tag_query 不会改变当前 shell 的 PATH。
PATH="$fake_bin:$PATH" system_yq=$(_get_system_yq)
assert_eq "$fake_bin/yq" "$system_yq" 'mikefarah v4 system yq is accepted'

make_fake_yq 'yq 3.4.1'
PATH="$fake_bin:$PATH" _get_system_yq 2>/dev/null &&
    fail 'python-flavored system yq must be rejected'

make_fake_yq 'yq (https://github.com/mikefarah/yq/) version v5.0.0'
PATH="$fake_bin:$PATH" _get_system_yq 2>/dev/null &&
    fail 'untested yq major version must be rejected'

rm -f -- "$fake_bin/yq"

# prepare_zip：系统 yq 可用且本地未装时跳过 yq 下载
configure_home yq-skip
make_fake_yq 'yq (https://github.com/mikefarah/yq/) version v4.53.6'
_real_unzip_zip=$(declare -f unzip_zip)
download_zip() {
    printf '%s\n' "$*" >"$WORK_DIR/yq-skip-components"
    case $* in *mihomo*) ZIP_KERNEL=stub-mihomo.gz ;; esac
    case $* in *yq*) ZIP_YQ=stub-yq.tgz ;; esac
    case $* in *subconverter*) ZIP_SUBCONVERTER=stub-converter.tgz ;; esac
    case $* in *ui*) ZIP_UI=stub-ui.zip ;; esac
    return 0
}
unzip_zip() {
    printf '%s|%s|%s|%s\n' "$ZIP_KERNEL" "$ZIP_YQ" "$ZIP_SUBCONVERTER" "$ZIP_UI" \
        >"$WORK_DIR/selected-archives"
}
PATH="$fake_bin:$PATH" prepare_zip kernel yq
assert_eq 'mihomo' "$(<"$WORK_DIR/yq-skip-components")" \
    'compatible system yq skips the yq download'

# 系统 yq 不兼容时照常下载
make_fake_yq 'yq 3.4.1'
PATH="$fake_bin:$PATH" prepare_zip kernel yq
assert_eq 'mihomo yq' "$(<"$WORK_DIR/yq-skip-components")" \
    'incompatible system yq still downloads yq'

# 本地 bin/yq 已存在时不用系统副本（刷新语义不变）
configure_home yq-local
printf '#!/bin/sh\n' >"$BIN_BASE_DIR/yq"
chmod 0755 -- "$BIN_BASE_DIR/yq"
make_fake_yq 'yq (https://github.com/mikefarah/yq/) version v4.53.6'
PATH="$fake_bin:$PATH" prepare_zip kernel yq
assert_eq 'mihomo yq' "$(<"$WORK_DIR/yq-skip-components")" \
    'existing local yq is refreshed rather than replaced by system copy'

# 按需补装复用同一入口，但不能携带前次安装的内核或 yq 归档。
prepare_zip ui
assert_eq 'ui' "$(<"$WORK_DIR/yq-skip-components")" 'optional UI requests only UI'
assert_eq '|||stub-ui.zip' "$(<"$WORK_DIR/selected-archives")" 'optional UI excludes previous archives'
prepare_zip subconverter
assert_eq '||stub-converter.tgz|' "$(<"$WORK_DIR/selected-archives")" \
    'optional converter excludes previous archives'
rm -f -- "$fake_bin/yq"
unset -f download_zip
eval "$_real_unzip_zip"

# ── 部分组件集（按需补装场景）：仅 UI 时其他组件不动 ──
configure_home ui-only
seed_existing_components
stdout_file="$WORK_DIR/ui-only.stdout"
stderr_file="$WORK_DIR/ui-only.stderr"
ZIP_KERNEL='' ZIP_YQ='' ZIP_SUBCONVERTER='' ZIP_UI="$ARCHIVE_DIR/ui.zip" \
    unzip_zip >"$stdout_file" 2>"$stderr_file" ||
    fail "ui-only provisioning failed: $(<"$stderr_file")"
assert_eq old-kernel "$(<"$BIN_KERNEL")" 'ui-only provisioning keeps the kernel'
assert_eq old-yq "$(<"$BIN_YQ")" 'ui-only provisioning keeps yq'
assert_eq old-converter "$(<"$BIN_SUBCONVERTER")" 'ui-only provisioning keeps subconverter'
assert_eq '<html>new-ui</html>' "$(<"$CLASH_RESOURCES_DIR/dist/index.html")" \
    'ui-only provisioning replaces the Web UI'
assert_absent "$CLASH_RESOURCES_DIR/dist/stale.js" 'ui-only provisioning cleans stale UI'
assert_no_stages
assert_contains "$stderr_file" '运行组件已安装' 'ui-only provisioning success output'

if [ "$(id -u)" -eq 0 ]; then
    printf 'preflight-components: ok (root numeric-owner coverage)\n'
else
    # 更新器的库可以来自新源码，但配置始终来自目标安装。
(
    bootstrap="$WORK_DIR/bootstrap-source"
    target_home="$WORK_DIR/target-config"
    mkdir -p "$bootstrap/scripts" "$target_home"
    ln -s "$REPO_DIR/scripts/lib" "$bootstrap/scripts/lib"
    printf 'exit 91\n' >"$bootstrap/.env"
    printf 'CLASHCTL_SUB_TIMEOUT=37\n' >"$target_home/.env"
    export CLASHCTL_SRC="$bootstrap" CLASHCTL_HOME="$target_home"
    . "$REPO_DIR/scripts/preflight.sh" || fail 'preflight loaded bootstrap configuration'
    [ "$CLASHCTL_SUB_TIMEOUT" = 37 ] || fail 'preflight did not load target configuration'
)

printf 'preflight-components: ok (numeric-owner root behavior requires root)\n'
fi
