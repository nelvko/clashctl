#!/usr/bin/env bash
# 真实 Bash/Zsh/Fish 入口与伪终端；仅读取隔离配置，不接触宿主服务。
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
for tool in bash zsh fish python3; do
    command -v "$tool" >/dev/null || { printf '%s is required\n' "$tool" >&2; exit 1; }
done
export CLASHCTL_HOME="$WORK_DIR/home"
make_fake_home "$CLASHCTL_HOME"
mkdir -p "$WORK_DIR/user"

cat >"$CLASHCTL_HOME/scripts/lib/zz-fixture.sh" <<'EOF'
detect_service_manager() {
    service_manager=${STATUS_MANAGER:-nohup}
    service_log_path="$CLASHCTL_HOME/data/mihomo.log"
}
service_state() {
    printf 'state\n' >>"$CLASHCTL_HOME/calls"
    case ${STATUS_STATE:-running} in
    running | stopped | unknown) printf '%s\n' "${STATUS_STATE:-running}" ;;
    starting | stopping | failed) printf '%s\n' "$STATUS_STATE" ;;
    error) printf 'private native error\n' >&2; return 7 ;;
    *) return 8 ;;
    esac
}
service_main_pid() {
    printf 'pid\n' >>"$CLASHCTL_HOME/calls"
    [ "${STATUS_STATE:-running}" = running ] && [ "${STATUS_PID:-24680}" != unavailable ] || return 1
    printf '%s\n' "${STATUS_PID:-24680}"
}
service_uptime() {
    printf 'uptime\n' >>"$CLASHCTL_HOME/calls"
    [ "${STATUS_UPTIME:-90061}" != unavailable ] || return 1
    printf '%s\n' "${STATUS_UPTIME:-90061}"
}
service_is_active() { [ "${STATUS_STATE:-running}" = running ]; }
_is_root() { [ "${STATUS_ROOT:-1}" = 1 ]; }
_tun_pid_owns_device() {
    printf 'tun-owner\n' >>"$CLASHCTL_HOME/calls"
    case ${STATUS_TUN_OWNER:-owned} in
    owned) return 0 ;;
    foreign) return 1 ;;
    unavailable) return 2 ;;
    esac
}
_tun_api_state() {
    printf 'tun-api\n' >>"$CLASHCTL_HOME/calls"
    case ${STATUS_TUN_API:-disabled} in
    enabled) printf 'true\tct-test\n' ;;
    disabled) printf 'false\t\n' ;;
    unavailable) return 1 ;;
    esac
}
ip() {
    printf 'link\n' >>"$CLASHCTL_HOME/calls"
    case ${STATUS_TUN_LINK:-absent} in
    up) printf '7: ct-test: <POINTOPOINT,UP,LOWER_UP> state UNKNOWN\n' ;;
    down) printf '7: ct-test: <POINTOPOINT> state DOWN\n' ;;
    no-carrier) printf '7: ct-test: <NO-CARRIER,POINTOPOINT,UP> state DOWN\n' ;;
    absent) return 1 ;;
    esac
}
_get_local_ip() { printf '192.0.2.10\n'; }
# 查询不能绕到启动、配置合并或端口重分配路径。
service_start() { printf 'MUTATION\n' >>"$CLASHCTL_HOME/calls"; return 91; }
service_stop() { printf 'MUTATION\n' >>"$CLASHCTL_HOME/calls"; return 91; }
_merge_config() { printf 'MUTATION\n' >>"$CLASHCTL_HOME/calls"; return 91; }
_detect_proxy_port() { printf 'MUTATION\n' >>"$CLASHCTL_HOME/calls"; return 91; }
_detect_ext_addr() { printf 'MUTATION\n' >>"$CLASHCTL_HOME/calls"; return 91; }
_ci_provision() { printf 'MUTATION\n' >>"$CLASHCTL_HOME/calls"; return 91; }
curl() { printf 'MUTATION\n' >>"$CLASHCTL_HOME/calls"; return 91; }
EOF

cat >"$CLASHCTL_HOME/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ne 1 ] || [ "$1" != -v ]; then
    printf 'MUTATION\n' >>"$CLASHCTL_HOME/calls"
    exit 91
fi
printf 'version\n' >>"$CLASHCTL_HOME/calls"
case ${STATUS_VERSION:-stable} in
stable) printf 'Mihomo Meta v1.19.32 linux amd64 with go1.26.8\nUse tags: with_gvisor\n' ;;
nightly) printf 'Mihomo Meta alpha-abcdef linux amd64 with go1.26.8\n' ;;
invalid) printf 'private unrecognized version\n' ;;
error) printf 'private version error\n' >&2; exit 23 ;;
esac
EOF
chmod +x "$CLASHCTL_HOME/bin/mihomo"

