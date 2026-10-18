#!/usr/bin/env bash
# 用真实 Zsh 检查 node/sub；仅替换 API、yq 数据读取和订阅落盘。
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
command -v zsh >/dev/null || { printf 'zsh is required\n' >&2; exit 1; }
make_fake_home "$WORK_DIR/home"
mkdir -p "$WORK_DIR/home/data/profiles" "$WORK_DIR/home/resources" "$WORK_DIR/bin"
printf 'fixture subscription\n' >"$WORK_DIR/home/data/saved.yaml"

# 保留真实数组、URL 编码、curl 封装、编号/fzf 选择、临时文件和锁操作。
cat >"$WORK_DIR/home/scripts/cmd/zz-fixture.sh" <<'EOF'
service_is_active() { [ "${NO_SERVICE:-0}" = 0 ]; }
_node_api_base() { printf 'http://fixture.invalid'; }
_get_secret() { :; }
_sub_has() { case $1 in '订阅 A' | '订阅 B') return 0 ;; *) return 1 ;; esac; }
_sub_url_exists() { return 1; }
_sub_current() { printf '订阅 A'; }
_sub_rows() { printf '订阅 A\thttps://fixture.invalid/a\t2026-10-13\t\n订阅 B\thttps://fixture.invalid/b\t2026-10-13\t\n'; }
_sub_get() {
    case $2 in
    url) printf 'https://fixture.invalid/sub?token=a&b=2' ;;
    path) printf '%s/data/saved.yaml' "$CLASHCTL_HOME" ;;
    esac
}
_download_config() { printf 'downloaded subscription\n' >"$1"; }
_sub_update_locked() {
    date +%s >"$CLASH_DATA_DIR/date" || return
    mv -- "$4" "$3" || return
    printf '%s' "$1" >"$CLASH_DATA_DIR/updated"
}
_sub_use_locked() {
    [ "${FAIL_USE:-0}" = 0 ] || return 23
    printf '%s' "$1" >"$CLASH_DATA_DIR/used"
}
EOF

cat >"$WORK_DIR/bin/fixture" <<'PY'
#!/usr/bin/env python3
import json
import os
import pathlib
import sys
from urllib.parse import unquote, urlparse

kind = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
group = {"type": "Selector", "now": "DIRECT", "all": ["节点 A 🇭🇰", "DIRECT"]}
proxies = {"策略 A 🚀": group, "策略 B": group, "节点 A 🇭🇰": {"type": "Shadowsocks"}, "DIRECT": {"type": "Direct"}}
if kind == "curl":
    url = next(x for x in args if x.startswith("http://fixture.invalid"))
    route = unquote(urlparse(url).path)
    if args[args.index("-X") + 1] == "PUT":
        body = json.loads(args[args.index("--data-raw") + 1])
        pathlib.Path(os.environ["CLASHCTL_HOME"], "data", "selected").write_text(json.dumps([route, body["name"]], ensure_ascii=False))
        print("204", end="")
    else:
        data = {"delay": 31} if route.startswith("/proxies/") and "/delay" in route else {"节点 A 🇭🇰": 31, "DIRECT": 5} if "/delay" in route else {"proxies": proxies} if route == "/proxies" else proxies[route.removeprefix("/proxies/")]
        print(json.dumps(data), end="")
        if "-w" in args:
            print("\n200", end="")
elif kind == "fzf":
    rows = sys.stdin.read().splitlines()
    if os.environ.get("CANCEL_FZF"):
        sys.exit(130)
    print(rows[0])
elif kind == "yq":
    if args == ["--version"]:
        print("yq (https://github.com/mikefarah/yq/) version v4.53.3")
    elif "-n" in args:
        print(json.dumps({"name": os.environ["NODE"]}))
    elif "-i" in args and "PROFILE_PATH" in os.environ:
        pathlib.Path(os.environ["CLASHCTL_HOME"], "data", "added").write_text(os.environ["PROFILE_NAME"] + "\n" + os.environ["PROFILE_URL"] + "\n")
    else:
        expression = args[-1]
        data = json.load(sys.stdin)
        if "NODE_NAME" in expression:
            item = data["proxies"].get(os.environ["NODE_NAME"])
            print(f'{str(item is not None).lower()}\t{str(item is not None and "all" in item).lower()}')
        elif "to_entries" in expression:
            for name, value in data.get("proxies", data).items():
                if "select(.value.all != null)" in expression and "all" in value:
                    print(f'{name}\t{value["type"]}\t{value["now"]}')
                elif "select(.value.all == null)" in expression and "all" not in value:
                    print(f'{name}\t{value["type"]}')
                elif "select(" not in expression:
                    print(f'{name}\t{value}')
        elif ".all" in expression:
            print("\n".join(data["all"]))
        elif ".now" in expression:
            print(data["now"])
        elif ".delay" in expression:
            print(data["delay"])
        else:
            raise RuntimeError(f"Unexpected yq query: {expression}")
PY
chmod +x "$WORK_DIR/bin/fixture"
for tool in curl yq fzf; do ln -s fixture "$WORK_DIR/bin/$tool"; done

PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$WORK_DIR/home" python3 - <<'PY'
import json
import os
import pathlib
import pty
import subprocess

