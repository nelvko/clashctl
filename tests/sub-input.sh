#!/usr/bin/env bash
# 通过真实 Bash/Zsh/Fish 和 PTY 检查订阅输入，下载与落盘使用桩。
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
make_fake_home "$WORK_DIR/home"
mkdir -p "$WORK_DIR/user"
cat >"$WORK_DIR/home/scripts/cmd/zz-fixture.sh" <<'EOF'
_sub_url_exists() { return 1; }
_sub_download() {
    printf '%s' "$1" >"$CLASHCTL_HOME/received"
    _SUB_DL_FILE=/dev/null
    FETCH_USERINFO='' FETCH_FILENAME=''
}
_with_profiles_lock() { printf '%s' "$3" >"$CLASHCTL_HOME/saved"; }
EOF

TEST_WORK="$WORK_DIR" python3 -B - "$TEST_DIR/lib" <<'PY'
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, sys.argv[1])
from terminal import run

work = pathlib.Path(os.environ["TEST_WORK"])
home = work / "home"
env = {"PATH": os.environ["PATH"], "HOME": str(work / "user"),
       "CLASHCTL_HOME": str(home), "TERM": "xterm-256color", "LC_ALL": "C.UTF-8",
       "INPUTRC": "/dev/null", "CI": "1"}
prompt = "请输入要添加的订阅链接：".encode()
commands = {
    "bash": ["bash", "--noprofile", "--norc", "-c",
             '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl sub add "$@"', "sub-input"],
    "zsh": ["zsh", "-f", "-c",
            '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl sub add "$@"', "sub-input"],
    "fish": ["fish", "--no-config", "-c",
             'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; clashctl sub add $argv', "--"],
}

failures, checks = [], 0
def check(shell, name, data=b"", expected=None, tty=True, args=()):
    global checks
    for file in (home / "received", home / "saved"):
        file.unlink(missing_ok=True)
    command = commands[shell] + list(args)
    try:
        if tty:
            rc, output = run(command, env=env, replies=[(prompt, data)])
            assert prompt in output, "subscription prompt missing: " + repr(output)
        else:
            result = subprocess.run(command, env=env, input=data, capture_output=True, timeout=10)
            rc, output = result.returncode, result.stdout + result.stderr
        if expected is None:
            assert rc != 0, ("cancelled/empty input succeeded", output)
            assert not (home / "received").exists(), "cancelled/empty input reached download"
        else:
            assert rc == 0, (rc, output)
            assert (home / "received").read_bytes() == expected, (home / "received").read_bytes()
            assert (home / "saved").read_bytes() == expected, (home / "saved").read_bytes()
        if args:
            assert prompt not in output, "explicit URL prompted for input"
        checks += 1
        print(f"PASS: {shell} {name}")
    except (AssertionError, subprocess.TimeoutExpired) as exc:
        failures.append(f"{shell} {name}: {exc}")
        print("FAIL: " + failures[-1])

url = b"https://example.invalid/sub?token=a&b=2%20x"
for shell in commands:
    check(shell, "paste", b"\x1b[200~" + url + b"\x1b[201~\n", url)
    check(shell, "left arrow", b"https://example.invalid/sb\x1b[Du\n", b"https://example.invalid/sub")
    check(shell, "right arrow/backspace", b"https://example.invalid/sb\x1b[D\x1b[C\x7fub\n",
          b"https://example.invalid/sub")
    unicode_url = "https://example.invalid/订阅?name=测试&key=a\\b".encode()
    check(shell, "UTF-8/backslash", b"\x1b[200~" + unicode_url + b"\x1b[201~\n", unicode_url)
    check(shell, "empty", b"\n")
    check(shell, "EOF", b"\x04")
    check(shell, "cancel", b"\x03")
    check(shell, "pipe paste", b"\x1b[200~" + url + b"\x1b[201~\n", url, tty=False)
    check(shell, "pipe literal URL", unicode_url + b"\n", unicode_url, tty=False)
    check(shell, "pipe final line without newline", url, url, tty=False)
    check(shell, "explicit URL", expected=url, tty=False, args=(url.decode(),))

assert not failures, "\n".join(failures)
print(f"PASS: subscription input ({checks} checks)")
PY