# JSON 是合法 YAML；这个小桩只替换 yq 的字段读取，避免 CI 下载依赖。
cat >"$CLASHCTL_HOME/bin/yq" <<'PY'
#!/usr/bin/env python3
import base64
import json
import pathlib
import re
import sys

args = sys.argv[1:]
if '-i' in args or '--inplace' in args:
    pathlib.Path(__file__).parents[1].joinpath('calls').open('a').write('MUTATION\n')
    sys.exit(91)
if args == ['--version']:
    print('yq (https://github.com/mikefarah/yq/) version v4.53.3')
    sys.exit(0)
try:
    data = json.loads(pathlib.Path(args[-1]).read_text())
    if not isinstance(data, dict):
        raise ValueError('not a mapping')
except (OSError, ValueError):
    print('private yq parse error: fixture-secret', file=sys.stderr)
    sys.exit(1)
query = next(arg for arg in args[:-1] if not arg.startswith('-'))
def value(match):
    key, index, fallback = match.groups()
    result = data
    for part in key.split('.'):
        result = result.get(part) if isinstance(result, dict) else None
    if index is not None:
        result = result[int(index)] if isinstance(result, list) and len(result) > int(index) else None
    if result is None or result is False:
        result = json.loads(fallback)
    if result is True:
        result = 'true'
    elif result is False:
        result = 'false'
    else:
        result = str(result)
    if re.match(r'\s*\|\s*@base64\b', query[match.end():]):
        result = base64.b64encode(result.encode()).decode()
    return result
fields = list(re.finditer(r'\.([\w.-]+)(?:\[(\d+)\])?\s*//\s*("[^"]*"|false|true|[0-9]+)', query))
if fields:
    separator = '\t' if '@tsv' in query else '|'
    if 'join(' in query:
        separator = json.loads(re.search(r'join\(("[^"]*")\)', query).group(1))
    print(separator.join(value(match) for match in fields))
else:
    raise RuntimeError('Unsupported fixture yq query: ' + query)
PY
chmod +x "$CLASHCTL_HOME/bin/yq"

STATUS_TEST_WORK="$WORK_DIR" python3 - <<'PY'
import errno
import fcntl
import hashlib
import json
import os
import pathlib
import pty
import re
import select
import struct
import subprocess
import termios
import time
import unicodedata
from urllib.parse import quote

