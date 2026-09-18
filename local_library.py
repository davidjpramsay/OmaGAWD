"""Persist explicitly chosen local sources and index audio tags with ffprobe."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import uuid

EXTENSIONS = {'.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.aiff', '.aif', '.alac', '.wma', '.ape', '.wv', '.m4b'}


class LocalLibrary:
    def __init__(self, path=None):
        self.path = Path(path) if path else Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'omagawd/local.json'
        self.roots, self.prefer_local, self.cache = [], False, {}
        self.warning = ''
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                if not isinstance(data, dict) or not isinstance(data.get('paths', []), list):
                    raise ValueError('Invalid local settings')
                self.roots = [str(Path(p).expanduser().resolve()) for p in data.get('paths', []) if isinstance(p, str)]
                self.prefer_local = bool(data.get('preferLocal', False))
            except (OSError, ValueError, RuntimeError):
                backup = self.path.with_name(self.path.name + '.damaged-' + uuid.uuid4().hex)
                try:
                    shutil.copy2(self.path, backup)
                    self.warning = 'Local settings were unreadable. A backup was kept; add your music sources again.'
                except OSError:
                    self.warning = 'Local settings could not be read or backed up. Check file permissions.'
                    self.path = None  # Never overwrite settings we could not preserve.
                self.roots, self.prefer_local = [], False

    def save(self):
        if self.path is None:
            raise RuntimeError('Local settings are not writable. Check file permissions and reopen the player.')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix('.tmp')
        temp.write_text(json.dumps({'paths': self.roots, 'preferLocal': self.prefer_local}))
        temp.replace(self.path)

    def add(self, paths):
        for value in paths:
            path = Path(value).expanduser().resolve()
            if not path.exists(): raise ValueError('Selected file or folder is no longer available.')
            if str(path) not in self.roots: self.roots.append(str(path))
        self.prefer_local = True
        self.save()

    def remove(self, paths):
        # Forget configured sources only. Never unlink the underlying media.
        previous = list(self.roots)
        self.roots = [p for p in self.roots if p not in set(paths)]
        try: self.save()
        except Exception:
            self.roots = previous
            raise

    def scan(self):
        files = set()
        for value in self.roots:
            root = Path(value)
            if root.is_dir():
                for directory, _, names in os.walk(root, followlinks=False):
                    for name in names:
                        path = Path(directory) / name
                        if path.suffix.lower() in EXTENSIONS: files.add(path.resolve())
            elif root.is_file(): files.add(root)
        songs, skipped = [], 0
        for path in sorted(files):
            try:
                stat = path.stat()
                stamp = (stat.st_mtime_ns, stat.st_size)
                cached = self.cache.get(str(path))
                if cached and cached[0] == stamp:
                    item = cached[1]
                else:
                    result = subprocess.run(['ffprobe', '-v', 'error', '-protocol_whitelist', 'file',
                                             '-show_format', '-show_streams', '-of', 'json', str(path)],
                                            capture_output=True, text=True, timeout=10)
                    if result.returncode: raise ValueError('Unreadable audio')
                    data = json.loads(result.stdout)
                    audio = next(s for s in data.get('streams', []) if s.get('codec_type') == 'audio')
                    tags = {k.lower(): v for k, v in {**data.get('format', {}).get('tags', {}), **audio.get('tags', {})}.items()}
                    def number(key):
                        try: return int(str(tags.get(key, 0)).split('/')[0])
                        except ValueError: return 0
                    artist = tags.get('album_artist') or tags.get('albumartist') or tags.get('artist') or 'Unknown artist'
                    album = tags.get('album') or path.parent.name or 'Unknown album'
                    item = {'id': 'local:' + hashlib.sha256(str(path).encode()).hexdigest(), 'source': 'local',
                            'path': str(path), 'title': tags.get('title') or path.stem, 'artist': artist, 'album': album,
                            'albumId': 'local:' + hashlib.sha256((str(path.parent) + '\0' + album).encode()).hexdigest(),
                            'duration': float(data.get('format', {}).get('duration') or audio.get('duration') or 0),
                            'track': number('track'), 'disc': number('disc')}
                    self.cache[str(path)] = (stamp, item)
                songs.append(item)
            except (OSError, ValueError, StopIteration, subprocess.TimeoutExpired): skipped += 1
        self.cache = {str(p): self.cache[str(p)] for p in files if str(p) in self.cache}
        songs.sort(key=lambda s: (s['artist'].casefold(), s['album'].casefold(), s['disc'], s['track'], s['title'].casefold()))
        return songs, skipped
