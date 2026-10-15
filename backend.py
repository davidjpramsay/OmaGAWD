#!/usr/bin/env python3
"""OmaGAWD: JSON-lines bridge. Passwords stay in memory; reconnect tokens use the desktop keyring."""
import json
import math
import os
import random
import signal
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from session_store import SessionStore
from spectrum import filter_graph, level
from stream_proxy import StreamProxy
from process_guard import guard_parent
from playback_store import identity
import radio_library as radio
from radio_store import RadioStore
from radio_browser import RadioBrowser, PAGE_SIZE, MAX_RESULTS
from clipboard_io import read_clipboard
from bounded_process import run_bounded
import metadata
import jellyfin_playlists as hosted
from media_policy import FORMAT_WHITELIST, local_file, demux_options
from playback_store import MAX_QUEUE_TRACKS, MAX_SESSION_BYTES
from collection_store import CollectionStore
from local_music_window import LocalMusicWindow

# Live EBU R128 measurement: modest music target, true-peak headroom, wide
# loudness range. Explicit resampling avoids loudnorm's 192 kHz output reaching
# the audio device. This is optional playback processing, never a file rewrite.
NORMALIZATION_FILTER = '@normalize:lavfi=[loudnorm=I=-18:TP=-1.5:LRA=50:linear=false:dual_mono=true,aresample=48000]'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


MAX_API_BYTES = 8 * 1024 * 1024
MAX_LIBRARY_BYTES = 64 * 1024 * 1024
MAX_LIBRARY_TRACKS = 100000
MAX_NUMBER_TICKS = 2**31 * 10000000
MAX_IPC_BYTES = 4 * 1024 * 1024


def read_api_body(response):
    """Bound decoded HTTP bodies regardless of framing or declared size."""
    for declared in response.headers.get_all('Content-Length', []):
        try:
            if not declared.isascii() or not declared.isdecimal():
                raise ValueError()
            length = int(declared)
        except ValueError:
            raise ValueError('Jellyfin sent an invalid response length.') from None
        if length > MAX_API_BYTES:
            raise ValueError('Jellyfin API response exceeds the 8 MiB safety limit.')
    if response.headers.get('Content-Encoding', 'identity').lower() != 'identity':
        raise ValueError('Jellyfin sent an unsupported encoded API response.')
    data = bytearray()
    deadline = time.monotonic() + 30
    while True:
        if time.monotonic() > deadline:
            raise ValueError('Jellyfin API response took too long.')
        # One extra byte distinguishes a full valid response from an oversized one.
        chunk = response.read1(min(65536, MAX_API_BYTES + 1 - len(data)))
        if time.monotonic() > deadline:
            raise ValueError('Jellyfin API response took too long.')
        if not chunk:
            return data
        data.extend(chunk)
        if len(data) > MAX_API_BYTES:
            raise ValueError('Jellyfin API response exceeds the 8 MiB safety limit.')


def finite_json_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError('Jellyfin sent a non-finite JSON number.')
    return number


def invalid_json_constant(value):
    raise ValueError('Jellyfin sent a non-finite JSON number.')


class Jellyfin:
    def __init__(self, url):
        url = url.strip().rstrip('/')
        p = urllib.parse.urlsplit(url)
        if p.scheme not in ('https', 'http') or not p.hostname or p.username or p.password or p.query or p.fragment:
            raise ValueError('Enter an http(s) server URL, including any /jellyfin base path.')
        self.url, self.token, self.user = url, '', ''
        self.device = str(uuid.uuid4())
        self.response_bytes = 0
        self.opener = urllib.request.build_opener(NoRedirect)

    def authorization(self):
        values = {'Client': 'OmaGAWD', 'Device': 'Omarchy', 'DeviceId': self.device, 'Version': '0.1.0'}
        if self.token:
            values['Token'] = self.token
        return 'MediaBrowser ' + ', '.join(k + '="' + urllib.parse.quote(v, safe='') + '"' for k, v in values.items())

    def request(self, path, params=None, body=None, method=None):
        url = self.url + path
        if params:
            url += '?' + urllib.parse.urlencode(params)
        headers = {'Authorization': self.authorization(), 'Content-Type': 'application/json', 'Accept-Encoding': 'identity'}
        request = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
        with self.opener.open(request, timeout=20) as response:
            raw = read_api_body(response)
            self.response_bytes = len(raw)
            try:
                data = json.loads(raw, parse_constant=invalid_json_constant, parse_float=finite_json_float) if raw else {}
            except (RecursionError, UnicodeError):
                raise ValueError('Jellyfin sent invalid or excessively nested JSON.') from None
            if not isinstance(data, dict):
                raise ValueError('Jellyfin API response must be a JSON object.')
            return data

    def login(self, username, password):
        data = self.request('/Users/AuthenticateByName', body={'Username': username, 'Pw': password})
        token, user = data.get('AccessToken'), data.get('User')
        if not isinstance(token, str) or not 0 < len(token) <= 4096 or not isinstance(user, dict) or not isinstance(user.get('Id'), str) or not 0 < len(user['Id']) <= 512:
            raise ValueError('Jellyfin returned an invalid sign-in response.')
        self.token, self.user = token, user['Id']

    def libraries(self):
        data = self.request('/UserViews', {'UserId': self.user})
        rows = data.get('Items', [])
        if not isinstance(rows, list): raise ValueError('Jellyfin returned invalid libraries.')
        result = []
        for row in rows:
            if not isinstance(row, dict): raise ValueError('Jellyfin returned an invalid library.')
            if row.get('CollectionType') != 'music': continue
            if not isinstance(row.get('Id'), str) or not 0 < len(row['Id']) <= 512:
                raise ValueError('Jellyfin returned an invalid library identity.')
            result.append({'id': row['Id'], 'name': metadata.text(row.get('Name'), 'Music')})
        return result

    def songs(self, folder):
        result, seen, total_bytes = [], set(), 0
        while True:
            params = {'Recursive': 'true', 'IncludeItemTypes': 'Audio', 'UserId': self.user,
                      'SortBy': 'AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName', 'SortOrder': 'Ascending',
                      'StartIndex': len(result), 'Limit': 500}
            if folder:
                params['ParentId'] = folder
            data = self.request('/Items', params)
            total_bytes += self.response_bytes
            batch = data.get('Items', [])
            if not isinstance(batch, list) or len(batch) > 500:
                raise ValueError('Jellyfin returned an invalid or oversized library page.')
            if total_bytes > MAX_LIBRARY_BYTES or len(result) + len(batch) > MAX_LIBRARY_TRACKS:
                raise ValueError('Jellyfin library exceeds the safety limit (100,000 tracks / 64 MiB).')
            for i in batch:
                if not isinstance(i, dict) or not isinstance(i.get('Id'), str) or not 0 < len(i['Id']) <= 512:
                    raise ValueError('Jellyfin returned an invalid track.')
                if i['Id'] in seen:
                    raise ValueError('Jellyfin repeated tracks while paging. Refresh the library and try again.')
                seen.add(i['Id'])
                result.append(hosted.music_row(i))
            total = data.get('TotalRecordCount', len(result))
            if type(total) is not int or not 0 <= total <= MAX_LIBRARY_TRACKS:
                raise ValueError('Jellyfin returned an invalid library size.')
            if not batch or len(result) >= total:
                return result

    def stream(self, item):
        # mpv decodes the original audio; no lossy transcoding or token in URL.
        return self.url + '/Audio/' + urllib.parse.quote(item, safe='') + '/stream?static=true'


