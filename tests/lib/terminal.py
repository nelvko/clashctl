"""Run a command with a controlling terminal and bounded prompt replies."""
import errno
import os
import pty
import select
import signal
import subprocess
import time


def run(argv, *, env=None, replies=(), timeout=10):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, os.environ if env is None else env)
    output, status, eof, reply = b"", None, False, 0
    completed = False
    deadline = time.monotonic() + timeout
    try:
        while status is None or not eof:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, timeout, output=output)
            if not eof and select.select([fd], [], [], min(0.1, remaining))[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    chunk = b""
                eof = not chunk
                output += chunk
                while reply < len(replies) and replies[reply][0] in output:
                    os.write(fd, replies[reply][1])
                    reply += 1
            elif eof:
                time.sleep(min(0.01, remaining))
            if status is None:
                child, child_status = os.waitpid(pid, os.WNOHANG)
                if child:
                    status = child_status
        completed = True
        return os.waitstatus_to_exitcode(status), output
    finally:
        if not completed:
            # pty.fork 建立独立会话；管道和仍持有终端的后代也要回收。
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if status is None:
            os.waitpid(pid, 0)
        os.close(fd)
