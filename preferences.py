"""Small, atomic, non-secret playback preferences; queue uses playback_store."""
import json
import math
import os
from pathlib import Path
import tempfile


class Preferences:
    def __init__(self, path=None):
        self.path = Path(path) if path else Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'omagawd/playback.json'

    def load(self):
        values = {'volume': 70, 'shuffle': False, 'repeat': 'off', 'reduceMotion': False}
        try:
            with self.path.open('rb') as stream:
                raw = stream.read(4097)
            if len(raw) > 4096:
                return values
            data = json.loads(raw)
            if not isinstance(data, dict):
                return values
            volume = data.get('volume')
            if type(volume) in (int, float) and 0 <= volume <= 100 and math.isfinite(volume):
                values['volume'] = volume
            if type(data.get('shuffle')) is bool:
                values['shuffle'] = data['shuffle']
            if type(data.get('reduceMotion')) is bool:
                values['reduceMotion'] = data['reduceMotion']
            if data.get('repeat') in ('off', 'all', 'one'):
                values['repeat'] = data['repeat']
        except (OSError, ValueError, RecursionError):
            pass
        return values

    def save(self, volume, shuffle, repeat, reduce_motion=False):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        name = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', dir=self.path.parent, prefix='.playback-', delete=False) as stream:
                name = stream.name
                json.dump({'volume': volume, 'shuffle': shuffle, 'repeat': repeat, 'reduceMotion': reduce_motion}, stream, allow_nan=False)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.path)
        finally:
            if name and os.path.exists(name):
                os.unlink(name)
