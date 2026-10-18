#!/usr/bin/env bash
# 首次使用 UI/订阅转换器走真实组件安装，只替换网络和运行中的服务。
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
command -v zsh >/dev/null || fail 'zsh is required'
export COMPONENT_FIXTURES="$WORK_DIR/fixtures" COMPONENT_DOWNLOADS="$WORK_DIR/downloads"
mkdir -p "$COMPONENT_FIXTURES/subconverter" "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$COMPONENT_FIXTURES/subconverter/subconverter"
chmod 0755 "$COMPONENT_FIXTURES/subconverter/subconverter"
printf 'server:\n  port: 25500\n' >"$COMPONENT_FIXTURES/subconverter/pref.example.yml"
tar -czf "$COMPONENT_FIXTURES/converter.tar.gz" -C "$COMPONENT_FIXTURES" subconverter
python3 - "$COMPONENT_FIXTURES/ui.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as archive:
    archive.writestr('dist/index.html', '<html>fixture</html>')
PY
cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
destination=''
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output) destination=$2; shift ;;
    http://* | https://*) url=$1 ;;
    esac
    shift
done
case "$url" in
*/releases/latest) printf '{"tag_name":"v1.2.3"}' ;;
*/dist.zip | */subconverter_*.tar.gz)
    [ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
    case "$url" in
    */dist.zip) name=ui; file=ui.zip ;;
    *) name=subconverter; file=converter.tar.gz ;;
    esac
    printf '%s\n' "$name" >>"$COMPONENT_DOWNLOADS"
    cp "$COMPONENT_FIXTURES/$file" "$destination"
    ;;
http://localhost:25500/version) printf fixture ;;
https://api64.ipify.org) printf 127.0.0.1 ;;
*) printf 'unexpected URL: %s\n' "$url" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK_DIR/bin/curl"
cat >"$WORK_DIR/probe.sh" <<'PROBE'
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
clashctl ui || exit 1
clashctl ui || exit 1
[ -f "$CLASH_RESOURCES_DIR/dist/index.html" ] || exit 1
[ "$(grep -c '^ui$' "$COMPONENT_DOWNLOADS")" = 1 ] || exit 1
# 订阅转换只经 clashsub 等 Bash 入口到达，zsh 下只覆盖 clashctl ui。
if [ -n "${BASH_VERSION:-}" ]; then
    _start_convert || exit 1
    _start_convert || exit 1
    [ -x "$BIN_SUBCONVERTER" ] && [ -f "$BIN_SUBCONVERTER_CONFIG" ] || exit 1
    [ "$(grep -c '^subconverter$' "$COMPONENT_DOWNLOADS")" = 1 ] || exit 1
fi
# 下载失败应阻止后续使用，保留原来的错误返回值。
rm -rf "$CLASH_RESOURCES_DIR/dist" "$BIN_SUBCONVERTER_DIR" "$CLASHCTL_HOME/archives"
rm "$CLASHCTL_HOME/service-queried"
export FAIL_DOWNLOAD=1
if clashctl ui; then exit 1; fi
[ ! -e "$CLASHCTL_HOME/service-queried" ] || exit 1
if [ -n "${BASH_VERSION:-}" ] && _start_convert; then exit 1; fi
PROBE
for shell in bash zsh; do
    home_dir="$WORK_DIR/$shell"
    make_fake_home "$home_dir"
    mkdir -p "$home_dir/resources"
    # Zsh 转发到 Bash 时会重新加载脚本，模拟函数也必须随之加载。
    cat >"$home_dir/scripts/cmd/zz-fixture.sh" <<'STUB'
_detect_ext_addr() { EXT_IP=127.0.0.1; EXT_PORT=9090; }
service_is_active() { touch "$CLASHCTL_HOME/service-queried"; }
STUB
    # 模拟失效时应明确失败，不能借用宿主机上已运行的 systemd 服务。
    printf 'GH_PROXY=\n' >>"$home_dir/.env"
    printf '#!/bin/sh\nprintf 25500\n' >"$home_dir/bin/yq"
    chmod +x "$home_dir/bin/yq"
    : >"$COMPONENT_DOWNLOADS"
    shell_args=()
    [ "$shell" != zsh ] || shell_args=(-f)
    PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$home_dir" "$shell" "${shell_args[@]}" "$WORK_DIR/probe.sh" \
        >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail "$shell lazy component installation failed"; }
done
printf 'lazy-components: ok\n'
