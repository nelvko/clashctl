#!/usr/bin/env bash
# 订阅 HTML 检测：真实 HTML 页面须拒绝；字段值中含 HTML 标签文本的原生配置不能误判。
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'command rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 测试不下载依赖；CI 安装固定版本，本地可通过 TEST_YQ 指定 MikeFarah yq v4。
TEST_YQ=${TEST_YQ:-$(command -v yq || true)}
if [ -z "$TEST_YQ" ] || [ ! -x "$TEST_YQ" ]; then
    fail 'MikeFarah yq v4 is required; set TEST_YQ to its executable'
fi
case $("$TEST_YQ" --version 2>&1) in
*mikefarah*v4.*) ;;
*) fail 'TEST_YQ must be MikeFarah yq v4' ;;
esac

# shellcheck source=../scripts/lib/convert.sh
. "$REPO_DIR/scripts/lib/convert.sh"
# shellcheck disable=SC2034  # 供 _is_native_yaml_config 读取
BIN_YQ=$TEST_YQ

# 机场常把 HTML 片段放进 ws 伪装路径，配置本身合法。
cat >"$WORK_DIR/native.yaml" <<'EOF'
proxies:
  - {name: test, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, network: ws, ws-opts: {path: /video.m3u8<!DOCTYPE html>}}
EOF
_is_html_response "$WORK_DIR/native.yaml" && fail 'native config with HTML text in a field was treated as HTML'

cat >"$WORK_DIR/page.html" <<'EOF'
<!DOCTYPE html>
<html><head><title>Login</title></head><body></body></html>
EOF
_is_html_response "$WORK_DIR/page.html" || fail 'HTML page was not detected'

printf 'html-detection: ok\n'
