"""Drain child-process pipes with a shared byte budget and a wall-clock deadline."""
import os
import selectors
import signal
import subprocess
import time
from pathlib import Path


def run_bounded(args, *, payload=None, limit=65536, timeout=2, cancel=None, memory_limit=None):
    if payload is not None and len(payload) > limit:
        raise ValueError('Process input exceeds the safety limit.')
    guarded = ['/usr/bin/python3', str(Path(__file__).with_name('process_guard.py')), str(os.getpid())]
    if memory_limit is not None:
        guarded += ['--memory-bytes', str(memory_limit)]
    with subprocess.Popen(guarded + list(args), stdin=subprocess.PIPE if payload is not None else subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True) as process:
        out, err, total, written = bytearray(), bytearray(), 0, 0
        deadline = time.monotonic() + timeout
        try:
            with selectors.DefaultSelector() as selector:
                for stream, target in ((process.stdout, out), (process.stderr, err)):
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ, target)
                if payload:
                    os.set_blocking(process.stdin.fileno(), False)
                    selector.register(process.stdin, selectors.EVENT_WRITE, None)
                elif process.stdin:
                    process.stdin.close()
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if cancel is not None and cancel.is_set():
                        raise ValueError('Process cancelled.')
                    if remaining <= 0:
                        raise ValueError('Process timed out.')
                    for key, _ in selector.select(min(remaining, .1) if cancel is not None else remaining):
                        if key.data is None:
                            written += os.write(key.fd, payload[written:written + 4096])
                            if written == len(payload):
                                selector.unregister(key.fileobj); key.fileobj.close()
                            continue
                        try:
                            block = os.read(key.fd, min(16384, limit + 1 - total))
                        except BlockingIOError:
                            continue
                        if not block:
                            selector.unregister(key.fileobj)
                            continue
                        total += len(block)
                        if total > limit:
                            raise ValueError('Process output exceeds the safety limit.')
                        key.data.extend(block)
                status = process.wait(timeout=max(.01, deadline - time.monotonic()))
                return subprocess.CompletedProcess(args, status, bytes(out), bytes(err))
        finally:
            # Descendants may retain pipes after their immediate parent exits.
            # Every invocation owns a fresh process group; never kill unrelated apps.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