home = pathlib.Path(os.environ["CLASHCTL_HOME"])
bootstrap = '''
    original_path=$PATH
    original_options=$(setopt)
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
    [ "$BIN_YQ" = "${PATH%%:*}/yq" ] || { print -u2 "system yq not detected"; exit 1; }
'''
finish = '''
    result=$?
    [ "$PATH" = "$original_path" ] || exit 91
    [ "$(setopt)" = "$original_options" ] || exit 92
    exit "$result"
'''
count = 0
def run(command, expected=0, contains="", input_text="", tty=False, extra=None, prefix=""):
    global count
    env = dict(os.environ, **(extra or {}))
    master = slave = None
    if tty:
        master, slave = pty.openpty()
    try:
        result = subprocess.run(["zsh", "-f", "-c", prefix + bootstrap + command + finish],
                                env=env, stdin=slave if tty else None,
                                input=None if tty else input_text, text=True,
                                capture_output=True, timeout=20)
    finally:
        if tty:
            os.close(master)
            os.close(slave)
    output = result.stdout + result.stderr
    assert result.returncode == expected, (command, result.returncode, output)
    assert contains in output, (command, output)
    for error in ["bad substitution", "read-only variable", "command not found", "key="]:
        assert error not in output, (command, output)
    count += 1

for prefix in ["", "setopt KSH_ARRAYS\n"]:
    run("clashctl node ls\n", contains="策略 A 🚀", prefix=prefix)
    run("clashnode ls '策略 A 🚀'\n", contains="节点 A 🇭🇰", prefix=prefix)
    run("clashctl sub ls\n", contains="订阅 B", prefix=prefix)
run("clashctl node use '策略 A 🚀' '节点 A 🇭🇰'\n")
assert json.loads((home / "data/selected").read_text()) == ["/proxies/策略 A 🚀", "节点 A 🇭🇰"]
run("clashctl node delay '策略 A 🚀'\n", contains="31ms")
run("clashctl node use -d\n", input_text="1\n1\n")
run("clashnode use -d\n", tty=True)
assert json.loads((home / "data/selected").read_text()) == ["/proxies/策略 A 🚀", "节点 A 🇭🇰"]
run("clashctl node delay -p\n", tty=True, contains="31ms")
run("clashctl node delay -p\n", tty=True, extra={"CANCEL_FZF": "1"}, expected=1)
run("clashctl node use -d\n", tty=True, prefix="setopt KSH_ARRAYS\n")
run("clashctl node use -d\n", input_text="1\n1\n", prefix="setopt KSH_ARRAYS\n")
assert json.loads((home / "data/selected").read_text()) == ["/proxies/策略 A 🚀", "节点 A 🇭🇰"]
run("clashctl node use\n", tty=True, extra={"CANCEL_FZF": "1"}, expected=1)
run("clashctl sub add --name '新订阅 🚀' 'https://fixture.invalid/new?token=a&b=2'\n")
assert (home / "data/added").read_text() == "新订阅 🚀\nhttps://fixture.invalid/new?token=a&b=2\n"
run("clashsub add --name '添加并启用' --use 'https://fixture.invalid/use'\n")
assert (home / "data/used").read_text() == "添加并启用"
run("clashsub add --name '启用失败' --use 'https://fixture.invalid/fail'\n", extra={"FAIL_USE": "1"}, expected=23)
run("clashctl sub update '订阅 A'\n")
assert (home / "data/updated").read_text() == "订阅 A"
assert (home / "data/saved.yaml").read_text() == "downloaded subscription\n"
assert not list((home / "resources").glob(".fetch.*"))
run("clashsub use\n", input_text="2\n")
assert (home / "data/used").read_text() == "订阅 B"
run("clashctl sub use\n", tty=True)
assert (home / "data/used").read_text() == "订阅 A"
run("clashsub use\n", tty=True, extra={"CANCEL_FZF": "1"}, expected=1)
run("clashsub use '订阅 A'\n", extra={"FAIL_USE": "1"}, expected=23)
run("clashnode use --invalid\n", expected=1, contains="未知选项")
run("clashsub add --invalid\n", expected=1, contains="未知选项")
run("clashctl node ls\n", extra={"NO_SERVICE": "1"}, expected=1, contains="未运行")
run("export ZSH_VERSION; clashnode ls\n", contains="策略 B")
for command in ["node", "sub"]:
    run(f"PATH=/nonexistent; clashctl {command} ls; result=$?; PATH=$original_path; (exit $result)\n",
        expected=127, contains="未找到 Bash，请安装后重试")
    run(f"clashctl {command} --help\n", contains=f"clashctl {command}")

# 所有依赖 Bash 语义的子命令在非 Bash 解释器下都必须转发到 Bash 子进程；
# PATH 中没有 bash 时统一报 127，而不是在当前解释器里误执行。
for command in ["start", "stop", "status", "ui", "log", "mixin", "secret", "upgrade", "tun"]:
    run(f"PATH=/nonexistent; clashctl {command}; result=$?; PATH=$original_path; (exit $result)\n",
        expected=127, contains="未找到 Bash，请安装后重试")
# 直接调用 clash* 函数（fish 包装器与用户习惯）同样要转发。
for function in ["clashstart", "clashstop", "clashstatus", "clashui", "clashmixin",
                 "clashsecret", "clashupgrade", "clashtun"]:
    run(f"PATH=/nonexistent; {function}; result=$?; PATH=$original_path; (exit $result)\n",
        expected=127, contains="未找到 Bash，请安装后重试")
# 必须留在当前 Shell 的命令：off 只清理本 Shell 变量，PATH 清空也应成功。
run("PATH=/nonexistent; clashctl off; result=$?; PATH=$original_path; (exit $result)\n",
    contains="当前终端代理已关闭")
run("clashctl help\n", contains="clashctl COMMAND")
run("clashctl version\n", contains="clashctl")
print(f"zsh-commands: {count} checks passed")
PY
