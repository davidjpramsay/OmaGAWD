"""Bounded, atomic playback snapshots. Account secrets stay in Secret Service."""
import json
import math
import os
from pathlib import Path
import tempfile
import threading
import urllib.parse
import radio_library as radio
from concurrent.futures import ThreadPoolExecutor

MAX_SESSION_BYTES = 64 * 1024 * 1024
MAX_QUEUE_TRACKS = 100_000
FIELDS = ('id', 'key', 'title', 'artist', 'album', 'albumId', 'duration', 'track', 'disc', 'source', 'path')


def identity(client):
    return {'url': client.url, 'user': client.user} if client else None


def validate(data):
    if not isinstance(data, dict) or not isinstance(data.get('queue'), list) or len(data['queue']) > MAX_QUEUE_TRACKS:
        raise ValueError('Invalid playback session')
    seen, queue = set(), []
    for row in data['queue']:
        if not isinstance(row, dict) or any(not isinstance(row.get(k), str) for k in ('id', 'key', 'title', 'artist', 'album')):
            raise ValueError('Invalid saved track')
        if not row['key'] or row['key'] in seen:
            raise ValueError('Duplicate queue identity')
        seen.add(row['key'])
        local = row.get('source') == 'local'
        broadcast = row.get('source') == 'radio'
        if broadcast and radio.station(row['id']) is None: raise ValueError('Invalid saved radio station')
        if not broadcast and row['id'].startswith('radio:'): raise ValueError('Invalid radio source')
        if local and (not row['id'].startswith('local:') or not isinstance(row.get('path'), str) or not Path(row['path']).is_absolute()):
            raise ValueError('Invalid saved local track')
        if not local and row['id'].startswith('local:'):
            raise ValueError('Invalid remote track')
        duration = row.get('duration', 0)
        if type(duration) not in (int, float) or not 0 <= duration <= 2**31 or not math.isfinite(duration):
            raise ValueError('Invalid duration')
        clean = {k: row[k] for k in FIELDS if k in row}
        if 'albumId' in clean and not isinstance(clean['albumId'], str):
            raise ValueError('Invalid album identity')
        for field in ('track', 'disc'):
            if field in clean and (type(clean[field]) is not int or not 0 <= clean[field] <= 2**31):
                raise ValueError('Invalid track number')
        clean['duration'] = duration
        if broadcast:
            clean = dict(radio.station(row['id']), key=row['key'])
        if not local:
            clean.pop('path', None)
            if not broadcast: clean.pop('source', None)
        queue.append(clean)
    index, position = data.get('index', -1), data.get('position', 0)
    if type(index) is not int or index < -1 or index >= len(queue): raise ValueError('Invalid queue index')
    if type(position) not in (int, float) or not 0 <= position <= 2**31 or not math.isfinite(position): raise ValueError('Invalid position')
    library = data.get('library')
    if library is not None:
        if not isinstance(library, dict) or not all(isinstance(library.get(k), str) and library[k] for k in ('url', 'user')):
            raise ValueError('Invalid library identity')
        library = {k: library[k] for k in ('url', 'user')}
        url = urllib.parse.urlsplit(library['url'])
        if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError('Invalid saved server URL')
    if any(radio.remote(row) for row in queue) and library is None:
        raise ValueError('Missing remote library identity')
    folder = data.get('folder', 'local')
    if not isinstance(folder, str): raise ValueError('Invalid saved library')
    duration = queue[index]['duration'] if index >= 0 else 0
    if index >= 0 and queue[index].get('source') == 'radio': position = 0
    return {'queue': queue, 'index': index, 'position': (min(position, duration) if duration > 0 else position) if index >= 0 else 0,
            'idle': data.get('idle') is not False or index < 0, 'folder': folder, 'library': library}


class PlaybackStore:
    def __init__(self, path=None):
        self.path = Path(path) if path else Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'omagawd/playback-session.json'
        self.worker = ThreadPoolExecutor(max_workers=1)
        self.pending = None
        self.lock = threading.Lock()
        self.latest = None
        self.error = None
        self.closed = False

    def load(self):
        try:
            with self.path.open('rb') as stream: raw = stream.read(MAX_SESSION_BYTES + 1)
            if len(raw) > MAX_SESSION_BYTES: return None
            return validate(json.loads(raw))
        except (OSError, ValueError, TypeError, RecursionError): return None

    def save(self, data):
        # Keep just the latest snapshot while a write is running.
        with self.lock:
            if self.closed: return False
            self.latest = data
            if self.pending is None:
                self.pending = self.worker.submit(self.drain)
            return True

    def drain(self):
        while True:
            with self.lock:
                if self.latest is None:
                    self.pending = None
                    return
                data, self.latest = self.latest, None
            try:
                self.write(data)
            except (OSError, ValueError, TypeError, RecursionError) as exc:
                with self.lock: self.error = exc

    def take_error(self):
        with self.lock:
            error, self.error = self.error, None
            return error

    def write(self, data):
        safe = validate(data)
        payload = json.dumps(safe, allow_nan=False, separators=(',', ':')).encode()
        if len(payload) > MAX_SESSION_BYTES: raise ValueError('Playback session too large')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        name = None
        try:
            with tempfile.NamedTemporaryFile(dir=self.path.parent, prefix='.session-', delete=False) as stream:
                name = stream.name
                stream.write(payload); stream.flush(); os.fsync(stream.fileno())
            os.replace(name, self.path)
        finally:
            if name and os.path.exists(name): os.unlink(name)

    def close(self, data):
        with self.lock: self.closed = True
        self.worker.shutdown(wait=True)
        self.write(data)
