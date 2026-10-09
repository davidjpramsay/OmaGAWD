"""Private, atomic saved stations. Forgetting a station never edits the queue."""
import json
import os
from pathlib import Path
import tempfile
import time

import radio_library as radio

MAX_BYTES = 1024 * 1024
MAX_STATIONS = 1000


class RadioStore:
    def __init__(self, path=None, memory=False):
        self.path = None if memory else Path(path) if path else Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'omagawd/radio.json'
        self.rows = radio.songs()
        self.warning = ''
        self.writable = True
        if self.path:
            try:
                with self.path.open('rb') as stream: raw = stream.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES: raise ValueError('Oversized saved stations')
                self.rows = self.validate(json.loads(raw))
            except FileNotFoundError: pass
            except (ValueError, TypeError, RecursionError):
                try:
                    self.path.rename(self.path.with_name(self.path.name + '.invalid-' + str(time.time_ns())))
                    self.warning = 'Damaged saved stations were backed up. Starting with the built-in stations.'
                except OSError:
                    self.writable = False
                    self.warning = 'Could not back up damaged saved stations. The original file has been kept; saving is disabled.'
            except OSError:
                self.writable = False
                self.warning = 'Could not read saved stations. Check permissions before saving.'

    @staticmethod
    def validate(rows):
        if not isinstance(rows, list) or len(rows) > MAX_STATIONS: raise ValueError('Too many saved stations (maximum 1,000).')
        result, ids = [], set()
        for row in rows:
            clean = radio.clean_station(row)
            if clean['id'] in ids: raise ValueError('Duplicate saved station')
            ids.add(clean['id']); result.append(clean)
        return result

    def save(self, rows):
        if not self.writable: raise RuntimeError('Saved stations could not be read safely. The original file has been kept.')
        rows = self.validate(rows)
        raw = json.dumps(rows, ensure_ascii=False, allow_nan=False).encode()
        if len(raw) > MAX_BYTES: raise ValueError('Saved stations exceed the 1 MiB limit.')
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            name = None
            try:
                with tempfile.NamedTemporaryFile(dir=self.path.parent, prefix='.radio-', delete=False) as stream:
                    name = stream.name
                    stream.write(raw); stream.flush(); os.fsync(stream.fileno())
                os.replace(name, self.path)
            finally:
                if name and os.path.exists(name): os.unlink(name)
        self.rows = rows

    def add(self, row):
        row = radio.clean_station(row)
        existing = next((s for s in self.rows if radio.stream(s) == radio.stream(row)), None)
        if existing: return existing['id']
        self.save(self.rows + [row])
        return row['id']

    def remove(self, station_id):
        self.save([row for row in self.rows if row['id'] != station_id])
