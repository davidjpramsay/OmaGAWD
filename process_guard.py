"""Linux parent-death guard, installed before exec without a threaded preexec_fn."""
import ctypes
import os
import signal
import sys


def guard_parent(expected, death_signal=signal.SIGTERM):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, int(death_signal), 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'Cannot protect playback process lifetime')
    # Close the race where the parent died before prctl was installed.
    if os.getppid() != expected:
        os.kill(os.getpid(), death_signal)


if __name__ == '__main__':
    guard_parent(int(sys.argv[1]), signal.SIGKILL)
    os.execvp(sys.argv[2], sys.argv[2:])