work = pathlib.Path(os.environ['STATUS_TEST_WORK'])
home = work / 'home'
runtime = home / 'data/runtime.yaml'
calls_file = home / 'calls'
(home / 'data/config.yaml').write_text('{"proxies": []}')
(home / 'data/profiles.yaml').write_text(json.dumps({
    'use': '订阅 A',
    'profiles': [{'name': '订阅 A', 'url': 'https://subscription.invalid/private-subscription-token'}],
}))
env_base = {
    'PATH': os.environ['PATH'], 'HOME': str(work / 'user'),
    'CLASHCTL_HOME': str(home), 'TERM': 'xterm-256color',
    'CLASHCTL_COLOR': 'auto', 'LC_ALL': 'C.UTF-8',
}
bash_probe = r'''
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 90
case ${STATUS_PROXY_CASE:-none} in
    lower) http_proxy='http://terminal-user:terminal-pass@proxy.example:8123' ;;
    upper) HTTPS_PROXY='http://terminal-user:terminal-pass@proxy.example:8123'; export HTTPS_PROXY ;;
    socks) all_proxy='socks5h://terminal-user:terminal-pass@proxy.example:8124' ;;
    http-upper) HTTP_PROXY='http://terminal-user:terminal-pass@proxy.example:8123' ;;
    https-lower) https_proxy='http://terminal-user:terminal-pass@proxy.example:8123' ;;
    socks-upper) ALL_PROXY='socks5h://terminal-user:terminal-pass@proxy.example:8124' ;;
    bypass) no_proxy=localhost; export no_proxy ;;
    empty) http_proxy=''; export http_proxy ;;
esac
if [ -n "${STATUS_UNEXPORTED_PROXY:-}" ]; then
    typeset +x "$STATUS_UNEXPORTED_PROXY"
fi
if [ -n "${STATUS_COLUMNS:-}" ]; then
    COLUMNS=$STATUS_COLUMNS
fi
if [ -n "${ZSH_VERSION:-}" ]; then
    before_parameters=$(typeset -p http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY COLUMNS PATH 2>/dev/null)
    before_environment=$(env | LC_ALL=C sort)
    before_options=$(setopt)
    if [ -n "${STATUS_UNEXPORTED_PROXY:-}" ]; then
        case ${parameters[$STATUS_UNEXPORTED_PROXY]} in *export*) exit 95 ;; esac
    fi
    if [ -n "${STATUS_COLUMNS:-}" ]; then
        case ${parameters[COLUMNS]} in *export*) exit 96 ;; esac
    fi
fi
before_proxy="${http_proxy-unset}|${HTTP_PROXY-unset}|${https_proxy-unset}|${HTTPS_PROXY-unset}|${all_proxy-unset}|${ALL_PROXY-unset}|${no_proxy-unset}"
case ${STATUS_ENTRY:-dispatch} in
direct) clashstatus "$@" ;;
dispatch) clashctl status "$@" ;;
esac
probe_rc=$?
after_proxy="${http_proxy-unset}|${HTTP_PROXY-unset}|${https_proxy-unset}|${HTTPS_PROXY-unset}|${all_proxy-unset}|${ALL_PROXY-unset}|${no_proxy-unset}"
[ "$before_proxy" = "$after_proxy" ] || exit 92
if [ -n "${ZSH_VERSION:-}" ]; then
    after_parameters=$(typeset -p http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY COLUMNS PATH 2>/dev/null)
    [ "$before_parameters" = "$after_parameters" ] || exit 93
    [ "$before_environment" = "$(env | LC_ALL=C sort)" ] || exit 94
    [ "$before_options" = "$(setopt)" ] || exit 97
fi
exit "$probe_rc"
'''
fish_probe = r'''
source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; or exit 90
switch "$STATUS_PROXY_CASE"
    case lower
        set -gx http_proxy 'http://terminal-user:terminal-pass@proxy.example:8123'
    case upper
        set -gx HTTPS_PROXY 'http://terminal-user:terminal-pass@proxy.example:8123'
    case socks
        set -gx all_proxy 'socks5h://terminal-user:terminal-pass@proxy.example:8124'
    case http-upper
        set -gx HTTP_PROXY 'http://terminal-user:terminal-pass@proxy.example:8123'
    case https-lower
        set -gx https_proxy 'http://terminal-user:terminal-pass@proxy.example:8123'
    case socks-upper
        set -gx ALL_PROXY 'socks5h://terminal-user:terminal-pass@proxy.example:8124'
    case bypass
        set -gx no_proxy localhost
    case empty
        set -gx http_proxy ''
end
set -l before_proxy (env | sort)
clashctl status $argv
set -l probe_rc $status
set -l after_proxy (env | sort)
test "$before_proxy" = "$after_proxy"; or exit 92
exit $probe_rc
'''
count = 0

def configure(**fields):
    runtime.write_text(json.dumps(fields), encoding='utf-8')

def run(shell='bash', args=(), expected=0, extra=None, tty=False, width=100):
    global count
    env = dict(env_base, **(extra or {}))
    command = [shell, *(['--no-config'] if shell == 'fish' else ['-f'] if shell == 'zsh' else ['--noprofile', '--norc']),
               '-c', fish_probe if shell == 'fish' else bash_probe, '--', *args]
    calls_file.write_text('')
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (home / 'data').rglob('*') if p.is_file()}
    if tty:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
        process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, stdout=slave, stderr=subprocess.PIPE)
        os.close(slave)
        chunks = []
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], .1)
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        break
                    if not data:
                        break
                    chunks.append(data)
            else:
                raise AssertionError('status PTY timed out')
            _, stderr = process.communicate(timeout=3)
            stdout = b''.join(chunks).decode().replace('\r\n', '\n')
            stderr = stderr.decode()
            rc = process.returncode
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
    else:
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
        stdout, stderr, rc = result.stdout, result.stderr, result.returncode
    after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (home / 'data').rglob('*') if p.is_file()}
    calls = calls_file.read_text().splitlines()
    label = (shell, args, extra, tty, width)
    assert rc == expected, (label, 'exit', rc, expected, stdout, stderr)
    assert before == after, (label, 'query changed runtime data')
    assert 'MUTATION' not in calls, (label, calls)
    assert '原生状态' not in stdout + stderr, (label, stdout, stderr)
    no_frame(stdout)
    assert '代理地址（运行配置）' not in stdout, (label, 'old address heading', stdout)
    if not args:
        assert 'PID' not in stdout, (label, 'PID in default output', stdout)
    for secret in ('terminal-user', 'terminal-pass', 'ignored-user', 'ignored-pass', 'fixture-secret',
                   'private-subscription-token', 'private version error', 'private unrecognized version'):
        assert secret not in stdout + stderr, (label, 'non-runtime value exposed', stdout, stderr)
    for error in ('bad substitution', 'read-only variable', 'command not found', 'private yq parse error'):
        assert error not in stdout + stderr, (label, error, stdout, stderr)
    count += 1
    return stdout, stderr, calls

