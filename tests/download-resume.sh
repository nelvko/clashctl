#!/usr/bin/env bash
# Exercise the real curl downloader against a local HTTP server; no external network.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
SERVER_PID=''
cleanup_hook() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}

command -v python3 >/dev/null || fail 'python3 is required for the local HTTP fixture'
command -v curl >/dev/null || fail 'curl is required for the download regression'
export NO_PROXY=127.0.0.1,localhost
export no_proxy=$NO_PROXY

export CLASHCTL_SRC=$REPO_DIR
export CLASHCTL_HOME="$WORK_DIR/home"
export CLASHCTL_KERNEL=mihomo
export CLASHCTL_COLOR=never
mkdir -p -- "$CLASHCTL_HOME"

# Total download time is unlimited by default, while explicit user values survive loading.
(
    unset CLASHCTL_DOWNLOAD_TIMEOUT
    # shellcheck source=../scripts/lib/common.sh
    . "$REPO_DIR/scripts/lib/common.sh"
    [ "$CLASHCTL_DOWNLOAD_TIMEOUT" = 0 ] || fail 'default total download timeout is not unlimited'
    for timeout in 0 180; do
        CLASHCTL_DOWNLOAD_TIMEOUT=$timeout
        . "$REPO_DIR/scripts/lib/common.sh"
        [ "$CLASHCTL_DOWNLOAD_TIMEOUT" = "$timeout" ] || fail 'explicit download timeout was overwritten'
    done
)

# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"

# shellcheck disable=SC2034  # Read by sourced downloader functions.
ZIP_BASE_DIR="$WORK_DIR/archives"
# shellcheck disable=SC2034
GH_PROXY=''
# shellcheck disable=SC2034
CLASHCTL_DOWNLOAD_TIMEOUT=3
mkdir -p -- "$ZIP_BASE_DIR"

cat >"$WORK_DIR/server.py" <<'PY'
import gzip
import http.server
import json
import pathlib
import random
import socket
import sys
import threading

root = pathlib.Path(sys.argv[1])
rng = random.Random(1327)
body = gzip.compress(bytes(rng.getrandbits(8) for _ in range(131072)), mtime=0)
(root / 'source.gz').write_bytes(body)
cut = 16384
counts = {}
guard = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        with guard:
            counts[self.path] = counts.get(self.path, 0) + 1
            count = counts[self.path]
        header = self.headers.get('Range', '')
        offset = int(header.removeprefix('bytes=').removesuffix('-')) if header else 0
        with guard, (root / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'range': header, 'offset': offset}) + '\n')

        if self.path == '/missing.gz' or (self.path == '/server-error.gz' and count == 1):
            self.send_response(404 if self.path == '/missing.gz' else 503)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return

        if self.path == '/reject-range.gz' and header:
            self.send_response(416)
            self.send_header('Content-Range', f'bytes */{len(body)}')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return

        use_range = bool(header) and self.path != '/ignore-range.gz'
        start = offset if use_range else 0
        self.send_response(206 if use_range else 200)
        if use_range:
            self.send_header('Content-Range', f'bytes {start}-{len(body) - 1}/{len(body)}')
        self.send_header('Content-Length', str(len(body) - start))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()

        interrupted = self.path == '/automatic.gz' and count == 1
        interrupted |= self.path == '/across-runs.gz' and count <= 2
        timed_out = self.path == '/timeout.gz' and count <= 2
        payload = body[start:start + cut] if interrupted or timed_out else body[start:]
        try:
            self.wfile.write(payload)
            self.wfile.flush()
            if timed_out:
                # Long enough to exceed curl's tiny test timeout, with no long test sleep.
                threading.Event().wait(0.4)
            if interrupted or timed_out:
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
(root / 'port').write_text(str(server.server_address[1]))
server.serve_forever()
PY

