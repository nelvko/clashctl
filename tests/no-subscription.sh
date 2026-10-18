#!/usr/bin/env bash
# 无订阅时能用默认直连配置运行；订阅、Mixin 错误不能覆盖有效运行配置。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

# 测试不下载依赖；CI 安装固定版本，本地可通过 TEST_YQ 指定 MikeFarah yq v4。
TEST_YQ=${TEST_YQ:-$(command -v yq || true)}
if [ -z "$TEST_YQ" ] || [ ! -x "$TEST_YQ" ]; then
    fail 'MikeFarah yq v4 is required; set TEST_YQ to its executable'
fi
case $("$TEST_YQ" --version 2>&1) in
*mikefarah*v4.*) ;;
*) fail 'TEST_YQ must be MikeFarah yq v4' ;;
esac
export TEST_YQ
export CLASHCTL_HOME="$WORK_DIR/home" CLASHCTL_KERNEL=mihomo CLASHCTL_COLOR=never TERM=dumb
mkdir -p -- "$CLASHCTL_HOME/data" "$CLASHCTL_HOME/resources"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/config.sh
. "$REPO_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/convert.sh
. "$REPO_DIR/scripts/lib/convert.sh"
# shellcheck source=../scripts/lib/shell.sh
. "$REPO_DIR/scripts/lib/shell.sh"
# shellcheck source=../scripts/cmd/start.sh
. "$REPO_DIR/scripts/cmd/start.sh"
# shellcheck source=../scripts/cmd/on.sh
. "$REPO_DIR/scripts/cmd/on.sh"
# shellcheck source=../scripts/cmd/sub.sh
. "$REPO_DIR/scripts/cmd/sub.sh"
BIN_YQ=$TEST_YQ
BIN_KERNEL="$WORK_DIR/kernel"
cat >"$BIN_KERNEL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
config=''
while [ "$#" -gt 0 ]; do
    case $1 in
    -f) config=$2; shift 2 ;;
    -d) shift 2 ;;
    -t) shift ;;
    *) exit 1 ;;
    esac
