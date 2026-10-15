"""Private named playlists and recent albums/stations; no credentials retained."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import uuid
from playback_store import validate, MAX_SESSION_BYTES, MAX_QUEUE_TRACKS

MAX_PLAYLISTS = 128
MAX_RECENT = 30


def name(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 80 or any(ord(c) < 32 for c in value):
        raise ValueError('Enter a playlist name of 1–80 characters.')
    return value.strip()


class CollectionStore:
    def __init__(self, path=None, memory=False):
        self.path = None if memory else Path(path) if path else Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'omagawd/collections.json'
        self.data = {'playlists': [], 'recent': []}
        self.warning, self.writable = '', True
        if self.path:
            try:
                with self.path.open('rb') as f: raw = f.read(MAX_SESSION_BYTES + 1)
                if len(raw) > MAX_SESSION_BYTES: raise ValueError('Oversized collections')
                self.data = self.clean(json.loads(raw))
            except FileNotFoundError: pass
            except (ValueError, TypeError, RecursionError):
                try:
                    self.path.rename(self.path.with_name(self.path.name + '.damaged-' + uuid.uuid4().hex))
                    self.warning = 'Unreadable playlists were backed up. Saved playlists and recents start empty.'
                except OSError:
                    self.writable = False
                    self.warning = 'Could not back up saved playlists. Saving is disabled; the original is kept.'
            except OSError:
                self.writable = False; self.warning = 'Could not read saved playlists. Check file permissions.'

    @staticmethod
    def clean(data):
        if not isinstance(data, dict): raise ValueError('Invalid saved playlists')
        result, tracks = {}, 0
        for section, maximum in (('playlists', MAX_PLAYLISTS), ('recent', MAX_RECENT)):
            rows = data.get(section, [])
            if not isinstance(rows, list) or len(rows) > maximum: raise ValueError('Too many saved playlists or recents.')
            seen, clean = set(), []
            for row in rows:
                if not isinstance(row, dict) or not isinstance(row.get('id'), str) or not 1 <= len(row['id']) <= 128 or row['id'] in seen:
                    raise ValueError('Invalid playlist identity')
                seen.add(row['id'])
                snapshot = validate(row.get('snapshot'))
                if not snapshot['queue']: raise ValueError('A saved playlist needs at least one track.')
                tracks += len(snapshot['queue'])
                if tracks > MAX_QUEUE_TRACKS: raise ValueError('Saved playlists exceed 100,000 total tracks.')
                clean.append({'id': row['id'], 'name': name(row.get('name')), 'snapshot': snapshot})
            result[section] = clean
        return result

    def save(self, data):
        if not self.writable: raise RuntimeError('Saved playlists are not writable; the original has been kept.')
        data = self.clean(data)
        raw = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
        if len(raw) > MAX_SESSION_BYTES: raise ValueError('Saved playlists exceed the 64 MiB safety limit.')
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=self.path.parent, prefix='.collections-', delete=False) as f:
                    temporary = f.name; f.write(raw); f.flush(); os.fsync(f.fileno())
                os.replace(temporary, self.path)
            finally:
                if temporary and os.path.exists(temporary): os.unlink(temporary)
        self.data = data

    def summary(self):
        return {section: [{'id': r['id'], 'name': r['name'], 'count': len(r['snapshot']['queue']),
                           'source': 'mixed' if len({t.get('source', 'jellyfin') for t in r['snapshot']['queue']}) > 1 else r['snapshot']['queue'][0].get('source', 'jellyfin')}
                          for r in rows] for section, rows in self.data.items()}

    def add(self, title, snapshot):
        title = name(title)
        if any(r['name'].casefold() == title.casefold() for r in self.data['playlists']):
            raise ValueError('That playlist name is already used. Choose another name.')
        row = {'id': uuid.uuid4().hex, 'name': title, 'snapshot': snapshot}
        self.save(dict(self.data, playlists=self.data['playlists'] + [row]))
        return row['id']

    def rename(self, key, title):
        title = name(title)
        if any(r['id'] != key and r['name'].casefold() == title.casefold() for r in self.data['playlists']):
            raise ValueError('That playlist name is already used.')
        if not any(r['id'] == key for r in self.data['playlists']): raise ValueError('Choose a saved playlist.')
        self.save(dict(self.data, playlists=[dict(r, name=title) if r['id'] == key else r for r in self.data['playlists']]))

    def remove(self, key):
        self.save(dict(self.data, playlists=[r for r in self.data['playlists'] if r['id'] != key]))

    def get(self, section, key):
        if section not in ('playlists', 'recent'): raise ValueError('Choose a saved playlist or recent item.')
        row = next((r for r in self.data[section] if r['id'] == key), None)
        if row is None: raise ValueError('That saved item is no longer available.')
        return validate(row['snapshot'])

    def recent(self, group, title, snapshot):
        key = hashlib.sha256(group.encode()).hexdigest()
        # Album labels can exceed a playlist name; trim only this display label.
        title = ''.join(c for c in title if ord(c) >= 32)[:80].strip() or 'Recently played'
        row = {'id': key, 'name': title, 'snapshot': snapshot}
        self.save(dict(self.data, recent=([row] + [r for r in self.data['recent'] if r['id'] != key])[:MAX_RECENT]))

    def clear_recent(self):
        self.save(dict(self.data, recent=[]))