python3 "$WORK_DIR/server.py" "$WORK_DIR" >"$WORK_DIR/server.stdout" 2>"$WORK_DIR/server.stderr" &
SERVER_PID=$!
for _ in {1..100}; do
    [ ! -s "$WORK_DIR/port" ] || break
    kill -0 "$SERVER_PID" 2>/dev/null || fail 'local HTTP fixture exited before startup'
    sleep 0.02
done
[ -s "$WORK_DIR/port" ] || fail 'local HTTP fixture did not start'
BASE_URL="http://127.0.0.1:$(<"$WORK_DIR/port")"

download() {
    local name=$1
    _download_archive "$name" "$BASE_URL/$name.gz" "$ZIP_BASE_DIR/$name.gz" \
        >"$WORK_DIR/$name.stdout" 2>"$WORK_DIR/$name.stderr"
}

assert_downloaded() {
    local name=$1
    cmp -s -- "$WORK_DIR/source.gz" "$ZIP_BASE_DIR/$name.gz" || {
        cat "$WORK_DIR/$name.stderr" >&2
        fail "$name: final archive differs from the HTTP source"
    }
    assert_absent "$ZIP_BASE_DIR/$name.gz.part" "$name completed fragment"
}

assert_ranges() {
    local name=$1 expected=$2
    python3 - "$WORK_DIR/requests.jsonl" "/$name.gz" "$expected" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
actual = [row['offset'] for row in rows if row['path'] == sys.argv[2]]
expected = json.loads(sys.argv[3])
if actual != expected:
    raise SystemExit(f'FAIL: {sys.argv[2]} requested offsets {actual}, expected {expected}')
PY
}

# A partial HTTP response must retry from the bytes already received, inside one call.
download automatic || fail 'interrupted transfer did not recover automatically'
assert_downloaded automatic
assert_ranges automatic '[0,16384]'

# Exhausting both network attempts preserves the cumulative fragment for a rerun.
if download across-runs; then
    fail 'two interrupted responses unexpectedly completed'
fi
assert_absent "$ZIP_BASE_DIR/across-runs.gz" 'failed transfer final cache'
[ "$(stat -c %s -- "$ZIP_BASE_DIR/across-runs.gz.part")" -eq 32768 ] ||
    fail 'failed transfer did not retain both responses in its fragment'
download across-runs || fail 'later invocation did not resume retained fragment'
assert_downloaded across-runs
assert_ranges across-runs '[0,16384,32768]'

# A real curl timeout follows the same path, and records the installer timeout flag.
# shellcheck disable=SC2034
CLASHCTL_DOWNLOAD_TIMEOUT=0.1
unset CLASHCTL_DOWNLOAD_TIMED_OUT
if download timeout; then
    fail 'two timed-out responses unexpectedly completed'
fi
[ "${CLASHCTL_DOWNLOAD_TIMED_OUT:-0}" = 1 ] || fail 'timeout state was not recorded'
[ "$(stat -c %s -- "$ZIP_BASE_DIR/timeout.gz.part")" -eq 32768 ] ||
    fail 'timeout did not preserve downloaded bytes across retry'
# shellcheck disable=SC2034
CLASHCTL_DOWNLOAD_TIMEOUT=3
download timeout || fail 'later invocation did not resume a timed-out fragment'
assert_downloaded timeout
assert_ranges timeout '[0,16384,32768]'

# Retry a transient HTTP failure without losing the prefix; do not retry a 404.
head -c 16384 "$WORK_DIR/source.gz" >"$ZIP_BASE_DIR/server-error.gz.part"
download server-error || fail 'transient HTTP failure was not retried'
assert_downloaded server-error
assert_ranges server-error '[16384,16384]'
head -c 16384 "$WORK_DIR/source.gz" >"$ZIP_BASE_DIR/missing.gz.part"
if download missing; then
    fail 'HTTP 404 unexpectedly completed'
fi
assert_ranges missing '[16384]'
[ "$(stat -c %s -- "$ZIP_BASE_DIR/missing.gz.part")" -eq 16384 ] ||
    fail 'HTTP 404 discarded an existing fragment'