done
if ! "$TEST_YQ" -e 'tag == "!!map" and
    ((.mode // "rule") == "rule" or (.mode // "rule") == "direct" or (.mode // "rule") == "global")' \
    "$config" >/dev/null 2>&1; then
    printf 'kernel: invalid configuration\n' >&2
    exit 1
fi
EOF
chmod +x "$BIN_KERNEL"
cp -- "$REPO_DIR/resources/mixin.yaml.example" "$CLASH_CONFIG_MIXIN"
cp -- "$REPO_DIR/resources/profiles.yaml" "$CLASH_PROFILES_META"
cp -- "$CLASH_PROFILES_META" "$WORK_DIR/metadata.before"

# 服务替身只记录生命周期，不访问宿主服务、不监听端口。
KERNEL_RUNNING=false STARTUP_ENABLED=false
service_is_active() { [ "$KERNEL_RUNNING" = true ]; }
service_start() { _require_base_config && _valid_config "$CLASH_CONFIG_RUNTIME" && KERNEL_RUNNING=true; }
service_stop() { KERNEL_RUNNING=false; }
service_enable() { STARTUP_ENABLED=true; }
_tun_is_active() { return 1; }
_is_port_used() { return 1; }
_get_local_ip() { printf '127.0.0.1\n'; }

assert_runtime() {
    "$TEST_YQ" -e "$1" "$CLASH_CONFIG_RUNTIME" >/dev/null || fail "$2"
}
assert_preserved() {
    if _merge_config >"$WORK_DIR/result" 2>&1; then
        fail "$1 was accepted"
    fi
    cmp -s -- "$WORK_DIR/runtime.before" "$CLASH_CONFIG_RUNTIME" || fail "$1 replaced the working runtime"
    [ -s "$WORK_DIR/result" ] || fail "$1 omitted its diagnostic"
}

# 缺失主配置也可启动、设置自启和启用终端代理，无需虚构订阅文件或记录。
clashon >"$WORK_DIR/result" 2>&1 || { cat "$WORK_DIR/result" >&2; fail 'fresh direct startup failed'; }
[ "$KERNEL_RUNNING" = true ] || fail 'direct startup did not start its service'
[ "$STARTUP_ENABLED" = true ] || fail 'direct startup did not enable its service'
[ "${http_proxy:-}" = http://127.0.0.1:7890 ] || fail 'direct startup did not expose the local proxy'
[ ! -e "$CLASH_CONFIG_BASE" ] || fail 'direct startup wrote a fake base configuration'
cmp -s -- "$WORK_DIR/metadata.before" "$CLASH_PROFILES_META" || fail 'direct startup selected a fake subscription'
assert_runtime '.mode == "direct" and .mixed-port == 7890 and .tun.enable == false' 'default direct runtime is incomplete'
assert_runtime '(.proxies | length) == 0 and (.proxy-groups | length) == 0' 'default direct runtime contains fake nodes'

: >"$CLASH_CONFIG_BASE"
_merge_config >"$WORK_DIR/result" 2>&1 || fail 'empty base could not generate a direct runtime'
[ ! -s "$CLASH_CONFIG_BASE" ] || fail 'direct merge modified an empty base'
cmp -s -- "$WORK_DIR/metadata.before" "$CLASH_PROFILES_META" || fail 'direct merge changed subscription metadata'

# Mixin 的显式规则模式、自定义节点和端口仍优先，不被默认直连配置覆盖。
"$TEST_YQ" -i '.mode = "rule" | .mixed-port = 18080 | .secret = "local-secret" |
    .proxies.append = [{"name": "custom", "type": "http", "server": "127.0.0.1", "port": 18081}]' "$CLASH_CONFIG_MIXIN"
_merge_config >"$WORK_DIR/result" 2>&1 || fail 'custom Mixin could not run without a subscription'
assert_runtime '.mode == "rule" and .mixed-port == 18080 and .secret == "local-secret"' 'direct fallback overrode Mixin settings'
assert_runtime '(.proxies | length) == 1 and .proxies[0].name == "custom"' 'direct fallback dropped custom Mixin nodes'

# 从直连切换到真实订阅时，由订阅提供的模式、节点接管默认基础配置。
cp -- "$REPO_DIR/resources/mixin.yaml.example" "$CLASH_CONFIG_MIXIN"
_merge_config >"$WORK_DIR/result" 2>&1 || fail 'could not restore direct runtime before adding a subscription'
rm -f -- "$CLASH_CONFIG_BASE"
cp -- "$CLASH_CONFIG_RUNTIME" "$WORK_DIR/direct.before"
mkdir -p -- "$CLASH_PROFILES_DIR"
profile="$CLASH_PROFILES_DIR/example.yaml"
cat >"$profile" <<'EOF'
proxies:
  - name: example-node
    type: http
    server: 127.0.0.1
    port: 18082
proxy-groups:
  - name: example-group
    type: select
    proxies: [example-node]
rules:
  - MATCH,example-group
EOF
PROFILE_PATH=$profile "$TEST_YQ" -i '.profiles = [{"name": "example", "path": strenv(PROFILE_PATH), "url": "file://example"}]' "$CLASH_PROFILES_META"

# 原主配置不存在时，订阅应用失败也不能遗留主配置或破坏直连运行配置。
"$TEST_YQ" -i '.mode = "invalid"' "$CLASH_CONFIG_MIXIN"
if _sub_use_locked example >"$WORK_DIR/result" 2>&1; then
    fail 'subscription with an invalid Mixin was accepted'
fi
[ ! -e "$CLASH_CONFIG_BASE" ] || fail 'failed subscription created a base configuration'
cmp -s -- "$WORK_DIR/direct.before" "$CLASH_CONFIG_RUNTIME" || fail 'failed subscription replaced direct runtime'
[ -z "$("$TEST_YQ" '.use // ""' "$CLASH_PROFILES_META")" ] || fail 'failed subscription was selected'
cp -- "$REPO_DIR/resources/mixin.yaml.example" "$CLASH_CONFIG_MIXIN"

# 写入主配置失败时不能把直连回退当作订阅应用成功。
(
    cat() {
        [ "$*" != "$profile" ] || return 1
        command cat "$@"
    }
    if _sub_use_locked example >"$WORK_DIR/result" 2>&1; then
        fail 'subscription write failure was reported as success'
    fi
)
[ ! -e "$CLASH_CONFIG_BASE" ] || fail 'subscription write failure left a base configuration'
cmp -s -- "$WORK_DIR/direct.before" "$CLASH_CONFIG_RUNTIME" || fail 'subscription write failure replaced direct runtime'
[ -z "$("$TEST_YQ" '.use // ""' "$CLASH_PROFILES_META")" ] || fail 'unwritten subscription was selected'
_sub_use_locked example >"$WORK_DIR/result" 2>&1 || { cat "$WORK_DIR/result" >&2; fail 'valid subscription could not replace direct mode'; }
assert_runtime '.mode != "direct" and .proxies[0].name == "example-node"' 'subscription inherited the fallback direct mode'
[ "$("$TEST_YQ" '.use' "$CLASH_PROFILES_META")" = example ] || fail 'valid subscription was not selected'
cmp -s -- "$profile" "$CLASH_CONFIG_BASE" || fail 'valid subscription was not installed as the base'
cp -- "$CLASH_CONFIG_RUNTIME" "$WORK_DIR/runtime.before"
cp -- "$CLASH_CONFIG_MIXIN" "$WORK_DIR/mixin.before"

# 有已选订阅时丢失主配置、无效配置和错误元数据都不能悄悄变为直连。
rm -- "$CLASH_CONFIG_BASE"
assert_preserved 'selected subscription with a missing base'
: >"$CLASH_CONFIG_BASE"
assert_preserved 'selected subscription with an empty base'
printf '{}\n' >"$CLASH_CONFIG_BASE"
assert_preserved 'base without proxy nodes'
cp -- "$profile" "$CLASH_CONFIG_BASE"
"$TEST_YQ" -i '.mode = "invalid"' "$CLASH_CONFIG_BASE"
assert_preserved 'base rejected by the kernel'
rm -- "$CLASH_CONFIG_BASE"
for metadata in 'use: [' '[example]' 'use: {unexpected: object}'; do
    printf '%s\n' "$metadata" >"$CLASH_PROFILES_META"
    assert_preserved 'invalid subscription metadata'
done

# 合并器报错或内核拒绝合并结果时，原有效 runtime 完整保留。
cp -- "$WORK_DIR/metadata.before" "$CLASH_PROFILES_META"
printf 'rules: [\n' >"$CLASH_CONFIG_MIXIN"
assert_preserved 'malformed Mixin'
cp -- "$WORK_DIR/mixin.before" "$CLASH_CONFIG_MIXIN"
"$TEST_YQ" -i '.mode = "invalid"' "$CLASH_CONFIG_MIXIN"
assert_preserved 'merged configuration rejected by the kernel'
cp -- "$WORK_DIR/mixin.before" "$CLASH_CONFIG_MIXIN"
failing_yq() {
    if [ "${1:-}" = eval-all ]; then
        printf 'mode: direct\n'
        return 1
    fi
    "$TEST_YQ" "$@"
}
export BIN_YQ=failing_yq
assert_preserved 'merge command with valid partial output and a failure status'

printf 'no-subscription: ok\n'
