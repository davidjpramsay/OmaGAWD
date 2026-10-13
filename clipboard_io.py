"""Explicit clipboard reads happen in the backend, never through Qt's clipboard."""
from bounded_process import run_bounded

MAX_CLIPBOARD_BYTES = 64 * 1024
CLIPBOARD_TIMEOUT = 2


def read_clipboard(primary=False):
    args = ['wl-paste', '--no-newline', '--type', 'text']
    if primary:
        args.append('--primary')
    result = run_bounded(args, limit=MAX_CLIPBOARD_BYTES, timeout=CLIPBOARD_TIMEOUT, memory_limit=128*1024*1024)
    if result.returncode:
        raise ValueError('Clipboard text is unavailable.')
    return result.stdout.decode('utf-8')