# Some release mirrors ignore Range or reject it; both need one clean fallback.
for name in ignore-range reject-range; do
    head -c 16384 "$WORK_DIR/source.gz" >"$ZIP_BASE_DIR/$name.gz.part"
    download "$name" || fail "$name did not recover with a complete download"
    assert_downloaded "$name"
    assert_ranges "$name" '[16384,0]'
done

# A matching size alone cannot establish validity: corrupt prefixes must be discarded.
head -c 16384 "$WORK_DIR/source.gz" >"$ZIP_BASE_DIR/corrupt.gz.part"
printf 'bad' | dd of="$ZIP_BASE_DIR/corrupt.gz.part" bs=1 seek=0 conv=notrunc status=none
if download corrupt; then
    fail 'resumed archive with corrupt prefix passed validation'
fi
assert_absent "$ZIP_BASE_DIR/corrupt.gz" 'corrupt resumed final cache'
assert_absent "$ZIP_BASE_DIR/corrupt.gz.part" 'corrupt resumed fragment'
download corrupt || fail 'clean retry after failed validation did not recover'
assert_downloaded corrupt
assert_ranges corrupt '[16384,0]'

# A complete fragment left by an interrupted final move needs no network request.
cp -- "$WORK_DIR/source.gz" "$ZIP_BASE_DIR/complete.gz.part"
download complete || fail 'valid complete fragment was not adopted'
assert_downloaded complete
assert_ranges complete '[]'

# Reusing the stable fragment path must never follow a symlink into another file.
printf 'outside-unchanged\n' >"$WORK_DIR/outside"
ln -s "$WORK_DIR/outside" "$ZIP_BASE_DIR/link.gz.part"
if download link; then
    assert_downloaded link
fi
[ "$(<"$WORK_DIR/outside")" = outside-unchanged ] ||
    fail 'download followed a fragment symlink and modified its target'

# Hard links also share file content, so they need replacement before curl writes.
ln "$WORK_DIR/outside" "$ZIP_BASE_DIR/hardlink.gz.part"
if download hardlink; then
    assert_downloaded hardlink
fi
[ "$(<"$WORK_DIR/outside")" = outside-unchanged ] ||
    fail 'download appended to a hard-linked fragment and modified its other link'

# Check the real archive download arguments without waiting for the low-speed limit.
(
    # shellcheck disable=SC2317  # Called by the sourced downloader.
    curl() {
        local arg output='' previous=''
        printf '%s\n' "$@" >"$WORK_DIR/download-args"
        for arg in "$@"; do
            if [ "$previous" = --output ]; then output=$arg; fi
            previous=$arg
        done
        [ -n "$output" ] || return 1
        cp -- "$WORK_DIR/source.gz" "$output" || return 1
        printf '200'
    }

    for timeout in 0 180; do
        CLASHCTL_DOWNLOAD_TIMEOUT=$timeout
        _download_archive 'download policy' 'https://example.invalid/archive.gz' \
            "$ZIP_BASE_DIR/timeout-policy-$timeout.gz" >"$WORK_DIR/policy.stdout" 2>"$WORK_DIR/policy.stderr" ||
            fail "download policy probe failed for max-time=$timeout"
        python3 - "$WORK_DIR/download-args" "$timeout" <<'PY'
import pathlib
import sys

args = pathlib.Path(sys.argv[1]).read_text().splitlines()
expected = {
    '--connect-timeout': '15',
    '--speed-limit': '1024',
    '--speed-time': '60',
    '--max-time': sys.argv[2],
}
for option, value in expected.items():
    if args.count(option) != 1 or args[args.index(option) + 1:args.index(option) + 2] != [value]:
        raise SystemExit(f'FAIL: download policy expected {option} {value}, got {args}')
PY
    done
)

printf 'PASS: real HTTP interruption, timeout, resume, mirror fallback, validation, and symlink safety\n'
