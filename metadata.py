"""Normalize untrusted music metadata before it reaches QML or saved queues."""
import math

MAX_TEXT = 512
MAX_NUMBER = 2**31


def text(value, fallback=''):
    return value[:MAX_TEXT] if isinstance(value, str) and value else fallback


def number(value):
    if type(value) not in (int, float) or not 0 <= value <= MAX_NUMBER or not math.isfinite(value):
        return 0
    return value

