#!/usr/bin/env python3
"""OmaGAWD: JSON-lines bridge. Passwords stay in memory; reconnect tokens use the desktop keyring."""
import json
import os
import random
import signal
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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Jellyfin:
    def __init__(self, url):
        url = url.strip().rstrip('/')
        p = urllib.parse.urlsplit(url)
        if p.scheme not in ('https', 'http') or not p.hostname or p.username or p.password or p.query or p.fragment:
            raise ValueError('Enter an http(s) server URL, including any /jellyfin base path.')
        self.url, self.token, self.user = url, '', ''
        self.device = str(uuid.uuid4())
        self.opener = urllib.request.build_opener(NoRedirect)

    def authorization(self):
        values = {'Client': 'OmaGAWD', 'Device': 'Omarchy', 'DeviceId': self.device, 'Version': '0.1.0'}
        if self.token:
            values['Token'] = self.token
        return 'MediaBrowser ' + ', '.join(k + '="' + urllib.parse.quote(v, safe='') + '"' for k, v in values.items())

    def request(self, path, params=None, body=None):
        url = self.url + path
        if params:
            url += '?' + urllib.parse.urlencode(params)
        headers = {'Authorization': self.authorization(), 'Content-Type': 'application/json'}
        request = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=headers)
        with self.opener.open(request, timeout=20) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}

    def login(self, username, password):
        data = self.request('/Users/AuthenticateByName', body={'Username': username, 'Pw': password})
        self.token, self.user = data['AccessToken'], data['User']['Id']

    def libraries(self):
        data = self.request('/UserViews', {'UserId': self.user})
        return [{'id': i['Id'], 'name': i['Name']} for i in data.get('Items', []) if i.get('CollectionType') == 'music']

    def songs(self, folder):
        result = []
        while True:
            params = {'Recursive': 'true', 'IncludeItemTypes': 'Audio', 'UserId': self.user,
                      'SortBy': 'AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName', 'SortOrder': 'Ascending',
                      'StartIndex': len(result), 'Limit': 500}
            if folder:
                params['ParentId'] = folder
            data = self.request('/Items', params)
            batch = data.get('Items', [])
            for i in batch:
                result.append({'id': i['Id'], 'title': i.get('Name', 'Untitled'),
                               'artist': i.get('AlbumArtist') or ', '.join(i.get('Artists') or []) or 'Unknown artist',
                               'album': i.get('Album') or 'Unknown album', 'albumId': i.get('AlbumId') or i.get('Album', ''),
                               'duration': i.get('RunTimeTicks', 0) / 10000000,
                               'track': i.get('IndexNumber', 0), 'disc': i.get('ParentIndexNumber', 0)})
            if not batch or len(result) >= data.get('TotalRecordCount', len(result)):
                return result

    def stream(self, item):
        # mpv decodes the original audio; no lossy transcoding or token in URL.
        return self.url + '/Audio/' + urllib.parse.quote(item, safe='') + '/stream?static=true'