class Mpv:
    supports_gapless = True
    def __init__(self, callback):
        self.callback, self.lock = callback, threading.Lock()
        self.closing = False
        self.close_lock = threading.Lock()
        self.temp = tempfile.TemporaryDirectory(prefix='omaamp-')
        path = self.temp.name + '/mpv.sock'
        meter_path = self.temp.name + '/spectrum.pipe'
        os.mkfifo(meter_path, 0o600)
        self.meter_fd = os.open(meter_path, os.O_RDWR | os.O_NONBLOCK)
        self.meter_graph = '@meter:lavfi=[' + filter_graph(meter_path) + ']'
        self.meter_enabled = False
        self.meter_stop = threading.Event()
        self.spectrum = [0.0] * 16
        self.meter_thread = threading.Thread(target=self.read_spectrum, daemon=True)
        self.meter_thread.start()
        self.proxy = None
        self.proc = subprocess.Popen(['/usr/bin/python3', os.path.join(os.path.dirname(__file__), 'process_guard.py'), str(os.getpid()), 'mpv', '--no-config', '--idle=yes', '--no-video', '--no-terminal',
                                      '--audio-display=no', '--tls-verify=yes', '--ytdl=no', '--load-unsafe-playlists=no',
                                      '--demuxer=lavf', '--access-references=no', '--autoload-files=no', '--load-scripts=no',
                                      '--demuxer-lavf-o=format_whitelist=[' + FORMAT_WHITELIST + ']',
                                      '--gapless-audio=weak', '--prefetch-playlist=yes', '--replaygain=no',
                                      '--input-ipc-server=' + path],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.sock = socket.socket(socket.AF_UNIX)
        for _ in range(100):
            try:
                self.sock.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.proc.poll() is not None:
                    self.close()
                    raise RuntimeError('mpv could not start.')
                time.sleep(.03)
        else:
            self.close()
            raise RuntimeError('mpv did not become ready.')
        threading.Thread(target=self.read, daemon=True).start()
        for n, prop in enumerate(['time-pos', 'duration', 'pause', 'idle-active', 'audio-bitrate', 'metadata', 'paused-for-cache']):
            self.send('observe_property', n, prop)

    def load(self, url, headers, start=0):
        if headers:
            if self.proxy is None:
                self.proxy = StreamProxy()
            url = self.proxy.stream(url, {'Authorization': headers[0].split(': ', 1)[1]})
        elif self.proxy:
            self.proxy.route = None
            self.proxy.next_route = None
        self.send('set_property', 'http-header-fields', [])
        if start > 0:
            self.send('loadfile', url, 'replace', -1, {'start': str(start)})
        else:
            self.send('loadfile', url, 'replace')

    def clear_next(self):
        self.send('playlist-clear')
        if self.proxy: self.proxy.next_route = None

    def append_next(self, url, headers, local):
        if headers:
            if self.proxy is None: self.proxy = StreamProxy()
            url = self.proxy.prefetch(url, {'Authorization': headers[0].split(': ', 1)[1]})
        options = demux_options(local)
        encoded = ','.join(k + '=[' + v + ']' for k, v in options.items())
        self.send('loadfile', url, 'append', -1, {'demuxer-lavf-o': encoded})

    def advance_prefetch(self):
        if self.proxy: self.proxy.advance()

    def send(self, *command):
        with self.lock:
            self.sock.sendall((json.dumps({'command': command}) + '\n').encode())

    def set_meter(self, enabled):
        if enabled == self.meter_enabled:
            return
        self.send('af', 'add' if enabled else 'remove', self.meter_graph if enabled else '@meter')
        self.meter_enabled = enabled
        self.spectrum = [0.0] * 16

    def query_meter(self):
        self.callback({'request_id': 900, 'spectrum': list(self.spectrum)})

    def read_spectrum(self):
        pending = ''
        frame = [0.0] * 16
        while not self.meter_stop.is_set():
            if not select.select([self.meter_fd], [], [], .5)[0]:
                continue
            try:
                raw = os.read(self.meter_fd, 65536)
            except BlockingIOError:
                continue
            pending += raw.decode('utf-8', errors='replace')
            lines = pending.split('\n')
            pending = lines.pop()
            for line in lines:
                if line.startswith('lavfi.astats.') and '.RMS_level=' in line:
                    key, value = line.split('=', 1)
                    try:
                        index = int(key.split('.')[2]) - 1
                    except ValueError:
                        continue
                    if 0 <= index < 16:
                        frame[index] = level(value)
                        if index == 15:
                            if self.meter_enabled:
                                self.spectrum = frame[:]

    def read(self):
        try:
            with self.sock.makefile('rb') as stream:
                while True:
                    line = stream.readline(MAX_IPC_BYTES + 1)
                    if not line: break
                    if len(line) > MAX_IPC_BYTES: raise ValueError('Playback metadata exceeds the safety limit.')
                    event = json.loads(line)
                    if not isinstance(event, dict): raise ValueError('Invalid playback event.')
                    self.callback(event)
        except (OSError, ValueError, RecursionError):
            pass
        finally:
            if not self.closing:
                self.callback({'event': 'engine-exited'})

    def close(self):
        with self.close_lock:
            if self.closing:
                return
            self.closing = True
        if getattr(self, 'proc', None):
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if getattr(self, 'sock', None):
            self.sock.close()
        if getattr(self, 'proxy', None):
            self.proxy.close()
        self.meter_stop.set()
        self.meter_thread.join(timeout=1)
        os.close(self.meter_fd)
        self.temp.cleanup()


class Player:
    def __init__(self, emit, mpv_factory=Mpv, store=None, local=None, preferences=None, playback_store=None, radio_store=None, radio_browser=None, collections=None):
        self.emit, self.mpv_factory = emit, mpv_factory
        self.radios = radio_store or RadioStore(memory=True)
        self.radio_browser = radio_browser or RadioBrowser()
        self.radio_results = []
        self.radio_generation = 0
        self.radio_future = None
        self.radio_work = ThreadPoolExecutor(max_workers=1)
        self.clipboard_work = ThreadPoolExecutor(max_workers=1)
        self.clipboard_future = None
        self.closing = threading.Event()
        self.collections = collections or CollectionStore(memory=True)
        self.collection_work = ThreadPoolExecutor(max_workers=1)
        self.collection_future = None
        self.hosted_work = ThreadPoolExecutor(max_workers=1)
        self.hosted_pending = None
        self.hosted_active = self.hosted_mutating = False
        self.hosted_generation = 0
        self.hosted_playlists = []
        self.playback_revision = 0
        self.pending_recent, self.recent_running = None, False
        self.last_recent_group = None
        self.prepared_next, self.awaiting_next = None, None
        self.gapless, self.normalization, self.radio_status = True, False, 'stopped'
        self.file_loaded, self.cache_paused = False, False
        self.keep_recent = True
        self.local = local
        self.local_window = None
        self.preferences = preferences
        self.reduce_motion = False
        self.visible = False
        self.playback_store = playback_store
        self.queue_identity = None
        self.session_pending = False
        self.session_folder = None
        self.radio_title = ""
        self.checkpoint_at = time.monotonic()
        self.session_warning = False
        self.store, self.remembered = store, False
        self.username, self.folder = "", ""
        self.lock = threading.RLock()
        self.client, self.mpv = None, None
        self.engine_token = None
        self.songs, self.queue = [], []
        self.index, self.position, self.duration = -1, 0, 0
        self.paused, self.idle, self.shuffle, self.repeat = True, True, False, 'off'
        self.volume, self.bitrate, self.generation = 70, 0, 0
        if preferences:
            saved = preferences.load()
            self.volume, self.shuffle, self.repeat = saved['volume'], saved['shuffle'], saved['repeat']
            self.reduce_motion = saved['reduceMotion']
            self.gapless, self.normalization = saved.get('gapless', True), saved.get('normalization', False)
            self.keep_recent = saved.get('keepRecent', True)
        if playback_store:
            saved = playback_store.load()
            if saved:
                self.queue, self.index, self.position = saved['queue'], saved['index'], saved['position']
                self.duration = self.queue[self.index]['duration'] if self.index >= 0 else 0
                self.queue_identity, self.session_folder = saved['library'], saved['folder']
                self.session_pending = not saved['idle'] and self.index >= 0
                self.idle, self.paused = saved['idle'], True
                if self.local:
                    self.local.prefer_local = saved['folder'] == 'local'
        self.work = ThreadPoolExecutor(max_workers=1)

    def session_snapshot(self):
        folder = 'local' if self.local and self.local.prefer_local else self.folder or self.session_folder or 'local'
        return {'queue': [dict(row) for row in self.queue], 'index': self.index, 'position': self.position,
                'idle': self.idle, 'folder': folder, 'library': self.queue_identity if any(radio.remote(s) for s in self.queue) else None}

    def checkpoint(self):
        if not self.playback_store: return
        try:
            error = self.playback_store.take_error()
            if self.playback_store.save(self.session_snapshot()): self.checkpoint_at = time.monotonic()
            if error: raise error
        except (OSError, ValueError):
            if not self.session_warning:
                self.emit({'type': 'error', 'message': 'Could not save the playback session. Check file permissions or free space.'})
                self.session_warning = True

    def state(self):
        if self.idle: self.radio_title = ''
        if not self.paused and not self.idle and time.monotonic() - self.checkpoint_at >= 5:
            self.checkpoint()
        if self.mpv:
            self.mpv.set_meter(self.visible and not self.idle and not self.paused)
        self.emit({'type': 'state', 'queue': self.queue, 'index': self.index, 'position': self.position,
                   'duration': self.duration, 'paused': self.paused, 'idle': self.idle,
                   'shuffle': self.shuffle, 'repeat': self.repeat, 'volume': self.volume, 'bitrate': self.bitrate, 'reduceMotion': self.reduce_motion, 'radioTitle': self.radio_title,
                   'gapless': self.gapless, 'normalization': self.normalization, 'keepRecent': self.keep_recent, 'radioStatus': self.radio_status})

    def discard_engine(self):
        self.prepared_next, self.awaiting_next = None, None
        old, self.mpv = self.mpv, None
        self.engine_token = None
        if old:
            old.close()

    def engine(self):
        if self.mpv and getattr(self.mpv, 'proc', None) and self.mpv.proc.poll() is not None:
            self.discard_engine()
        if self.mpv is None:
            token = self.engine_token = object()
            def receive(event):
                with self.lock:
                    if self.engine_token is token:
                        self.event(event)
            self.mpv = self.mpv_factory(receive)
            self.mpv.send('set_property', 'volume', self.volume)
            self.mpv.send('set_property', 'options/gapless-audio', 'weak' if self.gapless else 'no')
            if self.normalization: self.mpv.send('af', 'add', NORMALIZATION_FILTER)
        return self.mpv

    def is_radio(self):
        return 0 <= self.index < len(self.queue) and self.queue[self.index].get('source') == 'radio'

    def upcoming(self):
        if not 0 <= self.index < len(self.queue): return None
        if self.repeat == 'one': return self.index
        if self.shuffle and len(self.queue) > 1:
            return random.choice([i for i in range(len(self.queue)) if i != self.index])
        target = self.index + 1
        return target if target < len(self.queue) else 0 if self.repeat == 'all' else None

    def track_stream(self, track):
        if track.get('source') == 'local': return str(local_file(track.get('path'))), []
        if track.get('source') == 'radio': return radio.stream(track if 'radioUrl' in track else track['id']), []
        if self.client and self.queue_identity == identity(self.client):
            return self.client.stream(track['id']), ['Authorization: ' + self.client.authorization()]
        raise ValueError('Reconnect to this playlist’s Jellyfin account.')

    def prepare_next(self):
        if not self.mpv or not getattr(self.mpv, 'supports_gapless', False): return
        if self.awaiting_next: return
        target = self.upcoming() if self.gapless and not self.is_radio() and not self.idle else None
        if self.prepared_next and self.shuffle and self.repeat != 'one':
            target = next((i for i, row in enumerate(self.queue) if row['key'] == self.prepared_next and i != self.index), target)
        if target is not None and self.queue[target].get('source') == 'radio': target = None
        key = self.queue[target]['key'] if target is not None else None
        if key == self.prepared_next: return
        self.mpv.clear_next(); self.prepared_next = None
        if target is not None:
            try:
                row = self.queue[target]; url, headers = self.track_stream(row)
                self.mpv.append_next(url, headers, row.get('source') == 'local')
                self.prepared_next = key
            except (OSError, RuntimeError, ValueError): pass

    def emit_collections(self):
        self.emit(dict(type='collections', **self.collections.summary()))

    def submit_hosted(self, command):
        client = self.client
        request = command.get('request', 0)
        if type(request) is not int or not 0 <= request <= 2**53: raise ValueError('Invalid playlist request.')
        if not client or not client.user or not client.token:
            self.emit({'type': 'hosted_error', 'request': request, 'message': 'Connect to Jellyfin to use server playlists.'})
            return
        mutating = command['cmd'] in ('hosted_create', 'hosted_load', 'hosted_delete')
        if self.hosted_active and (mutating or self.hosted_mutating):
            self.emit({'type': 'hosted_error', 'request': request, 'message': 'A playlist request is still running. Try again in a moment.'})
            return
        if command['cmd'] == 'hosted_delete':
            key = hosted.item_id(command.get('id'))
            if command.get('confirmed') is not True or not any(row['id'] == key for row in self.hosted_playlists):
                self.emit({'type': 'hosted_error', 'request': request, 'message': 'Select a Jellyfin playlist and confirm its deletion first.'})
                return
        rows = [dict(row) for row in self.queue] if command['cmd'] == 'hosted_create' else None
        if rows is not None and self.queue_identity != identity(client):
            self.emit({'type': 'hosted_error', 'request': request, 'message': 'The queue must belong to the connected Jellyfin account.'})
            return
        # Independent clients avoid racing response-byte budgets with library work.
        captured = Jellyfin(client.url)
        captured.token, captured.user, captured.device = client.token, client.user, client.device
        self.hosted_generation += 1
        self.hosted_pending = (dict(command), captured, client, self.hosted_generation, self.playback_revision, rows)
        self.hosted_mutating = mutating
        self.emit({'type': 'hosted_busy', 'request': request, 'value': True, 'action': 'write' if mutating else 'read'})
        if not self.hosted_active:
            self.hosted_active = True
            self.hosted_work.submit(self.drain_hosted)

    def drain_hosted(self):
        while True:
            with self.lock:
                if self.hosted_pending is None or self.closing.is_set():
                    self.hosted_active = self.hosted_mutating = False
                    return
                command, client, owner, generation, revision, rows = self.hosted_pending
                self.hosted_pending = None
            request, created = command.get('request', 0), False
            def current():
                with self.lock:
                    return not self.closing.is_set() and generation == self.hosted_generation and self.client is owner
            try:
                if not current(): raise hosted.Cancelled()
                cmd = command['cmd']
                if cmd == 'hosted_list':
                    result = hosted.catalog(client, lambda: not current())
                    with self.lock:
                        if current():
                            self.hosted_playlists = result
                            self.emit({'type': 'hosted_playlists', 'request': request, 'playlists': result})
                elif cmd == 'hosted_delete':
                    key = hosted.item_id(command.get('id'))
                    hosted.delete(client, key, lambda: not current())
                    with self.lock:
                        if not current(): raise hosted.Cancelled()
                        self.hosted_playlists = [row for row in self.hosted_playlists if row['id'] != key]
                        self.emit({'type': 'hosted_playlists', 'request': request, 'playlists': self.hosted_playlists})
                        self.emit({'type': 'hosted_items', 'request': request, 'id': '', 'songs': []})
                        self.emit({'type': 'hosted_deleted', 'request': request, 'id': key})
                else:
                    key = command.get('id')
                    if cmd == 'hosted_create':
                        entry = hosted.create(client, command.get('name'), rows, lambda: not current())
                        created, key = True, entry['id']
                        with self.lock:
                            if not current(): raise hosted.Cancelled()
                            self.hosted_playlists = ([entry] + [r for r in self.hosted_playlists if r['id'] != key])[:hosted.MAX_PLAYLISTS]
                            self.emit({'type': 'hosted_playlists', 'request': request, 'playlists': self.hosted_playlists})
                            self.emit({'type': 'hosted_created', 'request': request, 'id': key, 'name': entry['name']})
                    result = hosted.tracks(client, key, lambda: not current())
                    with self.lock:
                        if not current(): raise hosted.Cancelled()
                        if cmd == 'hosted_load':
                            if revision != self.playback_revision:
                                raise ValueError('Playlist load cancelled because playback changed.')
                            if not result: raise ValueError('This Jellyfin playlist is empty. Your queue is unchanged.')
                            index = command.get('index', 0)
                            if type(index) is not int or not 0 <= index < len(result): raise ValueError('Choose a playlist song.')
                            queue = [dict(row, key=uuid.uuid4().hex) for row in result]
                            if not self.queue_fits(queue): raise ValueError('This playlist exceeds the queue safety limit.')
                            self.discard_engine()
                            self.queue, self.queue_identity = queue, identity(owner)
                            self.index, self.position = index, 0
                            self.duration, self.idle, self.paused, self.session_pending = queue[index]['duration'], True, True, False
                            self.radio_status = 'stopped'
                            self.playback_revision += 1
                            if command.get('play') is True: self.play(index)
                            self.checkpoint(); self.state()
                        self.emit({'type': 'hosted_items', 'request': request, 'id': key, 'songs': result})
                        if created:
                            self.hosted_playlists = [dict(r, count=len(result)) if r['id'] == key else r for r in self.hosted_playlists]
                            self.emit({'type': 'hosted_playlists', 'request': request, 'playlists': self.hosted_playlists})
            except hosted.Cancelled: pass
            except Exception as exc:
                if isinstance(exc, urllib.error.HTTPError):
                    status = exc.code; exc.close()
                    message = 'Jellyfin denied playlist access. Check this account’s permissions.' if status in (401, 403) else 'This Jellyfin playlist is no longer available.' if status == 404 else 'Jellyfin could not complete the playlist request.'
                    if command['cmd'] == 'hosted_create' and status not in (401, 403, 400, 422):
                        message += ' Check Jellyfin before retrying; the playlist may already exist.'
                    if command['cmd'] == 'hosted_delete' and status not in (401, 403, 400, 422, 404):
                        message += ' Refresh the list before trying to delete it again; it may already be gone.'
                elif isinstance(exc, (hosted.CreationUncertain, hosted.DeletionUncertain)): message = str(exc)
                elif isinstance(exc, ValueError): message = str(exc) if not isinstance(exc, json.JSONDecodeError) else 'Jellyfin returned invalid playlist data.'
                else: message = 'Could not reach Jellyfin. If you were creating a playlist, check Jellyfin before retrying; it may already exist.'
                if created: message = 'Playlist created, but its tracks could not be loaded. Open it again to retry.'
                with self.lock:
                    if current(): self.emit({'type': 'hosted_error', 'request': request, 'message': message})
            finally:
                with self.lock:
                    if current(): self.emit({'type': 'hosted_busy', 'request': request, 'value': False, 'action': ''})

    def clear_hosted(self):
        self.hosted_generation += 1
        self.hosted_pending = None
        self.hosted_playlists = []
        self.emit({'type': 'hosted_reset'})

    def remember_current(self):
        if self.closing.is_set() or not self.keep_recent or not 0 <= self.index < len(self.queue): return
        track = self.queue[self.index]
        if radio.remote(track) and (not self.client or not self.client.user): return
        remote_id = identity(self.client) if radio.remote(track) else None
        group = json.dumps([track.get('source', 'jellyfin'), remote_id, track['id'] if self.is_radio() else track.get('albumId') or track['id']], sort_keys=True)
        if group == self.last_recent_group: return
        self.last_recent_group = group
        rows = [track] if self.is_radio() else [r for r in self.songs if r.get('albumId') and r.get('albumId') == track.get('albumId') and r.get('source') == track.get('source')]
        if not rows: rows = [r for r in self.queue if r.get('albumId') and r.get('albumId') == track.get('albumId') and r.get('source') == track.get('source')] or [track]
        snapshot = {'queue': [dict(r, key=uuid.uuid4().hex) for r in rows], 'index': 0, 'position': 0, 'idle': True,
                    'folder': self.session_snapshot()['folder'], 'library': remote_id}
        title = track['title'] if self.is_radio() else track['artist'] + ' / ' + track['album']
        self.pending_recent = (group, title, snapshot)
        if not self.recent_running:
            self.recent_running = True
            self.collection_work.submit(self.flush_recent)

    def flush_recent(self):
        while True:
            with self.lock:
                if self.pending_recent is None:
                    self.recent_running = False; return
                group, title, snapshot = self.pending_recent
                self.pending_recent = None
            try:
                self.collections.recent(group, title, snapshot)
                with self.lock: self.emit_collections()
            except (OSError, ValueError, RuntimeError):
                with self.lock: self.emit({'type': 'error', 'message': 'Recently played could not be saved; playback continues.'})
            with self.lock:
                if self.pending_recent is not None and not self.closing.is_set():
                    # Yield to explicit playlist edits, retaining only the newest
                    # pending recent item instead of growing an unbounded queue.
                    try:
                        self.collection_work.submit(self.flush_recent)
                        return
                    except RuntimeError: pass  # Shutdown drains the final item.

    def collection_command(self, c, captured):
        try:
            cmd = c['cmd']
            if cmd == 'playlist_save': self.collections.add(c.get('name'), captured)
            elif cmd == 'playlist_rename': self.collections.rename(c.get('id'), c.get('name'))
            elif cmd == 'playlist_delete': self.collections.remove(c.get('id'))
            elif cmd == 'recent_clear': self.collections.clear_recent()
            with self.lock: self.emit_collections()
        except (OSError, ValueError, RuntimeError) as exc:
            with self.lock: self.emit({'type': 'error', 'message': str(exc) if isinstance(exc, (ValueError, RuntimeError)) else 'Saved playlists could not be written.'})

    def load_collection(self, c):
        snapshot = self.collections.get(c.get('section', 'playlists'), c.get('id'))
        if snapshot['library'] and snapshot['library'] != identity(self.client):
            raise ValueError('Connect to this playlist’s Jellyfin account first. Your current queue is unchanged.')
        if not self.queue_fits(snapshot['queue']): return
        self.discard_engine()
        self.queue = [dict(row, key=uuid.uuid4().hex) for row in snapshot['queue']]
        self.queue_identity = snapshot['library']
        self.index, self.position = 0, 0
        self.duration, self.idle, self.paused, self.session_pending = self.queue[0]['duration'], True, True, False
        self.radio_status = 'stopped'
        if c.get('play') is True: self.play(0)

    def load_radio(self):
        self.songs = [dict(row) for row in self.radios.rows]
        self.folder = self.session_folder = 'radio'
        if self.local: self.local.prefer_local = False
        self.emit({'type': 'library', 'songs': self.songs, 'folder': 'radio'})
        self.checkpoint()

    def event(self, event):
        with self.lock:
            if event.get('event') == 'start-file' and self.awaiting_next:
                key, self.awaiting_next = self.awaiting_next, None
                self.prepared_next = None
                index = next((i for i, row in enumerate(self.queue) if row['key'] == key), -1)
                if index < 0:
                    self.mpv.send('stop'); self.idle, self.paused = True, True
                    self.state(); return
                self.index, self.position, self.duration = index, 0, self.queue[index]['duration']
                self.file_loaded, self.cache_paused = False, False
                # mpv keeps its pause property when advancing its playlist.
                # Preserve a pause requested between EOF and this start event.
                self.bitrate, self.idle = 0, False
                self.mpv.advance_prefetch()
                self.checkpoint(); self.state()
            elif event.get('event') == 'file-loaded':
                self.idle = False
                self.file_loaded = True
                if self.is_radio(): self.radio_status = 'paused' if self.paused else 'buffering' if self.cache_paused else 'playing'
                self.remember_current(); self.prepare_next(); self.state()
            elif event.get('event') == 'engine-exited':
                self.discard_engine()
                self.idle, self.paused, self.position, self.bitrate = True, True, 0, 0
                self.radio_title = ''
                self.radio_status = 'unavailable' if self.is_radio() else 'stopped'
                self.emit({'type': 'error', 'message': 'Audio player stopped. Press Play to restart playback.'})
                self.state()
            elif event.get('request_id') == 900:
                if not self.idle and not self.paused:
                    self.emit({'type': 'meter', 'levels': event.get('spectrum', [0.0] * 16)})
            elif event.get('event') == 'property-change':
                name, value = event.get('name'), event.get('data')
                mapping = {'time-pos': 'position', 'duration': 'duration', 'pause': 'paused',
                           'idle-active': 'idle', 'audio-bitrate': 'bitrate'}
                if name == 'metadata' and self.is_radio() and not self.idle:
                    metadata = value if isinstance(value, dict) else {}
                    title = next((v for k, v in metadata.items() if k.lower() in ('icy-title', 'streamtitle') and isinstance(v, str)), '')
                    self.radio_title = ''.join(c for c in title[:512] if c.isprintable()).strip()
                    self.state()
                if self.is_radio() and name in ('time-pos', 'duration'): return
                if self.is_radio() and name == 'paused-for-cache' and value is not None and not self.idle:
                    self.cache_paused = bool(value)
                    self.radio_status = 'paused' if self.paused else 'connecting' if not self.file_loaded else 'buffering' if value else 'playing'
                    self.state(); return
                if name in mapping and value is not None:
                    setattr(self, mapping[name], value)
                    if self.is_radio() and name == 'pause' and not self.idle:
                        self.radio_status = 'paused' if value else 'connecting' if not self.file_loaded else 'buffering' if self.cache_paused else 'playing'
                    if name == 'idle-active' and value: self.radio_title = ''
                    self.state()
            elif event.get('event') == 'end-file':
                if self.is_radio() and event.get('reason') in ('eof', 'error'):
                    self.idle, self.paused, self.radio_title = True, True, ''
                    self.radio_status = 'unavailable'
                    self.emit({'type': 'error', 'message': 'Radio station is unavailable. Press Play to reconnect or choose another station.'})
                    self.state()
                elif event.get('reason') == 'eof':
                    if self.prepared_next:
                        self.awaiting_next = self.prepared_next
                    else: self.next_track(automatic=True)
                elif event.get('reason') == 'error':
                    if self.mpv and getattr(self.mpv, 'supports_gapless', False): self.mpv.clear_next()
                    self.prepared_next, self.awaiting_next = None, None
                    self.idle = True
                    self.emit({'type': 'error', 'message': 'Cannot stream this track. Check the connection and Jellyfin playback permissions.'})
                    self.state()

    def play(self, index, resume=False):
        if not 0 <= index < len(self.queue):
            return
        track = self.queue[index]
        if radio.remote(track) and self.queue_identity and self.queue_identity != identity(self.client):
            self.emit({'type': 'error', 'message': 'This playlist belongs to a different Jellyfin account. Reconnect to that account or replace the playlist.'})
            return
        start = self.position if resume and index == self.index else 0
        self.file_loaded, self.cache_paused = False, False
        self.prepared_next, self.awaiting_next = None, None
        if track.get('source') == 'local':
            try:
                path = local_file(track.get('path'))
            except (OSError, ValueError, RuntimeError):
                if self.mpv: self.mpv.send('stop')
                self.index, self.position = index, 0
                self.idle, self.paused = True, True
                self.emit({'type': 'error', 'message': 'This local file is unavailable or is not a supported audio file.'})
                return
            url, headers = str(path), []
        elif track.get('source') == 'radio':
            url, headers, start = radio.stream(track if 'radioUrl' in track else track['id']), [], 0
        elif self.client:
            url, headers = self.client.stream(track['id']), ['Authorization: ' + self.client.authorization()]
        else:
            return
        # A station switch gets fresh ICY metadata and cannot inherit callbacks.
        if self.is_radio() or track.get('source') == 'radio': self.discard_engine()
        self.radio_title = ''
        self.radio_status = 'connecting' if track.get('source') == 'radio' else 'stopped'
        self.bitrate = 0
        self.index = index
        engine = self.engine()
        engine.send('set_property', 'options/demuxer-lavf-o', demux_options(track.get('source') == 'local'))
        engine.load(url, headers, start=start)
        engine.send('set_property', 'pause', False)
        self.index, self.position = index, start
        self.session_pending = False
        self.duration = self.queue[index]['duration']
        self.paused, self.idle = False, False

    def next_track(self, automatic=False):
        if not self.queue:
            return
        if automatic and self.repeat == 'one':
            target = self.index
        elif self.shuffle and len(self.queue) > 1:
            target = random.choice([i for i in range(len(self.queue)) if i != self.index])
        else:
            target = self.index + 1
        if target >= len(self.queue):
            if self.repeat == 'all':
                target = 0
            else:
                if self.mpv:
                    self.mpv.send('stop')
                self.idle, self.paused = True, True
                self.checkpoint()
                self.state()
                return
        self.play(target)
        self.checkpoint()
        self.state()

    def network(self, command, generation):
        client = None
        stage = 'library'
        try:
            if command['cmd'] in ('login', 'restore'):
                if command['cmd'] == 'restore':
                    stage = 'restore'
                    # Local browsing must not depend on the keyring or server.
                    if self.session_folder == 'radio':
                        with self.lock:
                            if generation != self.generation: return
                            self.load_radio()
                    elif self.local and self.local.prefer_local:
                        self.load_local(generation)
                    saved = self.store.load() if self.store else None
                    if not saved:
                        with self.lock:
                            if generation != self.generation: return
                            self.emit({'type': 'restore_retry', 'value': False})
                        if self.local and not self.local.prefer_local and self.session_folder != 'radio': self.load_local(generation)
                        return
                    with self.lock:
                        if generation != self.generation:
                            return
                        self.emit({'type': 'profile', 'url': saved['url'], 'username': saved['username']})
                    client = Jellyfin(saved['url'])
                    client.token, client.user, client.device = saved['token'], saved['user'], saved['device']
                    command['username'] = saved['username']
                    client.request('/Users/Me')
                else:
                    stage = 'login'
                    client = Jellyfin(command['url'])
                    client.login(command['username'], command.pop('password', ''))
                stage = 'libraries'
                libraries = client.libraries()
                preferred = (self.session_folder if self.session_folder not in (None, 'local') else saved.get('folder', '')) if command['cmd'] == 'restore' else ''
                folder = next((item['id'] for item in libraries if item['id'] == preferred),
                              libraries[0]['id'] if libraries else '')
                with self.lock:
                    if generation != self.generation:
                        return
                    self.client = client
                    self.username = command['username']
                    self.emit({'type': 'profile', 'url': client.url, 'username': command['username']})
                    self.remembered = command['cmd'] == 'restore'
                    if self.store and command['cmd'] == 'login':
                        try:
                            self.store.save(client, command['username'])
                            self.remembered = True
                        except RuntimeError as exc:
                            self.emit({'type': 'error', 'message': str(exc)})
                    self.emit({'type': 'restore_retry', 'value': False})
                    self.emit({'type': 'remembered', 'value': self.remembered})
                    self.emit({'type': 'connected', 'libraries': libraries, 'username': command['username'], 'folder': folder,
                               'preserveLocal': bool(self.local and self.local.prefer_local and command['cmd'] == 'restore'),
                               'preserveRadio': self.session_folder == 'radio' and command['cmd'] == 'restore'})
                stage = 'library'
                if command['cmd'] == 'restore' and (self.session_folder == 'radio' or (self.local and self.local.prefer_local)):
                    with self.lock:
                        if generation == self.generation: self.state()
                    return
                songs = client.songs(folder) if libraries else []
            else:
                client = self.client
                if not client:
                    raise ValueError('Connect to Jellyfin first.')
                libraries = client.libraries()
                requested = command.get('folder', self.folder)
                folder = next((item['id'] for item in libraries if item['id'] == requested), libraries[0]['id'] if libraries else '')
                songs = client.songs(folder) if folder else []
            with self.lock:
                if generation == self.generation:
                    if command['cmd'] == 'library':
                        self.emit({'type': 'remote_libraries', 'libraries': libraries})
                    self.songs = songs
                    if self.local:
                        self.local.prefer_local = False
                        try:
                            self.local.save()
                        except (OSError, RuntimeError):
                            self.emit({'type': 'error', 'message': 'Jellyfin loaded, but its source selection could not be saved.'})
                    changed = folder != self.folder
                    self.folder = folder
                    self.emit({'type': 'library', 'songs': songs, 'folder': folder})
                    self.session_folder = folder
                    self.checkpoint()
                    if changed and self.store and self.remembered:
                        try:
                            self.store.save(client, self.username, folder)
                        except RuntimeError:
                            self.emit({'type': 'error', 'message': 'Library loaded, but its selection could not be saved. Unlock your keyring and select it again.'})
                            self.folder = ''
        except Exception as exc:
            with self.lock:
                if generation != self.generation:
                    return
                if command['cmd'] == 'restore': self.emit({'type': 'restore_retry', 'value': True})
                if isinstance(exc, urllib.error.HTTPError):
                    exc.close()
                    if exc.code in (401, 403) and stage == 'restore':
                        if self.store:
                            self.clear_saved()
                        message = 'Saved sign-in has expired. Please sign in again.'
                    elif exc.code in (401, 403):
                        message = ('Jellyfin rejected the username or password.' if stage == 'login' else
                                   'Login succeeded, but Jellyfin denied library access. Check this account’s library permissions and sign in again.')
                    else:
                        message = 'Jellyfin returned HTTP ' + str(exc.code) + ' while loading ' + stage + '. Check the server URL and base path.'
                elif isinstance(exc, RuntimeError):
                    message = str(exc)
                elif isinstance(exc, ValueError):
                    message = str(exc) if not isinstance(exc, json.JSONDecodeError) else 'The server did not return Jellyfin JSON.'
                else:
                    message = 'Could not reach Jellyfin. Check the URL, network, and TLS certificate.'
                self.emit({'type': 'error', 'message': message})
        finally:
            command.pop('password', None)
            if command['cmd'] == 'login' and client and client is not self.client and client.token:
                self.revoke(client)
            with self.lock:
                if generation == self.generation:
                    self.emit({'type': 'busy', 'value': False})

    def load_local(self, generation):
        if not self.local: raise RuntimeError('Local library unavailable.')
        songs, skipped = self.local.scan(cancel=self.closing)
        with self.lock:
            if generation != self.generation: return
            self.songs = songs
            self.local.prefer_local = True
            self.emit({'type': 'library', 'folder': 'local', 'songs': songs})
            self.session_folder = 'local'
            self.checkpoint()
            try:
                self.local.save()
            except (OSError, RuntimeError):
                self.emit({'type': 'error', 'message': 'Local music loaded, but its selection could not be saved.'})
            if skipped:
                self.emit({'type': 'error', 'message': str(skipped) + ' unreadable local audio file(s) skipped.'})

    def local_command(self, command, generation):
        picker = command['cmd'] in ('choose_files', 'choose_folder', 'choose_drop')
        picker_request = command.get('pickerRequest')
        owned_picker = picker and type(picker_request) is int and 1 <= picker_request <= 2**31 - 1
        window = command.pop('_window', None)
        message = ''
        try:
            with self.lock:
                if generation != self.generation: return
            if not self.local: raise RuntimeError('Local library unavailable.')
            paths = command.get('paths', [])
            if command['cmd'] == 'local_remove':
                with self.lock:
                    if generation != self.generation: return
                    self.local.remove(paths)
                    self.emit({'type': 'local_sources', 'available': bool(self.local.roots), 'paths': self.local.roots})
                if self.local.prefer_local: self.load_local(generation)
                return
            if picker:
                args = ['/usr/bin/python3', '-B', os.path.join(os.path.dirname(__file__), 'file_picker.py')]
                # Older clients' drop action now opens the normal folder picker.
                if command['cmd'] in ('choose_folder', 'choose_drop'): args += ['--folder']
                result = run_bounded(args, limit=65536, timeout=3610, cancel=self.closing, memory_limit=1024*1024*1024)
                if result.returncode == 1: return
                if result.returncode: raise RuntimeError('Could not open the desktop file picker. Check your file-picker portal.')
                paths = json.loads(result.stdout)
            with self.lock:
                if generation != self.generation: return
                if paths:
                    self.local.add(paths)
                    self.emit({'type': 'local_sources', 'available': bool(self.local.roots), 'paths': self.local.roots})
            self.load_local(generation)
        except Exception as exc:
            message = str(exc) if isinstance(exc, (RuntimeError, ValueError)) else 'Could not read or save local music sources.'
            with self.lock:
                if generation == self.generation:
                    self.emit({'type': 'error', 'message': message})
        finally:
            with self.lock:
                if generation == self.generation:
                    self.emit({'type': 'busy', 'value': False})
                # Release only the matching modern picker. Retired selections
                # must never reopen the player or change newer source state.
                if owned_picker:
                    self.emit({'type': 'picker_closed' if generation == self.generation else 'picker_retired', 'request': picker_request})
                elif picker and generation == self.generation:
                    self.emit({'type': 'picker_closed'})
                if window and window is self.local_window:
                    window.update(self.local.roots, message or ('Source view changed; try again.' if generation != self.generation else ''))

    def manage_local(self, theme):
        if not self.local: raise RuntimeError('Local music is unavailable.')
        if self.local_window:
            self.local_window.present(); return
        if not isinstance(theme, dict) or len(json.dumps(theme)) > 8192: raise ValueError('Invalid Local Music theme.')
        def action(command):
            with self.lock:
                if self.closing.is_set() or self.local_window is not window: return
                command['_window'] = window
                self.handle(command)
        def closed():
            with self.lock:
                if self.local_window is not window: return
                self.local_window = None
                if not self.closing.is_set():
                    if window.proc and window.proc.returncode not in (0, -signal.SIGTERM):
                        self.emit({'type': 'error', 'message': 'The Local Music window could not stay open. Check GTK 4 and Python.'})
                    self.emit({'type': 'local_manager_closed'})
        window = self.local_window = LocalMusicWindow(action, closed)
        try: window.start(self.local.roots, theme)
        except Exception:
            self.local_window = None; window.close()
            raise RuntimeError('Could not open the Local Music window. Check GTK 4 is installed.')

    def search_radio(self, command, generation):
        try:
            with self.lock:
                if generation != self.radio_generation: return
            rows, more = self.radio_browser.search(command.get('fields', {}), command.get('offset', 0))
            with self.lock:
                if generation != self.radio_generation: return
                if command.get('offset', 0):
                    seen = {row['id'] for row in self.radio_results}
                    self.radio_results += [row for row in rows if row['id'] not in seen]
                else: self.radio_results = rows
                self.radio_results = self.radio_results[:MAX_RESULTS]
                self.emit({'type': 'radio_results', 'songs': self.radio_results, 'more': more and len(self.radio_results) < MAX_RESULTS, 'offset': command.get('offset', 0) + PAGE_SIZE, 'request': command.get('request', 0)})
        except (RuntimeError, ValueError, OSError):
            with self.lock:
                if generation == self.radio_generation:
                    self.emit({'type': 'radio_error', 'message': 'Radio search is unavailable. Try again; saved stations still work.', 'request': command.get('request', 0)})
        finally:
            with self.lock:
                if generation == self.radio_generation: self.emit({'type': 'radio_busy', 'value': False, 'request': command.get('request', 0)})

    def available_tracks(self):
        return self.songs + self.radio_results if self.folder == 'radio' else self.songs

    def queue_fits(self, rows):
        if len(rows) > MAX_QUEUE_TRACKS:
            self.emit({'type': 'error', 'message': 'Playlist exceeds the 100,000-track safety limit.'})
            return False
        # Count encoded pieces, rather than constructing an oversized JSON string.
        total = 0
        for block in json.JSONEncoder(ensure_ascii=False, allow_nan=False).iterencode(rows):
            total += len(block.encode('utf-8'))
            if total > MAX_SESSION_BYTES - 65536:
                self.emit({'type': 'error', 'message': 'Playlist exceeds the 64 MiB safety limit.'})
                return False
        return True

    def paste_clipboard(self, request, primary):
        try:
            text = read_clipboard(primary)
            self.emit({'type': 'clipboard', 'request': request, 'text': text})
        except (OSError, ValueError, subprocess.SubprocessError):
            self.emit({'type': 'clipboard', 'request': request,
                       'error': 'Clipboard paste failed or exceeded its 64 KiB / 2-second limit. Copy a smaller amount of text and try again.'})

    def handle(self, c):
        with self.lock:
            cmd = c.get('cmd')
            if cmd == 'manage_local':
                try: self.manage_local(c.get('theme', {}))
                except Exception:
                    self.emit({'type': 'local_manager_closed'})
                    raise
                return
            if cmd in ('hosted_list', 'hosted_items', 'hosted_create', 'hosted_load', 'hosted_delete'):
                self.submit_hosted(c)
                return
            if cmd in ('add', 'replace_play', 'remove', 'move', 'clear', 'play', 'pause', 'stop', 'next', 'previous', 'seek', 'collection_load', 'prepare_update'):
                self.playback_revision += 1
            if cmd in ('playlist_save', 'playlist_rename', 'playlist_delete', 'recent_clear'):
                if self.collection_future and not self.collection_future.done():
                    self.emit({'type': 'error', 'message': 'A playlist change is still being saved. Try again in a moment.'})
                else:
                    if cmd == 'recent_clear':
                        self.pending_recent = None
                        self.last_recent_group = None
                    self.collection_future = self.collection_work.submit(self.collection_command, dict(c), self.session_snapshot())
                return
            if cmd == 'collection_load':
                try: self.load_collection(c); self.checkpoint(); self.state()
                except (OSError, ValueError, RuntimeError) as exc:
                    self.emit({'type': 'error', 'message': str(exc)})
                return
            if cmd == 'clipboard_paste':
                if not self.clipboard_future or self.clipboard_future.done():
                    self.clipboard_future = self.clipboard_work.submit(self.paste_clipboard, c.get('request', 0), c.get('primary') is True)
                else:
                    self.emit({'type': 'clipboard', 'request': c.get('request', 0), 'error': 'A paste is already in progress.'})
                return
            if cmd == 'prepare_update':
                self.paused = True
                if self.mpv and not self.idle:
                    self.mpv.send('set_property', 'pause', True)
                self.state()
                try:
                    if self.playback_store:
                        self.playback_store.flush(self.session_snapshot())
                    self.emit({'type': 'update_ready', 'request': c.get('request', 0)})
                except (OSError, ValueError, TypeError, RecursionError):
                    self.emit({'type': 'update_error', 'request': c.get('request', 0), 'message': 'Could not save your playlist and position. Update cancelled; check free space or permissions.'})
                return
            if cmd == 'radio_search':
                self.radio_generation += 1
                if self.radio_future: self.radio_future.cancel()
                if not c.get('offset', 0): self.radio_results = []
                self.emit({'type': 'radio_busy', 'value': True, 'request': c.get('request', 0)})
                self.radio_future = self.radio_work.submit(self.search_radio, dict(c), self.radio_generation)
                return
            if cmd == 'radio_cancel':
                self.radio_generation += 1
                if self.radio_future: self.radio_future.cancel()
                self.radio_results = []
                self.emit({'type': 'radio_results', 'songs': [], 'more': False, 'offset': 0, 'request': c.get('request', 0)})
                self.emit({'type': 'radio_busy', 'value': False, 'request': c.get('request', 0)})
                return
            if cmd in ('radio_save', 'radio_remove'):
                try:
                    if cmd == 'radio_remove':
                        self.radios.remove(c.get('id'))
                        saved_id = ''
                    else:
                        if 'id' in c:
                            row = next((row for row in self.available_tracks() if row['id'] == c['id'] and row.get('source') == 'radio'), None)
                            if row is None: raise ValueError('Select a station to save.')
                        else: row = radio.make_station(c.get('name'), c.get('url'))
                        saved_id = self.radios.add(row)
                    if self.folder == 'radio': self.load_radio()
                    self.emit({'type': 'radio_saved', 'id': saved_id})
                except (OSError, RuntimeError, ValueError) as exc:
                    self.emit({'type': 'error', 'message': str(exc) if isinstance(exc, (RuntimeError, ValueError)) else 'Could not save stations. Check permissions or free space.'})
                return
            if cmd == 'visibility':
                self.visible = c.get('visible') is True
                if self.mpv:
                    self.mpv.set_meter(self.visible and not self.idle and not self.paused)
                return
            if cmd == 'meter':
                if self.mpv and self.visible and not self.idle and not self.paused:
                    self.mpv.query_meter()
                return
            if cmd == 'library' and c.get('folder') == 'radio':
                self.generation += 1
                self.load_radio()
                self.emit({'type': 'busy', 'value': False})
            elif cmd in ('local_add', 'local_remove', 'choose_files', 'choose_folder', 'choose_drop') or (cmd == 'library' and c.get('folder') == 'local'):
                self.generation += 1
                self.emit({'type': 'busy', 'value': True})
                self.work.submit(self.local_command, c, self.generation)
            elif cmd in ('login', 'library', 'restore'):
                self.generation += 1
                if cmd == 'login':
                    old = self.client
                    self.reset()
                    if old:
                        self.work.submit(self.revoke, old)
                self.emit({'type': 'busy', 'value': True})
                self.work.submit(self.network, c, self.generation)
            elif cmd == 'logout':
                self.generation += 1
                old = self.client
                self.reset()
                self.emit({'type': 'disconnected'})
                self.work.submit(self.clear_saved)
                if old:
                    self.work.submit(self.revoke, old)
            elif cmd == 'add':
                ids = set(c.get('ids', []))
                selected = [dict(s, key=str(uuid.uuid4())) for s in {row['id']: row for row in self.available_tracks()}.values() if s['id'] in ids]
                if not self.queue_fits(self.queue + selected): return
                if any(radio.remote(s) for s in selected):
                    if self.queue_identity and self.queue_identity != identity(self.client):
                        self.emit({'type': 'error', 'message': 'Replace the playlist before adding music from a different Jellyfin account.'})
                        return
                    self.queue_identity = identity(self.client)
                self.queue = self.queue + selected
            elif cmd == 'replace_play':
                ids = set(c.get('ids', []))
                selection = [dict(s, key=str(uuid.uuid4())) for s in {row['id']: row for row in self.available_tracks()}.values() if s['id'] in ids]
                if not self.queue_fits(selection): return
                if selection and (self.client or all(not radio.remote(s) for s in selection)):
                    self.queue = selection
                    self.queue_identity = identity(self.client) if any(radio.remote(s) for s in selection) else None
                    self.play(0)
            elif cmd == 'remove':
                keys = set(c.get('keys', []))
                current = self.queue[self.index]['key'] if 0 <= self.index < len(self.queue) else None
                old_index = self.index
                self.queue = [s for s in self.queue if s['key'] not in keys]
                self.index = next((i for i, s in enumerate(self.queue) if s['key'] == current), -1)
                if current in keys:
                    self.session_pending = False
                    if self.mpv:
                        self.mpv.send('stop')
                    self.idle, self.paused = True, True
                    self.position, self.duration = 0, 0
                    if self.queue:
                        self.index = min(old_index, len(self.queue) - 1)
                        self.duration = self.queue[self.index]['duration']
            elif cmd == 'move':
                i, delta = int(c['index']), int(c['delta'])
                j = i + delta
                if 0 <= i < len(self.queue) and 0 <= j < len(self.queue):
                    self.queue[i], self.queue[j] = self.queue[j], self.queue[i]
                    if self.index == i:
                        self.index = j
                    elif self.index == j:
                        self.index = i
            elif cmd == 'clear':
                if self.mpv:
                    self.mpv.send('stop')
                self.queue, self.index = [], -1
                self.queue_identity, self.session_pending = None, False
                self.position, self.duration, self.paused, self.idle = 0, 0, True, True
                self.prepared_next, self.awaiting_next = None, None
            elif cmd == 'play':
                self.play(int(c.get('index', max(0, self.index))), resume=self.session_pending)
            elif cmd == 'pause':
                if self.idle or self.session_pending or self.mpv is None:
                    self.play(max(0, self.index), resume=self.session_pending)
                elif self.is_radio() and self.paused:
                    self.play(self.index)
                elif self.mpv:
                    self.paused = not self.paused
                    self.mpv.send('set_property', 'pause', self.paused)
                    if self.is_radio(): self.radio_status = 'paused' if self.paused else 'playing'
            elif cmd == 'stop':
                if self.mpv:
                    self.mpv.send('stop')
                self.idle, self.paused, self.position = True, True, 0
                self.radio_title = ''
                self.radio_status = 'stopped'
                self.prepared_next, self.awaiting_next = None, None
                self.session_pending = False
            elif cmd == 'next':
                self.next_track()
            elif cmd == 'previous':
                self.play(max(0, self.index - 1))
            elif cmd == 'seek' and not self.idle and not self.is_radio():
                value = float(c['seconds'])
                if not math.isfinite(value): raise ValueError('Seek must be finite.')
                self.position = max(0, min(value, self.duration))
                if self.mpv: self.mpv.send('seek', self.position, 'absolute')
            elif cmd == 'reduce_motion':
                self.reduce_motion = c.get('value') is True
            elif cmd == 'gapless':
                self.gapless = c.get('value') is True
                if self.mpv: self.mpv.send('set_property', 'options/gapless-audio', 'weak' if self.gapless else 'no')
            elif cmd == 'keep_recent':
                self.keep_recent = c.get('value') is True; self.last_recent_group = None
                if not self.keep_recent: self.pending_recent = None
            elif cmd in ('normalization', 'replay_gain'):
                value = c.get('value')
                if cmd == 'replay_gain':
                    # Compatibility with a bridge retained across a shell reload.
                    if value not in ('no', 'track', 'album'): raise ValueError('Choose normalization On or Off.')
                    value = value != 'no'
                if type(value) is not bool: raise ValueError('Choose normalization On or Off.')
                if self.mpv and value != self.normalization:
                    self.mpv.send('af', 'add' if value else 'remove', NORMALIZATION_FILTER if value else '@normalize')
                self.normalization = value
            elif cmd == 'radio_retry' and self.is_radio():
                self.play(self.index)
            elif cmd == 'volume':
                value = float(c['value'])
                if not math.isfinite(value):
                    raise ValueError('Volume must be finite.')
                self.volume = max(0, min(100, value))
                if self.mpv:
                    self.mpv.send('set_property', 'volume', self.volume)
            elif cmd == 'shuffle':
                self.shuffle = not self.shuffle
            elif cmd == 'repeat':
                self.repeat = {'off': 'all', 'all': 'one', 'one': 'off'}[self.repeat]
            if cmd in ('volume', 'shuffle', 'repeat', 'reduce_motion', 'gapless', 'normalization', 'replay_gain', 'keep_recent') and self.preferences:
                try:
                    self.preferences.save(self.volume, self.shuffle, self.repeat, self.reduce_motion, self.gapless, self.normalization, self.keep_recent)
                except OSError:
                    self.emit({'type': 'error', 'message': 'Playback settings changed but could not be saved.'})
            if cmd in ('add', 'replace_play', 'remove', 'move', 'clear', 'play', 'pause', 'stop', 'next', 'previous', 'seek', 'logout'):
                self.checkpoint()
            if cmd in ('add', 'remove', 'move', 'shuffle', 'repeat', 'gapless'):
                if cmd in ('shuffle', 'repeat') and self.prepared_next:
                    self.mpv.clear_next(); self.prepared_next = None
                self.prepare_next()
            self.state()

    @staticmethod
    def revoke(client):
        try:
            client.request('/Sessions/Logout', body={})
        except Exception:
            pass
        client.token = ''

    def clear_saved(self):
        if self.store:
            try:
                self.store.clear()
            except RuntimeError as exc:
                self.emit({"type": "error", "message": str(exc)})
        self.remembered = False

    def reset(self):
        # Account changes must retire both the active and prefetched relay routes.
        self.discard_engine()
        self.clear_hosted()
        self.client, self.songs, self.queue = None, [], []
        self.queue_identity, self.session_folder, self.session_pending = None, None, False
        self.username, self.folder = "", ""
        self.index, self.position, self.duration, self.bitrate = -1, 0, 0, 0
        self.idle, self.paused = True, True
        self.radio_title = ''
        self.radio_status = 'stopped'
        self.prepared_next, self.awaiting_next = None, None

    def close(self):
        with self.lock: self.generation += 1
        self.closing.set()
        if self.local_window: self.local_window.close()
        self.hosted_work.shutdown(wait=True, cancel_futures=True)
        self.clipboard_work.shutdown(wait=True, cancel_futures=True)
        self.radio_generation += 1
        self.radio_work.shutdown(wait=True, cancel_futures=True)
        self.collection_work.shutdown(wait=True, cancel_futures=False)
        with self.lock:
            if self.playback_store:
                try: self.playback_store.close(self.session_snapshot())
                except (OSError, ValueError): pass
                self.playback_store = None
            self.discard_engine()
        self.work.shutdown(wait=True, cancel_futures=False)
        if self.client and not self.remembered:
            self.revoke(self.client)


def main():
    output_lock = threading.Lock()
    media = None
    snapshot = {}
    def emit(data):
        if media and data.get("type") == "state":
            media.update()
        with output_lock:
            kind = data.get('type')
            if kind == 'disconnected':
                for stale in ('connected', 'profile', 'remembered', 'library', 'remote_libraries', 'restore_retry'):
                    snapshot.pop(stale, None)
            if kind == 'hosted_reset':
                for stale in ('hosted_playlists', 'hosted_items', 'hosted_busy'): snapshot.pop(stale, None)
            if kind == 'connected': snapshot.pop('disconnected', None)
            if kind in ('state', 'collections', 'hosted_reset', 'hosted_playlists', 'hosted_items', 'hosted_busy', 'local_sources', 'profile', 'remembered', 'connected', 'disconnected', 'library', 'remote_libraries', 'restore_retry', 'busy', 'radio_results', 'radio_busy'):
                snapshot.pop(kind, None)
                snapshot[kind] = data
            print(json.dumps(data, separators=(',', ':')), flush=True)
    def terminate(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    guard_parent(os.getppid())
    from local_library import LocalLibrary
    from preferences import Preferences
    from playback_store import PlaybackStore
    player = Player(emit, store=SessionStore(), local=LocalLibrary(), preferences=Preferences(), playback_store=PlaybackStore(), radio_store=RadioStore(), collections=CollectionStore())
    from mpris import Mpris
    media = Mpris(player)
    emit({'type': 'local_sources', 'available': bool(player.local.roots), 'paths': player.local.roots})
    if player.radios.warning:
        emit({'type': 'error', 'message': player.radios.warning})
    if player.local.warning:
        emit({'type': 'error', 'message': player.local.warning})
    if player.collections.warning: emit({'type': 'error', 'message': player.collections.warning})
    player.emit_collections()
    player.state()
    emit({'type': 'ready'})
    player.handle({'cmd': 'restore'})
    try:
        for line in sys.stdin:
            try:
                command = json.loads(line)
                if command.get('cmd') == 'sync':
                    # Quickshell may retain this process across a QML reload.
                    with output_lock:
                        for data in snapshot.values():
                            print(json.dumps(data, separators=(',', ':')), flush=True)
                        print('{"type":"ready"}', flush=True)
                else:
                    player.handle(command)
            except Exception:
                emit({'type': 'error', 'message': 'Player command failed. Check that mpv is installed and try again.'})
    finally:
        media.close()
        player.close()


if __name__ == '__main__':
    main()