def contains(output, *words):
    for word in words:
        assert word in output, ('missing', word, output)

def field(output, label, value):
    assert any(label in line and value in line for line in output.splitlines()), (label, value, output)

ansi = re.compile(r'\x1b\[[0-9;]*m')

def no_frame(output):
    assert not any('\u2500' <= character <= '\u257f' and character != '─' for character in output), ('frame in output', output)

def display_width(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1
               for c in ansi.sub('', text))

def plain(output):
    assert '\x1b[' not in output, ('ANSI in plain output', output)
    no_frame(output)
    assert '─' not in output, ('horizontal rule in plain output', output)
    assert 'clashctl' not in [line.strip() for line in output.splitlines()], ('title in plain output', output)
    assert '内核：' in output and '代理地址' in output, output

def interactive(output, verbose=False, color=True, columns=100):
    no_frame(output)
    lines = ansi.sub('', output).splitlines()
    content = [line for line in lines if line]
    rule_width = min(48, columns - 1)
    assert re.fullmatch(r'── clashctl ─+', content[0]), ('missing ruled title', output)
    assert display_width(content[0]) == rule_width, ('title rule width', columns, output)
    assert content[-1] == '─' * rule_width, ('footer rule width', columns, output)
    assert [line for line in lines if '─' in line] == [content[0], content[-1]], ('unexpected rules', output)
    assert '  代理地址' in lines, ('missing address group', output)
    if color:
        assert '\x1b[1mclashctl\x1b[0m' in output, ('title has no bold style', output)
    else:
        assert '\x1b[' not in output, output
    labels = ['内核', '管理方式', '状态', '运行时长', '已选订阅', '终端代理', 'TUN', 'HTTP(S)', 'SOCKS5']
    if any(line.lstrip().startswith('Web 面板') for line in lines):
        labels.append('Web 面板')
    if verbose:
        labels.extend(['PID', '主配置', '运行配置', '日志'])
    positions = {}
    for label in labels:
        matches = [(index, re.fullmatch(r'  ' + re.escape(label) + r' +(?P<value>\S.*)', line))
                   for index, line in enumerate(lines)]
        matches = [(index, match) for index, match in matches if match]
        assert len(matches) == 1, ('missing aligned field', label, output)
        index, match = matches[0]
        assert display_width(lines[index][:match.start('value')]) == 12, ('misaligned value', label, output)
        positions[label] = index
    first, last = sorted([positions['TUN'], positions['终端代理']])
    assert last == first + 1 and lines[first - 1] == lines[last + 1] == '', ('proxy group', output)
    if verbose:
        assert lines[positions['PID'] - 1] == '', ('verbose group', output)

def colored_value(output, label, value, color):
    pattern = r'  ' + re.escape(label) + r' +\x1b\[' + str(color) + 'm' + re.escape(value) + r'\x1b\[0m'
    assert any(re.fullmatch(pattern, line) for line in output.splitlines()), ('value color', label, value, color, output)

configure(**{'mixed-port': 7890, 'allow-lan': False,
             'authentication': ['runtime-user:runtime-pass', 'ignored-user:ignored-pass']})
