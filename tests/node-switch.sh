#!/usr/bin/env bash
# 保留真实 JSON 构造和 curl 封装；旧版 curl 替身不支持 --data-raw。
# shellcheck disable=SC2317  # 替身由待测函数间接调用。
set -euo pipefail

# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/lib/common.sh"
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

# 共用组选速路径：旧内核 404/405 回退，组超时或认证失败不再重复逐节点请求。
service_is_active() { return 0; }
DELAY_GROUP='策略 A 🚀/?#'
DELAY_NODE='节点 A/?'
DELAY_URL='https://fixture.invalid/ping?token=a&b=中文#frag'
requests="$WORK_DIR/delay-requests"
curl() {
    local arg target=''
    for arg; do
        [[ $arg = http://fixture.invalid:* ]] && target=$arg
    done
    printf '%s\n' "$target" >>"$requests"
    case $target in
    */group/*/delay?*)
        if [ "$HTTP_CODE" = 200 ]; then
            printf '{"节点 A/?":31}'
        else
            printf '{"message":"fixture failure"}'
        fi
        printf '\n%s' "$HTTP_CODE"
        ;;
    */proxies/*/delay?*) printf '{"delay":17}' ;;
    */proxies/*) printf '{"all":["节点 A/?","DIRECT"]}' ;;
    *) fail "unexpected controller route: $target" ;;
    esac
}
for HTTP_CODE in 200 404 405 504 401; do
    : >"$requests"
    rc=0
    clashnode delay -g --url "$DELAY_URL" --timeout=2500 "$DELAY_GROUP" >"$output" 2>&1 || rc=$?
    case $HTTP_CODE in
    404 | 405)
        assert_eq 4 "$(wc -l <"$requests")" 'old API fallback request count'
        assert_contains "$output" '17ms' 'old API fallback delay'
        ;;
    401)
        assert_eq 1 "$rc" 'group authentication failure'
        assert_eq 2 "$(wc -l <"$requests")" 'authentication failure must not trigger fallback'
        assert_contains "$output" '控制器返回 401' 'group authentication diagnosis'
        assert_not_contains "$output" '超时' 'authentication failure reported as timeout'
        ;;
    *)
        assert_eq 2 "$(wc -l <"$requests")" 'group API must not repeat delay requests'
        assert_contains "$output" '超时' 'missing or failed group result'
        [ "$HTTP_CODE" != 200 ] || assert_contains "$output" '31ms' 'group API delay'
        ;;
    esac
    python3 - "$requests" "$DELAY_GROUP" "$DELAY_URL" <<'PYTHON'
from pathlib import Path
import sys
from urllib.parse import parse_qs, quote, urlparse
path, group, target = sys.argv[1:]
urls = Path(path).read_text().splitlines()
assert urls[0].endswith('/proxies/' + quote(group, safe='')), urls
request = urlparse(urls[1])
assert request.path == '/group/' + quote(group, safe='') + '/delay', urls
for url in urls[1:]:
    assert parse_qs(urlparse(url).query) == {'timeout': ['2500'], 'url': [target]}, urls
PYTHON
    checks=$((checks + 1))
done

# 共用选项解析仍区分 use/delay 的参数，并保留校验与 -- 的原有语义。
for arguments in 'use -g' 'delay -d' 'delay -g -p'; do
    rc=0
    read -r -a options <<<"$arguments"
    clashnode "${options[@]}" >"$output" 2>&1 || rc=$?
    assert_eq 1 "$rc" 'invalid node options'
    checks=$((checks + 1))
done
assert_contains "$output" '不能同时使用' 'conflicting delay modes'
_node_apply() { printf '%s\t%s\n' "$1" "$2" >"$WORK_DIR/applied"; }
clashnode use -- --group -member
assert_eq $'--group\t-member' "$(cat "$WORK_DIR/applied")" 'literal names following --'
checks=$((checks + 1))
printf 'node-switch: %s checks passed\n' "$checks"
