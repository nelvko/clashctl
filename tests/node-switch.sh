#!/usr/bin/env bash
# 保留真实 JSON 构造和 curl 封装；旧版 curl 替身不支持 --data-raw。
# shellcheck disable=SC2317  # 替身由待测函数间接调用。
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected [$1], got [$2]"; }
assert_contains() { grep -Fqs -- "$2" "$1" || fail "$3: missing [$2]"; }
assert_not_contains() { if grep -Fqs -- "$2" "$1"; then fail "$3: unexpectedly found [$2]"; fi; }
export CLASHCTL_HOME="$WORK_DIR/home" CLASHCTL_COLOR=never
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/cmd/node.sh
. "$REPO_DIR/scripts/cmd/node.sh"
[ -x "$BIN_YQ" ] || fail 'mikefarah yq v4 is required'

_node_api_base() { printf 'http://fixture.invalid:9090'; }
_get_secret() { printf '%s' "$SECRET"; }
curl() {
    local arg
    printf '%s\0' "$@" >"$WORK_DIR/curl-args"
    for arg in "$@"; do
        if [ "$arg" = --data-raw ]; then
            printf 'curl: option --data-raw: is unknown\n' >&2
            return 2
        fi
    done
    printf '%s' "$HTTP_CODE"
    return "$CURL_RC"
}

GROUP=$'策略 A 🚀/?#\n'
MEMBER=$'@节点 🇭🇰 "引号" \\\n下一行'
SECRET='fixture secret'
export CLASHCTL_API_TIMEOUT=3
CURL_RC=0 HTTP_CODE=204
output="$WORK_DIR/output"
checks=0
switch_result() {
    local rc=0
    _node_apply "$GROUP" "$MEMBER" >"$output" 2>&1 || rc=$?
    assert_eq "$1" "$rc" 'switch exit status'
    assert_contains "$output" "$2" 'switch diagnostic'
    checks=$((checks + 1))
}

switch_result 0 '已切换'
python3 - "$WORK_DIR/curl-args" "$GROUP" "$MEMBER" "$SECRET" <<'PY'
import json
from pathlib import Path
import sys
from urllib.parse import quote

path, group, member, secret = sys.argv[1:]
args = Path(path).read_bytes().decode().split("\0")[:-1]
def value(option):
    assert args.count(option) == 1, args
    return args[args.index(option) + 1]

assert "--data-raw" not in args, args
assert value("-X") == "PUT", args
assert value("--noproxy") == "*", args
assert value("--max-time") == "3", args
assert value("-o") == "/dev/null", args
assert value("-w") == "%{http_code}", args
headers = [args[i + 1] for i, arg in enumerate(args) if arg == "-H"]
assert headers == [f"Authorization: Bearer {secret}", "Content-Type: application/json"], args
assert f"http://fixture.invalid:9090/proxies/{quote(group, safe='')}" in args, args
assert json.loads(value("--data-binary")) == {"name": member}, args
PY

# 无 HTTP 状态码、000，甚至传输失败前输出了 204，都必须报告 curl 失败。
for scenario in 2: 7:000 28:000 7:204; do
    CURL_RC=${scenario%%:*} HTTP_CODE=${scenario#*:}
    switch_result 1 "切换失败：控制器请求失败（curl 退出码：$CURL_RC）"
    assert_not_contains "$output" '控制器返回' 'request failure misreported as HTTP response'
    assert_not_contains "$output" '已切换' 'request failure reported success'
done

CURL_RC=0
HTTP_CODE=400 switch_result 1 '或该组不可手动切换'
HTTP_CODE=404 switch_result 1 '不存在'
HTTP_CODE=401 switch_result 1 '控制器返回 401'
printf 'node-switch: %s checks passed\n' "$checks"