for shell in ('bash', 'zsh', 'fish'):
    out, err, calls = run(shell)
    assert not err, (shell, err)
    plain(out)
    for label, value in [('内核', 'mihomo v1.19.32'), ('管理方式', 'nohup'), ('状态', '运行中'),
                         ('已选订阅', '订阅 A'), ('运行时长', '1d 01h 01m 01s'),
                         ('TUN', '关闭'), ('终端代理', '未启用')]:
        field(out, label, value)
    contains(out, 'http://runtime-user:runtime-pass@127.0.0.1:7890',
             'socks5h://runtime-user:runtime-pass@127.0.0.1:7890')
    assert calls.count('state') == 1, calls
    assert calls.count('version') == 1 and calls.count('uptime') == 1, calls
    assert 'Web 面板' not in out and 'PID' not in out, out
    assert str(home / 'data') not in out, out
    for proxy_case in ('lower', 'upper', 'socks', 'http-upper', 'https-lower', 'socks-upper'):
        out, _, _ = run(shell, extra={'STATUS_PROXY_CASE': proxy_case})
        field(out, '终端代理', '已启用')
        contains(out, 'http://runtime-user:runtime-pass@127.0.0.1:7890',
                 'socks5h://runtime-user:runtime-pass@127.0.0.1:7890')
    for proxy_case in ('empty', 'bypass'):
        out, _, _ = run(shell, extra={'STATUS_PROXY_CASE': proxy_case})
        field(out, '终端代理', '未启用')
    out, _, calls = run(shell, expected=1, extra={'STATUS_STATE': 'stopped'})
    field(out, '状态', '未运行')
    field(out, '运行时长', '—')
    field(out, 'TUN', '关闭')
    assert '24680' not in out, out
    out, _, _ = run(shell, expected=2, extra={'STATUS_STATE': 'error'})
    assert '检测失败' in out, out
    field(out, '运行时长', '—')
    field(out, 'TUN', '无法检测')
    for state, label in [('starting', '启动中'), ('stopping', '停止中'), ('failed', '异常停止')]:
        out, _, _ = run(shell, expected=1, extra={'STATUS_STATE': state})
        field(out, '状态', label)
    out, _, _ = run(shell, extra={'STATUS_PID': 'unavailable'})
    assert '24680' not in out, out
    field(out, '运行时长', '无法读取')
    for flag in ('-h', '--help'):
        out, err, calls = run(shell, args=(flag,))
        contains(out, 'status', '--verbose')
        assert not err and not calls, (shell, flag, err, calls)
    for args in (('--bad',), ('unexpected',), ('--help', '--verbose'), ('--verbose', '--verbose'),
                 ('--verbose', 'unexpected'), ('--help', '--help')):
        _, _, calls = run(shell, args=args, expected=1)
        assert not calls, (shell, args, calls)
    for state, expected in (('running', 0), ('stopped', 1), ('unknown', 2), ('error', 2)):
        for args in ((), ('--verbose',)):
            out, err, calls = run(shell, args=args, expected=expected,
                                  extra={'STATUS_STATE': state})
            assert not err, (shell, state, args, err)
            plain(out)
            field(out, '已选订阅', '订阅 A')
            assert '当前订阅' not in out, out
            if args:
                for label, value in [('PID', '24680' if state == 'running' else '—'),
                                     ('主配置', str(home / 'data/config.yaml')),
                                     ('运行配置', str(runtime)), ('日志', str(home / 'data/mihomo.log'))]:
                    field(out, label, value)
            else:
                assert str(home / 'data') not in out, out

# URL 中完整展示首组运行配置认证，保留用户名/密码分隔符并编码保留字符。
for shell in ('bash', 'zsh', 'fish'):
    username, password = 'user@/名?#%', 'p@ss:/#密 码%'
    configure(**{'mixed-port': 7890, 'authentication': [f'{username}:{password}']})
    userinfo = f'{quote(username, safe="")}:{quote(password, safe="")}@'
    for tty in (False, True):
        out, _, _ = run(shell, tty=tty, width=220)
        contains(out, f'http://{userinfo}127.0.0.1:7890', f'socks5h://{userinfo}127.0.0.1:7890')
        assert username not in out and password not in out, out
        if tty:
            interactive(out)

# 专用端口优先；缺少一类监听端口时不捏造默认端口。
for shell in ('bash', 'zsh', 'fish'):
    configure(**{'mixed-port': 7890, 'port': 7891, 'socks-port': 7892, 'allow-lan': True,
                 'bind-address': '2001:db8::10'})
    out, _, _ = run(shell)
    contains(out, 'http://[2001:db8::10]:7891', 'socks5h://[2001:db8::10]:7892')
    assert ':7890' not in out, out
    configure(**{'port': 8888, 'allow-lan': False})
    out, _, _ = run(shell)
    contains(out, 'http://127.0.0.1:8888')
    assert 'socks5h://' not in out, out
    configure(**{'mixed-port': 7890, 'allow-lan': False, 'bind-address': ''})
    out, _, _ = run(shell)
    contains(out, 'http://127.0.0.1:7890', 'socks5h://127.0.0.1:7890')
    configure(**{'mixed-port': 0, 'port': 0, 'socks-port': 0})
    out, _, _ = run(shell)
    assert 'http://' not in out and 'socks5h://' not in out, out
    runtime.unlink()
    out, err, _ = run(shell)
    assert 'http://' not in out and 'socks5h://' not in out and not err, (out, err)
    contains(out, '未配置')
    runtime.write_text('{ invalid fixture-secret')
    out, err, _ = run(shell)
    assert 'http://' not in out and 'socks5h://' not in out and not err, (out, err)
    contains(out, '无法读取')

