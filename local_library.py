"""Persist explicitly chosen local sources and index audio tags with ffprobe."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid
import tempfile
import metadata
from media_policy import EXTENSIONS, FORMAT_WHITELIST, local_file
from bounded_process import run_bounded

MAX_LOCAL_TRACKS = 100_000
MAX_PROBE_BYTES = 2 * 1024 * 1024
MAX_LOCAL_BYTES = 64 * 1024 * 1024
MAX_SOURCE_BYTES = 1024 * 1024
MAX_SOURCES = 1000
MAX_SCAN_ENTRIES = 1_000_000
MAX_SCAN_DIRECTORIES = 100_000


def probe_output(command, timeout=10, cancel=None):
    """Drain ffprobe incrementally; hostile tags cannot fill captured stdout."""
    result = run_bounded(command, limit=MAX_PROBE_BYTES, timeout=timeout, cancel=cancel)
    if result.returncode: raise ValueError('Unreadable audio')
    return result.stdout


class LocalLibrary:
    def __init__(self, path=None):
        self.path = Path(path) if path else Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'omagawd/local.json'
        self.roots, self.prefer_local, self.cache = [], False, {}
        self.warning = ''
        if self.path.exists():
            try:
                with self.path.open('rb') as stream: raw = stream.read(MAX_SOURCE_BYTES + 1)
                if len(raw) > MAX_SOURCE_BYTES: raise ValueError('Local settings exceed the safety limit.')
                data = json.loads(raw)
                if not isinstance(data, dict) or not isinstance(data.get('paths', []), list):
                    raise ValueError('Invalid local settings')
                paths = data.get('paths', [])
                if len(paths) > MAX_SOURCES or any(not isinstance(p,str) or not p or len(p)>4096 or '\0' in p for p in paths):
                    raise ValueError('Invalid local sources')
                self.roots = list(dict.fromkeys(str(Path(p).expanduser().resolve()) for p in paths))
                self.prefer_local = bool(data.get('preferLocal', False))
            except (OSError, ValueError, RuntimeError, TypeError, RecursionError):
                backup = self.path.with_name(self.path.name + '.damaged-' + uuid.uuid4().hex)
                try:
                    self.path.rename(backup)
                    self.warning = 'Local settings were unreadable. A backup was kept; add your music sources again.'
                except OSError:
                    self.warning = 'Local settings could not be read or backed up. Check file permissions.'
                    self.path = None  # Never overwrite settings we could not preserve.
                self.roots, self.prefer_local = [], False

    def save(self):
        if self.path is None:
            raise RuntimeError('Local settings are not writable. Check file permissions and reopen the player.')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        raw = json.dumps({'paths': self.roots, 'preferLocal': self.prefer_local}).encode()
        if len(self.roots) > MAX_SOURCES or len(raw) > MAX_SOURCE_BYTES:
            raise ValueError('Local settings exceed the 1 MiB / 1,000-source safety limit.')
        name = None
        try:
            with tempfile.NamedTemporaryFile(dir=self.path.parent, prefix='.local-', delete=False) as stream:
                name = stream.name
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            os.replace(name, self.path)
        finally:
            if name and os.path.exists(name): os.unlink(name)

    def add(self, paths):
        if not isinstance(paths, list) or len(paths) > MAX_SOURCES:
            raise ValueError('Select at most 1,000 files or folders.')
        candidate = list(self.roots)
        for value in paths:
            if not isinstance(value, str) or not value or len(value) > 4096 or '\0' in value:
                raise ValueError('Select a valid file or folder.')
            chosen = Path(value).expanduser().absolute()
            path = chosen.resolve()
            if not (path.is_file() or path.is_dir()): raise ValueError('Selected file or folder is no longer available.')
            if path.is_file(): path = local_file(str(chosen))
            if str(path) not in candidate: candidate.append(str(path))
        previous = self.roots, self.prefer_local
        self.roots, self.prefer_local = candidate, True
        try:
            self.save()
        except Exception:
            self.roots, self.prefer_local = previous
            raise

    def remove(self, paths):
        # Forget configured sources only. Never unlink the underlying media.
        previous = list(self.roots)
        self.roots = [p for p in self.roots if p not in set(paths)]
        try: self.save()
        except Exception:
            self.roots = previous
            raise

    def scan(self, cancel=None):
        files = set()
        visited, entries = 0, 0
        def check_cancel():
            if cancel is not None and cancel.is_set(): raise RuntimeError('Local scan cancelled.')
        def include(path):
            check_cancel()
            try:
                resolved = local_file(str(path.absolute()))
            except (OSError, RuntimeError, ValueError): return
            files.add(resolved)
            if len(files) > MAX_LOCAL_TRACKS:
                raise ValueError(f'Local library exceeds {MAX_LOCAL_TRACKS:,} tracks. Choose smaller music folders.')

        for value in self.roots:
            check_cancel()
            root = Path(value)
            if root.is_dir():
                pending = [root]
                while pending:
                    check_cancel()
                    directory = pending.pop()
                    visited += 1
                    if visited > MAX_SCAN_DIRECTORIES:
                        raise ValueError('Local scan exceeds the 100,000-folder safety limit.')
                    try: children = os.scandir(directory)
                    except OSError: continue
                    # Stream entries instead of os.walk's unbounded per-folder
                    # lists. Reject excessive breadth before any metadata probe.
                    with children:
                        for entry in children:
                            check_cancel()
                            entries += 1
                            if entries > MAX_SCAN_ENTRIES:
                                raise ValueError('Local scan exceeds the 1,000,000-entry safety limit.')
                            try: is_dir = entry.is_dir(follow_symlinks=False)
                            except OSError: continue
                            if is_dir:
                                if visited + len(pending) >= MAX_SCAN_DIRECTORIES:
                                    raise ValueError('Local scan exceeds the 100,000-folder safety limit.')
                                pending.append(Path(entry.path))
                            elif Path(entry.name).suffix.lower() in EXTENSIONS: include(Path(entry.path))
            elif root.is_file(): include(root)
        songs, skipped, total_bytes, next_cache = [], 0, 0, {}
        for path in sorted(files):
            check_cancel()
            try:
                stat = path.stat()
                stamp = (stat.st_mtime_ns, stat.st_size)
                cached = self.cache.get(str(path))
                if cached and cached[0] == stamp:
                    item = cached[1]
                else:
                    raw = probe_output(['ffprobe', '-v', 'error', '-protocol_whitelist', 'file',
                                        '-format_whitelist', FORMAT_WHITELIST,
                                        '-show_format', '-show_streams', '-of', 'json', str(path)], cancel=cancel)
                    data = json.loads(raw)
                    if not isinstance(data, dict) or not isinstance(data.get('streams'), list) or not isinstance(data.get('format', {}), dict):
                        raise ValueError('Unreadable audio metadata')
                    audio = next(s for s in data.get('streams', []) if s.get('codec_type') == 'audio')
                    tags = {k.lower(): v for k, v in {**data.get('format', {}).get('tags', {}), **audio.get('tags', {})}.items()}
                    def number(key):
                        try: return int(str(tags.get(key, 0)).split('/')[0])
                        except ValueError: return 0
                    artist = metadata.text(tags.get('album_artist') or tags.get('albumartist') or tags.get('artist'), 'Unknown artist')
                    album = metadata.text(tags.get('album'), metadata.text(path.parent.name, 'Unknown album'))
                    item = {'id': 'local:' + hashlib.sha256(str(path).encode()).hexdigest(), 'source': 'local',
                            'path': str(path), 'title': metadata.text(tags.get('title'), metadata.text(path.stem)), 'artist': artist, 'album': album,
                            'albumId': 'local:' + hashlib.sha256((str(path.parent) + '\0' + album).encode()).hexdigest(),
                            'duration': metadata.number(float(data.get('format', {}).get('duration') or audio.get('duration') or 0)),
                            'track': int(metadata.number(number('track'))), 'disc': int(metadata.number(number('disc')))}
            except (OSError, ValueError, TypeError, AttributeError, OverflowError, RecursionError, StopIteration, subprocess.TimeoutExpired):
                skipped += 1
                continue
            total_bytes += len(json.dumps(item, ensure_ascii=False, allow_nan=False).encode())
            if total_bytes > MAX_LOCAL_BYTES:
                raise ValueError('Local library exceeds the 64 MiB metadata safety limit. Choose smaller music folders.')
            next_cache[str(path)] = (stamp, item)
            songs.append(item)
        # Failed scans keep the previous bounded cache, rather than accumulating
        # partial results on every failed refresh.
        self.cache = next_cache
        songs.sort(key=lambda s: (s['artist'].casefold(), s['album'].casefold(), s['disc'], s['track'], s['title'].casefold()))
        return songs, skipped
