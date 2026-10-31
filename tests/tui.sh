#!/usr/bin/env bash
set -euo pipefail
export REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export TEST_YQ=${TEST_YQ:-$(command -v yq || true)}
python3 - <<'PY'
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time

repo = Path(os.environ['REPO_DIR'])
yq = os.environ['TEST_YQ']
assert yq and Path(yq).is_file(), 'MikeFarah yq v4 is required'
with tempfile.TemporaryDirectory(prefix='clashctl-tui-') as work:
    home = Path(work)
    shutil.copytree(repo / 'scripts', home / 'scripts')
    (home / 'data').mkdir()
    (home / 'bin').mkdir()
    (home / 'resources').mkdir()
    (home / 'bin/yq').symlink_to(yq)
    (home / 'bin/mihomo').write_text('#!/bin/sh\nexit 0\n')
    (home / 'bin/mihomo').chmod(0o755)
    (home / '.env').write_text('CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\n')
    (home / 'scripts/lib/zz-fixture.sh').write_text('''
detect_service_manager() { service_manager=systemd-user; }
service_state() { if [ -f "$CLASHCTL_HOME/running" ]; then echo running; else echo stopped; fi; }
service_is_active() { [ -f "$CLASHCTL_HOME/running" ]; }
service_start() { [ ! -f "$CLASHCTL_HOME/fail-start" ] || return 1; echo start >>"$CLASHCTL_HOME/actions"; touch "$CLASHCTL_HOME/running"; }
service_stop() { [ ! -f "$CLASHCTL_HOME/fail-stop" ] || return 1; echo stop >>"$CLASHCTL_HOME/actions"; command rm -f "$CLASHCTL_HOME/running"; }
service_enable() { echo enable >>"$CLASHCTL_HOME/actions"; }
service_disable() { echo disable >>"$CLASHCTL_HOME/actions"; }
systemctl() { [ "$2" = is-enabled ] && { echo disabled; return 1; }; return 99; }
_kernel_start() { service_start; }
tunstatus() { return 1; }
''')
    (home / 'scripts/cmd/zz-fixture.sh').write_text('clashsub() {\n    printf \'sub:%s\\n\' "$*" >>"$CLASHCTL_HOME/actions"\n    echo \'Subscription operation complete (fixture).\'\n}\n')
    with (home / 'scripts/cmd/zz-fixture.sh').open('a') as fixture:
        fixture.write('clashnode() {\n    printf \'node:%s\\n\' "$*" >>"$CLASHCTL_HOME/actions"\n    echo \'Node selected (fixture).\'\n}\n')
    with (home / 'scripts/cmd/zz-fixture.sh').open('a') as fixture:
        fixture.write("\n_sub_names() { printf 'Alpha\\nBeta\\n'; }\n_sub_current() { echo Alpha; }\n")
        fixture.write("_node_curl() { printf '%s' '{\"proxies\":{\"Group\":{\"type\":\"Selector\",\"now\":\"Tokyo\",\"all\":[\"Tokyo\",\"Hong Kong\"]}}}'; }\n")
    env = dict(os.environ, CLASHCTL_HOME=str(home), CLASHCTL_SRC=str(home),
               TERM='xterm-256color', NO_COLOR='1')
    config = {'mixed-port': 37700, 'allow-lan': False, 'mode': 'direct',
              'external-controller': '127.0.0.1:9090', 'tun': {'enable': False}}
    mixin = home / 'data/mixin.yaml'
    runtime = home / 'data/runtime.yaml'
    mixin.write_text(json.dumps(config))
    source = '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; '

    def run(code, expected=0):
        result = subprocess.run(['bash', '-c', source + code], env=env,
                                text=True, capture_output=True, timeout=15)
        assert result.returncode == expected, (code, result.returncode, result.stdout, result.stderr)
        return result

    def read(path):
        return json.loads(subprocess.check_output([yq, '-o=json', '.', str(path)], text=True))

    run('_merge_config')
    run('clashctl tui --help')
    run('clashctl tui', expected=1)
    run('_tui_set mixed-port 40123')
    assert read(mixin)['mixed-port'] == read(runtime)['mixed-port'] == 40123
    assert not (home / 'running').exists() and not (home / 'actions').exists()
    before = (mixin.read_bytes(), runtime.read_bytes())
    for key, value in [('mixed-port', '0'), ('port', '65536'), ('port', 'abc'),
                       ('mode', 'evil'), ('external-controller', 'localhost:0')]:
        run(f'_tui_set {key} {value}', expected=1)
        assert before == (mixin.read_bytes(), runtime.read_bytes())
    run('_valid_config() { return 1; }; _tui_set mixed-port 40124', expected=1)
    assert before == (mixin.read_bytes(), runtime.read_bytes())
    assert not (home / 'data/startup.lock.d').exists()
    run('_tui_set secret true; _tui_set external-controller "[::1]:9091"')
    assert read(mixin)['secret'] == 'true'
    assert read(mixin)['external-controller'] == '[::1]:9091'
    (home / 'running').touch()
    run('_tui_set mode rule')
    assert read(runtime)['mode'] == 'rule'
    assert (home / 'actions').read_text().splitlines() == ['stop', 'start']
    run('_tui_startup disable; _tui_startup enable')
    assert (home / 'actions').read_text().splitlines()[-2:] == ['disable', 'enable']
    run('service_start() { return 1; }; _tui_set mode direct', expected=1)
    assert read(mixin)['mode'] == 'direct'
    run('service_state() { return 1; }; _tui_set mode rule', expected=1)
    assert read(mixin)['mode'] == 'direct'
    (home / 'actions').unlink()

    # Repainting an unchanged frame must emit no bytes. Moving selection must
    # leave the header untouched and never issue a full-screen erase.
    renderer = "_TUI_FRAME_LINES=(); _TUI_FRAME_WIDTH=0; _TUI_FRAME_HEIGHT=0; _TUI_SCREEN_DIRTY=false; "
    frame = "frame=$'Header\\n> First\\n  Second'; "
    result = run(renderer + frame + '_tui_render_frame "$frame" 35 110 >/dev/null; '
                 '_tui_render_frame "$frame" 35 110')
    assert result.stdout == '', result.stdout
    result = run(renderer + frame + '_tui_render_frame "$frame" 35 110 >/dev/null; '
                 'frame=$\'Header\\n  First\\n> Second\'; _tui_render_frame "$frame" 35 110')
    assert 'Header' not in result.stdout and '\x1b[2J' not in result.stdout
    assert '\x1b[2;1H' in result.stdout and '\x1b[3;1H' in result.stdout

    # Compact viewport, wide characters, escape sanitization and original-index filtering.
    result = run('_TUI_COLUMNS=40; _tui_line "' + '节点' * 30 + '"')
    assert len(result.stdout.strip()) == 19, result.stdout
    result = run('_TUI_COLUMNS=80; _tui_line $\'safe\\e[31mname\'')
    assert '\x1b' not in result.stdout
    result = run('_TUI_COLOR=false; _TUI_COLUMNS=40; _TUI_PAGE=Overview; '
                 '_tui_build_frame $\'Title\\nRule\\nState\\nService\\nSub\\nAddress\' 8 15 '
                 'one two three four five six seven eight nine')
    assert '> 9  nine' in result.stdout and '    1  one' not in result.stdout
    assert len(result.stdout.splitlines()) < 15
    result = run('declare -A _TUI_SELECTIONS=(); calls=0; '
                 '_tui_menu() { calls=$((calls+1)); if [ "$calls" = 1 ]; then _TUI_CHOICE=search; '
                 'else [ "$2" = "Hong Kong" ] || return 1; _TUI_CHOICE=0; fi; }; '
                 '_tui_input() { _TUI_VALUE=kong; }; '
                 '_tui_choose Nodes Tokyo "Hong Kong" London; printf "INDEX:%s" "$_TUI_CHOICE"')
    assert result.stdout == 'INDEX:1', result.stdout
    result = run('_tui_quick() { "$@"; }; _tui_choose() { _TUI_CHOICE=1; }; '
                 '_sub_names() { printf "Alpha\\nBeta space\\n"; }; _sub_current() { echo Alpha; }; '
                 '_tui_pick_subscription')
    assert 'sub:use Beta space' in (home / 'actions').read_text()
    result = run('_tui_quick() { "$@"; }; _tui_choose() { _TUI_CHOICE=1; }; '
                 '_node_curl() { printf \'%s\' \'{"proxies":{"Group":{"type":"Selector",'
                 '"now":"Tokyo","all":["Tokyo","Hong Kong"]}}}\'; }; _tui_pick_node')
    assert 'node:use -- Group Hong Kong' in (home / 'actions').read_text()
    (home / 'actions').unlink()

    # Drive the real UI through a PTY. Verify keyboard navigation, saved ports,
    # start/stop dispatch, normal exit and signal cleanup without host services.
    def session(shell='bash', interrupt=False, proxy=None, language=None, quick=False):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 110, 0, 0))
        original = termios.tcgetattr(slave)
        variables = ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY',
                     'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY']
        after = ' printf "AFTER|' + '|'.join(['%s'] * len(variables)) + '\\n" ' + ' '.join('"$' + v + '"' for v in variables)
        if shell == 'fish':
            command = ['fish', '--no-config', '-c', 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; clashctl tui; set -l rc $status; ' + after + '; exit $rc']
        else:
            command = [shell, '-f' if shell == 'zsh' else '--noprofile', '-c', source + 'clashctl tui; rc=$?; ' + after + '; exit "$rc"']
        session_env = dict(env, **{v: 'before-' + v for v in variables})
        process = subprocess.Popen(command, env=session_env, stdin=slave, stdout=slave, stderr=slave,
                                   start_new_session=True)
        output = b''
        transcript = b''
        def expect(token):
            nonlocal output, transcript
            token = token.encode()
            deadline = time.monotonic() + 15
            while token not in output:
                assert time.monotonic() < deadline, (token, output[-1500:])
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try: chunk = os.read(master, 65536)
                    except OSError as e:
                        if e.errno == errno.EIO: chunk = b''
                        else: raise
                    assert chunk, (token, process.poll(), output[-1500:])
                    output += chunk
                    transcript += chunk
            output = output.split(token, 1)[1]
        def send(keys): os.write(master, keys.encode())
        try:
            saved_language = home / 'data/tui-language'
            chinese = saved_language.exists() and saved_language.read_text().strip() == 'zh-CN'
            expect('按数字键直接选择。' if chinese else 'Number keys select immediately.')
            if language is not None:
                if language == 'view-zh':
                    assert chinese
                    send('1')
                    expect('启动内核')
                    expect('按数字键直接选择。')
                    send('q')
                    expect('按数字键直接选择。')
                    send('q')
                else:
                    send('9')
                    expect('Language / 语言')
                    expect('简体中文')
                    expect('按数字键直接选择。' if chinese else 'Number keys select immediately.')
                    send('2' if language == 'zh-CN' else '1')
                    if language == 'zh-CN':
                        expect('内核与自启')
                        expect('按数字键直接选择。')
                        send('4')
                        expect('代理端口')
                        expect('按数字键直接选择。')
                        send('1')
                        expect('留空取消')
                        send('not-a-port\n')
                        expect('端口必须是 0 到 65535 之间的整数。')
                        expect('按任意键返回')
                        send('x')
                        expect('按数字键直接选择。')
                        send('q')
                        expect('按数字键直接选择。')
                    else:
                        expect('Kernel & startup')
                        expect('Number keys select immediately.')
                    send('q')
            elif interrupt:
                os.killpg(process.pid, signal.SIGTERM)
            elif proxy is not None:
                if quick:
                    send({'on': 'o', 'off': 'f', 'stop': 'x', 'failed-on': 'o', 'failed-stop': 'x'}[proxy])
                    if proxy in ('stop', 'failed-stop'):
                        expect('[y/N]')
                        send('y\n')
                    if proxy.startswith('failed'):
                        expect('Press any key to return')
                        send('z')
                        expect('Number keys select immediately.')
                    else:
                        expect('Done.')
                    send('q')
                else:
                    send('8')
                    expect('Number keys select immediately.')
                    key = {'on': '1', 'failed-on': '1', 'off': '2', 'stop': '3', 'failed-stop': '3'}[proxy]
                    send(key)
                    expect('Press any key to return')
                    send('x')
                    expect('Number keys select immediately.')
                    send('qq')
            elif shell == 'bash':
                # One full idle refresh interval must leave the terminal untouched.
                assert not select.select([master], [], [], 2.5)[0], 'idle TUI repainted unchanged content'
                send('4')
                expect('Proxy ports')
                expect('Number keys select immediately.')
                send('\r')
                expect('empty cancels')
                send('40125\n')
                expect('Press any key to return')
                send('x')
                expect('Number keys select immediately.')
                send('q')
                expect('Number keys select immediately.')
                send('g\x1b[B')
                expect('> 2  Subscriptions')
                send('\x1b[A')
                expect('> 1  Kernel & startup')
                send('\r')
                expect('Number keys select immediately.')
                send('1')
                expect('Press any key to return')
                send('x')
                expect('Number keys select immediately.')
                send('2')
                expect('[y/N]')
                send('y\n')
                expect('Press any key to return')
                send('x')
                expect('Number keys select immediately.')
                send('q')
                expect('Number keys select immediately.')
                send('2')
                expect('Add & activate subscription')
                expect('Number keys select immediately.')
                send('2')
                expect('empty cancels')
                send('\x1b[200~https://example.invalid/visible-token\x1b[201~')
                expect('https://example.invalid/visible-token')
                send('\n')
                expect('Press any key to return')
                assert b'visible-token' in transcript, 'subscription URL was not echoed'
                send('x')
                expect('Number keys select immediately.')
                send('3')
                expect('Beta')
                expect('Number keys select immediately.')
                send('2')
                expect('Done.')
                send('7')
                expect('Hong Kong')
                expect('Number keys select immediately.')
                send('2')
                expect('Done.')
                send('8')
                expect('Node selected (fixture).')
                expect('Press any key to return')
                send('x')
                expect('Number keys select immediately.')
                send('qq')
            else:
                send('q')
            rc = process.wait(timeout=10)
            assert rc in ((143, -signal.SIGTERM) if interrupt else (0,)), rc
            # The forwarding shell can exit before the UI child finishes its trap.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if not select.select([master], [], [], 0.1)[0]:
                    if b'\x1b[?1049l' in output: break
                    continue
                try: chunk = os.read(master, 65536)
                except OSError: break
                if not chunk: break
                output += chunk
            assert b'\x1b[?1049l' in output, output[-1000:]
            assert b'\x1b[2J' not in transcript + output, 'TUI cleared the full screen'
            assert termios.tcgetattr(slave) == original, 'terminal mode was not restored'
            if not interrupt:
                combined = transcript + output
                if proxy == 'on':
                    port = read(runtime)['mixed-port']
                    expected = [f'http://127.0.0.1:{port}'] * 4 + [f'socks5h://127.0.0.1:{port}'] * 2 + ['localhost,127.0.0.1,::1'] * 2
                elif proxy in ('off', 'stop', 'failed-stop'):
                    expected = [''] * len(variables)
                else:
                    expected = ['before-' + v for v in variables]
                marker = ('AFTER|' + '|'.join(expected)).encode()
                assert marker in combined, (shell, proxy, marker, combined[-1500:])
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)
            os.close(slave)
    session()
    assert read(mixin)['mixed-port'] == 40125
    actions = (home / 'actions').read_text()
    assert 'start' in actions
    assert 'sub:add --use https://example.invalid/visible-token' in actions
    assert 'sub:use' in actions
    assert 'node:use' in actions and 'node:use --delay' in actions
    assert (home / 'running').exists()
    for shell in ('zsh', 'fish'):
        assert shutil.which(shell), f'{shell} is required'
        session(shell)
    session(interrupt=True)
    for shell in ('bash', 'zsh', 'fish'):
        session(shell, proxy='on')
        assert (home / 'running').exists()
        session(shell, proxy='off')
        assert (home / 'running').exists(), 'off unexpectedly stopped the kernel'
        session(shell, proxy='stop')
        assert not (home / 'running').exists()
        (home / 'fail-start').touch()
        session(shell, proxy='failed-on')
        (home / 'fail-start').unlink()
        (home / 'running').touch()
        (home / 'fail-stop').touch()
        session(shell, proxy='failed-stop')
        assert (home / 'running').exists()
        (home / 'fail-stop').unlink()
    for shell in ('bash', 'zsh', 'fish'):
        session(shell, proxy='on', quick=True)
        session(shell, proxy='off', quick=True)
        session(shell, proxy='stop', quick=True)
    (home / 'fail-start').touch()
    session(proxy='failed-on', quick=True)
    (home / 'fail-start').unlink()
    run('clashctl secret true')
    assert read(mixin)['secret'] == 'true'
    run('clashctl secret 012345')
    assert read(mixin)['secret'] == '012345'
    language_file = home / 'data/tui-language'
    for shell in ('bash', 'zsh', 'fish'):
        language_file.write_text('en\n')
        session(shell, language='zh-CN')
        assert language_file.read_text() == 'zh-CN\n'
        assert language_file.stat().st_mode & 0o777 == 0o600
        session(shell, language='view-zh')
        session(shell, language='en')
        assert language_file.read_text() == 'en\n'
    (home / 'data/profiles.yaml').write_text('use: direct\n')
    result = run('_TUI_COLOR=false; _TUI_LANGUAGE=zh-CN; _tui_header test')
    assert '当前订阅：direct' in result.stdout
    language_file.write_text('$(touch "$CLASHCTL_HOME/injected")\n')
    assert run('_tui_load_language; printf "%s" "$_TUI_LANGUAGE"').stdout == 'en'
    assert not (home / 'injected').exists()
print('tui: ok')
PY