# 真正将 stdout 接到 PTY，验证 Zsh/Fish 桥接保留终端能力、宽度和颜色策略。
configure(**{'mixed-port': 7890, 'allow-lan': False})
for shell in ('bash', 'zsh', 'fish'):
    out, err, _ = run(shell, tty=True)
    assert not err, (shell, err)
    interactive(out)
    contains(out, 'http://127.0.0.1:7890')
    colored_value(out, '状态', '运行中', 32)
    colored_value(out, '终端代理', '未启用', 90)
    colored_value(out, 'TUN', '关闭', 90)
    uncolored_layout = ansi.sub('', out)
    out, _, _ = run(shell, tty=True, extra={'NO_COLOR': '', 'CLASHCTL_COLOR': 'always'})
    interactive(out, color=False)
    assert out == uncolored_layout, ('NO_COLOR changed layout', shell, out)
    for width in (28, 39):
        out, _, _ = run(shell, tty=True, width=width)
        plain(out)
    out, _, _ = run(shell, tty=True, width=40)
    interactive(out, columns=40)
    out, _, _ = run(shell, args=('--verbose',), tty=True)
    interactive(out, verbose=True)
    field(out, 'PID', '24680')
    uncolored_layout = ansi.sub('', out)
    out, _, _ = run(shell, args=('--verbose',), tty=True, extra={'NO_COLOR': '', 'CLASHCTL_COLOR': 'always'})
    interactive(out, verbose=True, color=False)
    assert out == uncolored_layout, ('NO_COLOR changed verbose layout', shell, out)
    for state, label, color in [('stopped', '未运行', 90), ('starting', '启动中', 33),
                                ('stopping', '停止中', 33), ('failed', '异常停止', 31),
                                ('unknown', '检测失败', 31), ('error', '检测失败', 31)]:
        out, _, _ = run(shell, tty=True, expected=2 if state in ('unknown', 'error') else 1,
                        extra={'STATUS_STATE': state})
        interactive(out)
        colored_value(out, '状态', label, color)
    out, _, _ = run(shell, tty=True, extra={'STATUS_PROXY_CASE': 'lower'})
    interactive(out)
    colored_value(out, '终端代理', '已启用', 32)
    out, _, _ = run(shell, tty=True, extra={'STATUS_TUN_API': 'enabled', 'STATUS_TUN_LINK': 'up'})
    interactive(out)
    colored_value(out, 'TUN', '已启用（ct-test）', 32)
    out, _, _ = run(shell, tty=True, extra={'STATUS_TUN_API': 'unavailable'})
    interactive(out)
    colored_value(out, 'TUN', '无法检测', 33)
    out, _, _ = run(shell, tty=True, extra={'TERM': 'dumb'})
    plain(out)
    out, _, _ = run(shell, tty=True, extra={'LC_ALL': 'C'})
    plain(out)
    out, _, _ = run(shell, extra={'CLASHCTL_COLOR': 'always'})
    plain(out)
    out, _, _ = run(shell, extra={'STATUS_MANAGER': 'systemd'})
    field(out, '管理方式', 'systemd')

# Zsh 的分发与直接入口均传递当前未导出的代理变量和显式列数，且不改变父环境。
for entry in ('dispatch', 'direct'):
    for proxy_case, variable in [('lower', 'http_proxy'), ('http-upper', 'HTTP_PROXY'),
                                  ('https-lower', 'https_proxy'), ('upper', 'HTTPS_PROXY'),
                                  ('socks', 'all_proxy'), ('socks-upper', 'ALL_PROXY')]:
        out, err, _ = run('zsh', extra={'STATUS_ENTRY': entry, 'STATUS_PROXY_CASE': proxy_case,
                                       'STATUS_UNEXPORTED_PROXY': variable})
        plain(out)
        field(out, '终端代理', '已启用')
        assert not err, err
    for columns in (39, 40):
        args = ('--verbose',) if columns == 40 else ()
        for state, expected in [('running', 0), ('stopped', 1), ('unknown', 2)]:
            out, err, _ = run('zsh', args=args, tty=True, width=100, expected=expected,
                              extra={'STATUS_ENTRY': entry, 'STATUS_COLUMNS': str(columns),
                                     'STATUS_PROXY_CASE': 'lower', 'STATUS_UNEXPORTED_PROXY': 'http_proxy',
                                     'STATUS_STATE': state})
            if columns == 39:
                plain(out)
            else:
                interactive(out, verbose=True, columns=columns)
                field(out, 'PID', '24680' if state == 'running' else '—')
            field(out, '终端代理', '已启用')
            assert not err, err