class Mpv:
    def __init__(self, callback):
        self.callback, self.lock = callback, threading.Lock()
        self.temp = tempfile.TemporaryDirectory(prefix='omaamp-')
        path = self.temp.name + '/mpv.sock'
        meter_path = self.temp.name + '/spectrum.pipe'
        os.mkfifo(meter_path, 0o600)
        self.meter_fd = os.open(meter_path, os.O_RDWR | os.O_NONBLOCK)
        self.meter_stop = threading.Event()
        self.spectrum = [0.0] * 16
        self.meter_thread = threading.Thread(target=self.read_spectrum, daemon=True)
        self.meter_thread.start()
        self.proc = subprocess.Popen(['mpv', '--no-config', '--idle=yes', '--no-video', '--no-terminal',
                                      '--audio-display=no', '--af=@meter:lavfi=[' + filter_graph(meter_path) + ']',
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
        for n, prop in enumerate(['time-pos', 'duration', 'pause', 'idle-active', 'audio-bitrate']):
            self.send('observe_property', n, prop)

    def send(self, *command):
        with self.lock:
            self.sock.sendall((json.dumps({'command': command}) + '\n').encode())

    def query_meter(self):
        self.callback({'request_id': 900, 'spectrum': list(self.spectrum)})

    def read_spectrum(self):
        pending = ''
        frame = [0.0] * 16
        while not self.meter_stop.wait(0.02):
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
                            self.spectrum = frame[:]

    def read(self):
        try:
            with self.sock.makefile() as stream:
                for line in stream:
                    self.callback(json.loads(line))
        except (OSError, ValueError):
            pass

    def close(self):
        if getattr(self, 'proc', None):
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if getattr(self, 'sock', None):
            self.sock.close()
        self.meter_stop.set()
        self.meter_thread.join(timeout=1)
        os.close(self.meter_fd)
        self.temp.cleanup()


class Player:
    def __init__(self, emit, mpv_factory=Mpv, store=None):
        self.emit, self.mpv_factory = emit, mpv_factory
        self.store, self.remembered = store, False
        self.username, self.folder = "", ""
        self.lock = threading.RLock()
        self.client, self.mpv = None, None
        self.songs, self.queue = [], []
        self.index, self.position, self.duration = -1, 0, 0
        self.paused, self.idle, self.shuffle, self.repeat = True, True, False, 'off'
        self.volume, self.bitrate, self.generation = 70, 0, 0
        self.work = ThreadPoolExecutor(max_workers=1)

    def state(self):
        self.emit({'type': 'state', 'queue': self.queue, 'index': self.index, 'position': self.position,
                   'duration': self.duration, 'paused': self.paused, 'idle': self.idle,
                   'shuffle': self.shuffle, 'repeat': self.repeat, 'volume': self.volume, 'bitrate': self.bitrate})

    def engine(self):
        if self.mpv is None:
            self.mpv = self.mpv_factory(self.event)
            self.mpv.send('set_property', 'volume', self.volume)
        return self.mpv

    def event(self, event):
        with self.lock:
            if event.get('request_id') == 900:
                if not self.idle and not self.paused:
                    self.emit({'type': 'meter', 'levels': event.get('spectrum', [0.0] * 16)})
            elif event.get('event') == 'property-change':
                name, value = event.get('name'), event.get('data')
                mapping = {'time-pos': 'position', 'duration': 'duration', 'pause': 'paused',
                           'idle-active': 'idle', 'audio-bitrate': 'bitrate'}
                if name in mapping and value is not None:
                    setattr(self, mapping[name], value)
                    self.state()
            elif event.get('event') == 'end-file':
                if event.get('reason') == 'eof':
                    self.next_track(automatic=True)
                elif event.get('reason') == 'error':
                    self.idle = True
                    self.emit({'type': 'error', 'message': 'Cannot stream this track. Check the connection and Jellyfin playback permissions.'})
                    self.state()

    def play(self, index):
        if not self.client or not 0 <= index < len(self.queue):
            return
        engine = self.engine()
        engine.send('set_property', 'http-header-fields', ['Authorization: ' + self.client.authorization()])
        engine.send('loadfile', self.client.stream(self.queue[index]['id']), 'replace')
        engine.send('set_property', 'pause', False)
        self.index, self.position = index, 0
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
                self.state()
                return
        self.play(target)
        self.state()

    def network(self, command, generation):
        client = None
        stage = 'library'
        try:
            if command['cmd'] in ('login', 'restore'):
                if command['cmd'] == 'restore':
                    stage = 'restore'
                    saved = self.store.load() if self.store else None
                    if not saved:
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
                preferred = saved.get('folder', '') if command['cmd'] == 'restore' else ''
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
                    self.emit({'type': 'remembered', 'value': self.remembered})
                    self.emit({'type': 'connected', 'libraries': libraries, 'username': command['username'], 'folder': folder})
                stage = 'library'
                songs = client.songs(folder) if libraries else []
            else:
                client = self.client
                if not client:
                    raise ValueError('Connect to Jellyfin first.')
                folder = command.get('folder', self.folder)
                songs = client.songs(folder)
            with self.lock:
                if generation == self.generation:
                    self.songs = songs
                    changed = folder != self.folder
                    self.folder = folder
                    self.emit({'type': 'library', 'songs': songs, 'folder': folder})
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
                if isinstance(exc, urllib.error.HTTPError):
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

    def handle(self, c):
        with self.lock:
            cmd = c.get('cmd')
            if cmd == 'meter':
                if self.mpv and not self.idle and not self.paused:
                    self.mpv.query_meter()
                return
            if cmd in ('login', 'library', 'restore'):
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
                self.queue = self.queue + [dict(s, key=str(uuid.uuid4())) for s in self.songs if s['id'] in ids]
            elif cmd == 'replace_play':
                ids = set(c.get('ids', []))
                selection = [dict(s, key=str(uuid.uuid4())) for s in self.songs if s['id'] in ids]
                if selection and self.client:
                    self.queue = selection
                    self.play(0)
            elif cmd == 'remove':
                keys = set(c.get('keys', []))
                current = self.queue[self.index]['key'] if 0 <= self.index < len(self.queue) else None
                old_index = self.index
                self.queue = [s for s in self.queue if s['key'] not in keys]
                self.index = next((i for i, s in enumerate(self.queue) if s['key'] == current), -1)
                if current in keys:
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
                self.position, self.duration, self.paused, self.idle = 0, 0, True, True
            elif cmd == 'play':
                self.play(int(c.get('index', max(0, self.index))))
            elif cmd == 'pause':
                if self.idle:
                    self.play(max(0, self.index))
                elif self.mpv:
                    self.paused = not self.paused
                    self.mpv.send('set_property', 'pause', self.paused)
            elif cmd == 'stop':
                if self.mpv:
                    self.mpv.send('stop')
                self.idle, self.paused, self.position = True, True, 0
            elif cmd == 'next':
                self.next_track()
            elif cmd == 'previous':
                self.play(max(0, self.index - 1))
            elif cmd == 'seek' and self.mpv and not self.idle:
                self.mpv.send('seek', max(0, min(float(c['seconds']), self.duration)), 'absolute')
            elif cmd == 'volume':
                self.volume = max(0, min(100, float(c['value'])))
                if self.mpv:
                    self.mpv.send('set_property', 'volume', self.volume)
            elif cmd == 'shuffle':
                self.shuffle = not self.shuffle
            elif cmd == 'repeat':
                self.repeat = {'off': 'all', 'all': 'one', 'one': 'off'}[self.repeat]
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
        if self.mpv:
            self.mpv.send('stop')
            self.mpv.send('set_property', 'http-header-fields', [])
        self.client, self.songs, self.queue = None, [], []
        self.username, self.folder = "", ""
        self.index, self.position, self.duration, self.bitrate = -1, 0, 0, 0
        self.idle, self.paused = True, True

    def close(self):
        self.generation += 1
        if self.mpv:
            self.mpv.close()
        self.work.shutdown(wait=True, cancel_futures=False)
        if self.client and not self.remembered:
            self.revoke(self.client)


def main():
    output_lock = threading.Lock()
    media = None
    def emit(data):
        if media and data.get("type") == "state":
            media.update()
        with output_lock:
            print(json.dumps(data, separators=(',', ':')), flush=True)
    def terminate(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    player = Player(emit, store=SessionStore())
    from mpris import Mpris
    media = Mpris(player)
    emit({'type': 'ready'})
    player.handle({'cmd': 'restore'})
    try:
        for line in sys.stdin:
            try:
                player.handle(json.loads(line))
            except Exception:
                emit({'type': 'error', 'message': 'Player command failed. Check that mpv is installed and try again.'})
    finally:
        media.close()
        player.close()


if __name__ == '__main__':
    main()
