#!/usr/bin/env bash
# 通过真实 Bash/Zsh/Fish 和 PTY 检查订阅输入，下载与落盘使用桩。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/home/scripts" "$WORK_DIR/user"
cp -r "$REPO_DIR/scripts/"{lib,cmd} "$WORK_DIR/home/scripts/"
printf '1\n' >"$WORK_DIR/home/.clashctl-format"
printf 'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\n' >"$WORK_DIR/home/.env"
cat >"$WORK_DIR/home/scripts/cmd/zz-fixture.sh" <<'EOF'
_sub_url_exists() { return 1; }
_sub_has() { [ "$1" = existing ]; }
_sub_current() { printf existing; }
_sub_get() { printf 'https://example.invalid/sub?token=a&b=2%%20x'; }
_sub_download() {
    printf '%s' "$1" >"$CLASHCTL_HOME/received"
    printf '%s\n' "$2" "${CLASHCTL_SUB_TIMEOUT:-}" "${CLASHCTL_SUB_UA:-}" >"$CLASHCTL_HOME/options"
    _SUB_DL_FILE=/dev/null
    FETCH_USERINFO='' FETCH_FILENAME=''
}
_with_profiles_lock() { printf '%s' "$3" >"$CLASHCTL_HOME/saved"; }
EOF

TEST_WORK="$WORK_DIR" python3 - <<'PY'
import errno
import os
import pathlib
import pty
import select
import signal
import subprocess
import time

work = pathlib.Path(os.environ["TEST_WORK"])
home = work / "home"
env = {"PATH": os.environ["PATH"], "HOME": str(work / "user"),
       "CLASHCTL_HOME": str(home), "TERM": "xterm-256color", "LC_ALL": "C.UTF-8",
       "INPUTRC": "/dev/null", "CI": "1"}
prompt = "请输入要添加的订阅链接：".encode()
commands = {
    "bash": ["bash", "--noprofile", "--norc", "-c",
             '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl sub "$@"', "sub-input"],
    "zsh": ["zsh", "-f", "-c",
            '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl sub "$@"', "sub-input"],
    "fish": ["fish", "--no-config", "-c",
             'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; clashctl sub $argv', "--"],
}

def terminal(command, data):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(command[0], command, env)
    output, sent, status = b"", False, None
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                output += chunk
                if not sent and prompt in output:
                    os.write(fd, data)
                    sent = True
            child, child_status = os.waitpid(pid, os.WNOHANG)
            if child:
                status = child_status
                break
        while status is None and time.monotonic() < deadline:
            child, child_status = os.waitpid(pid, os.WNOHANG)
            if child:
                status = child_status
                break
            time.sleep(0.01)
        assert status is not None, "input timed out: " + repr(output)
        assert sent, "subscription prompt missing: " + repr(output)
        return os.waitstatus_to_exitcode(status), output
    finally:
        if status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)

failures, checks = [], 0
def check(shell, name, data=b"", expected=None, tty=True, args=(), subcommand="add", options=None, error=None):
    global checks
    for file in (home / "received", home / "saved", home / "options"):
        file.unlink(missing_ok=True)
    command = commands[shell] + [subcommand] + list(args)
    try:
        if tty:
            rc, output = terminal(command, data)
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
            assert prompt not in output, "explicit argument prompted for input"
        if options is not None:
            assert (home / "options").read_text().splitlines() == list(options), (home / "options").read_text()
        if error is not None:
            assert error.encode() in output, output
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

# 同一组选项必须在两个命令及各 Shell 中保持一致；失败不能开始下载。
for shell in commands:
    for subcommand, target in (("add", url.decode()), ("update", "existing")):
        for flags, values in (
            (("--raw", "--raw", "-t", "7", "--ua", "Agent / 中文"), ("raw", "7", "Agent / 中文")),
            (("--convert", "--timeout=9", "--ua=Other Agent"), ("convert", "9", "Other Agent")),
        ):
            check(shell, f"{subcommand} download options", expected=url, tty=False,
                  args=flags + (target,), subcommand=subcommand, options=values)
        for flags, error in (
            (("--raw", "--convert"), "互斥"),
            (("--convert", "--raw"), "互斥"),
            (("--ua",), "UA 参数"),
            (("--ua=",), "UA 参数"),
            (("--timeout",), "超时参数"),
            ((("--all",) if subcommand == "add" else ("--name",)), "未知选项"),
        ):
            check(shell, f"{subcommand} rejected {flags}", tty=False,
                  args=flags, subcommand=subcommand, error=error)

assert not failures, "\n".join(failures)
print(f"PASS: subscription input ({checks} checks)")
PY