# 版本和运行时长只提供信息，不改变按内核运行状态决定的退出码。
configure(**{'mixed-port': 7890})
for shell in ('bash', 'zsh', 'fish'):
    out, err, _ = run(shell, extra={'STATUS_VERSION': 'nightly'})
    field(out, '内核', 'mihomo alpha-abcdef')
    assert not err, err
    for version in ('invalid', 'error'):
        for state, expected in [('running', 0), ('stopped', 1), ('error', 2)]:
            out, err, _ = run(shell, expected=expected, extra={'STATUS_VERSION': version, 'STATUS_STATE': state})
            field(out, '内核', 'mihomo（版本未知）')
            assert not err, err
    for seconds, label in [('0', '0s'), ('8', '8s'), ('59', '59s'), ('60', '1m 00s'),
                           ('788', '13m 08s'), ('3600', '1h 00m 00s'), ('3605', '1h 00m 05s'),
                           ('86400', '1d 00h 00m 00s'), ('90061', '1d 01h 01m 01s'),
                           ('94388', '1d 02h 13m 08s'),
                           ('unavailable', '无法读取'), ('invalid', '无法读取')]:
        out, _, _ = run(shell, extra={'STATUS_UPTIME': seconds})
        field(out, '运行时长', label)

kernel = home / 'bin/mihomo'
saved_kernel = kernel.with_name('saved-mihomo')
kernel.rename(saved_kernel)
try:
    for shell in ('bash', 'zsh', 'fish'):
        out, err, _ = run(shell)
        field(out, '内核', 'mihomo（未安装）')
        assert not err, err
finally:
    saved_kernel.rename(kernel)

# TUN 结合 API、真实链路标志和内核持有关系，不能仅凭配置 enable 宣称启用。
configure(**{'mixed-port': 7890, 'tun': {'enable': True, 'device': 'ct-test'}})
for shell in ('bash', 'zsh', 'fish'):
    out, _, calls = run(shell, extra={'STATUS_TUN_API': 'disabled', 'STATUS_TUN_LINK': 'up'})
    field(out, 'TUN', '关闭')
    assert 'link' not in calls and 'tun-owner' not in calls, calls
    for extra, label in [
        ({'STATUS_TUN_API': 'enabled', 'STATUS_TUN_LINK': 'up'}, '已启用（ct-test）'),
        ({'STATUS_TUN_API': 'enabled', 'STATUS_TUN_LINK': 'up', 'STATUS_TUN_OWNER': 'foreign'}, '关闭'),
        ({'STATUS_TUN_API': 'enabled', 'STATUS_TUN_LINK': 'up', 'STATUS_TUN_OWNER': 'unavailable',
          'STATUS_ROOT': '0'}, '已启用（ct-test）'),
        ({'STATUS_TUN_API': 'enabled', 'STATUS_TUN_LINK': 'no-carrier', 'STATUS_TUN_OWNER': 'unavailable',
          'STATUS_ROOT': '0'}, '无法检测'),
        ({'STATUS_TUN_API': 'unavailable', 'STATUS_TUN_LINK': 'up'}, '已启用（ct-test）'),
        ({'STATUS_TUN_API': 'unavailable', 'STATUS_TUN_LINK': 'up', 'STATUS_TUN_OWNER': 'unavailable'}, '无法检测'),
        ({'STATUS_STATE': 'stopped', 'STATUS_TUN_API': 'enabled', 'STATUS_TUN_LINK': 'up'}, '关闭'),
        ({'STATUS_STATE': 'error', 'STATUS_TUN_API': 'enabled', 'STATUS_TUN_LINK': 'up'}, '无法检测'),
    ]:
        state = extra.get('STATUS_STATE', 'running')
        out, _, calls = run(shell, expected={'running': 0, 'stopped': 1, 'error': 2}[state], extra=extra)
        field(out, 'TUN', label)
        assert calls.count('tun-api') <= 1, calls

# Web 面板只链接已经存在的本地资源，监听通配地址转换为本机可访问的地址。
ui_dir = home / 'resources/dist'
for shell in ('bash', 'zsh', 'fish'):
    configure(**{'mixed-port': 7890, 'external-controller': '0.0.0.0:9090', 'external-ui': 'dist'})
    out, _, _ = run(shell)
    assert 'Web 面板' not in out, out
    ui_dir.mkdir(parents=True, exist_ok=True)
    (ui_dir / 'index.html').write_text('<html>local fixture</html>')
    try:
        for controller, address in [('0.0.0.0:9090', 'http://127.0.0.1:9090/ui'),
                                    ('[::]:9091', 'http://[::1]:9091/ui'),
                                    ('[2001:db8::20]:9092', 'http://[2001:db8::20]:9092/ui')]:
            configure(**{'mixed-port': 7890, 'external-controller': controller, 'external-ui': 'dist'})
            out, _, _ = run(shell)
            field(out, 'Web 面板', address)
        out, _, _ = run(shell, tty=True, extra={'STATUS_STATE': 'stopped'}, expected=1)
        interactive(out)
        field(out, 'Web 面板', 'http://[2001:db8::20]:9092/ui')
        for controller in ('', '127.0.0.1:0', '127.0.0.1:65536', 'not-a-controller'):
            configure(**{'mixed-port': 7890, 'external-controller': controller, 'external-ui': 'dist'})
            out, _, _ = run(shell)
            assert 'Web 面板' not in out, out
        configure(**{'mixed-port': 7890, 'external-controller': '127.0.0.1:9090', 'external-ui': str(ui_dir)})
        out, _, _ = run(shell)
        field(out, 'Web 面板', 'http://127.0.0.1:9090/ui')
    finally:
        (ui_dir / 'index.html').unlink()

# 已选订阅只展示选择记录的名称；元数据缺失和读取失败单独说明。
configure(**{'mixed-port': 7890})
profiles = home / 'data/profiles.yaml'
saved_profiles = profiles.read_text()
for shell in ('bash', 'zsh', 'fish'):
    out, _, _ = run(shell, args=('--verbose',), extra={'STATUS_MANAGER': 'systemd'})
    field(out, '日志', 'journalctl -u mihomo')
    profiles.write_text('{"use": ""}')
    for args in ((), ('--verbose',)):
        out, _, _ = run(shell, args=args)
        field(out, '已选订阅', '未选择')
    profiles.unlink()
    for args in ((), ('--verbose',)):
        out, _, _ = run(shell, args=args)
        field(out, '已选订阅', '未选择')
    profiles.write_text('{invalid fixture-secret')
    for args in ((), ('--verbose',)):
        out, err, _ = run(shell, args=args)
        field(out, '已选订阅', '无法读取')
        assert not err, err
profiles.write_text(saved_profiles)

# 普通名称、组合字符和 emoji 在各 UTF-8 locale 下保持相同的交互布局。
utf8_locales = []
for locale_name in subprocess.check_output(['locale', '-a'], env=env_base, text=True).splitlines():
    encoding = subprocess.check_output(['locale', 'charmap'],
                                       env=dict(env_base, LC_ALL=locale_name), text=True).strip()
    if encoding.upper().replace('-', '') == 'UTF8':
        utf8_locales.append(locale_name)
assert utf8_locales, 'a UTF-8 locale is required'
for locale_name in utf8_locales:
    for name in ('MarukoMihomo', '中文订阅', '订阅 👩‍💻', 'Cafe\u0301', '订阅 🇨🇳', '订阅 👍🏽'):
        profiles.write_text(json.dumps({'use': name}))
        for shell in ('bash', 'zsh', 'fish'):
            for args in ((), ('--verbose',)):
                out, err, _ = run(shell, args=args, tty=True, extra={'LC_ALL': locale_name})
                interactive(out, verbose=bool(args))
                field(out, '已选订阅', name)
                assert not err, err
                if args:
                    field(out, 'PID', '24680')
profiles.write_text(saved_profiles)

configure(**{'mixed-port': 7890, 'allow-lan': True, 'bind-address': 'long-' + 'x' * 100 + '.example'})
for shell in ('bash', 'zsh', 'fish'):
    out, _, _ = run(shell, tty=True, width=80)
    interactive(out, columns=80)
    contains(out, 'long-' + 'x' * 100 + '.example:7890')
print(f'status: ok ({count} checks)')
PY
