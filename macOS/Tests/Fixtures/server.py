#!/usr/bin/env python3
"""Disposable Jellyfin/range server. Fixture credentials only; binds loopback."""
import http.server, json, math, os, struct, sys, time, wave, urllib.parse, threading
folder = sys.argv[1]
os.makedirs(folder, exist_ok=True)
path = os.path.join(folder, 'OmaGAWD test tone.wav')
with wave.open(path, 'wb') as f:
    f.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
    f.writeframes(b''.join(struct.pack('<h', int(1200 * math.sin(i * 440 * 2 * math.pi / 44100))) for i in range(44100 * 45)))
USER = '33333333333333333333333333333333'
SONG = '22222222222222222222222222222222'
PLAYLIST = '11111111111111111111111111111111'
CREATED = '44444444444444444444444444444444'
playlists = {PLAYLIST: {'Id': PLAYLIST, 'Name': 'Fixture playlist', 'Type': 'Playlist', 'MediaType': 'Audio', 'CanDelete': True, 'ChildCount': 2}}
playlist_lock = threading.Lock()
audio_counts = {}
audio_lock = threading.Lock()
audio_delayed = set()
large_path = os.path.join(folder, 'range-data.bin')
with open(large_path, 'wb') as f:
    f.write(bytes(range(256)) * (16 * 1024 * 1024 // 256))

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): print(fmt % args, flush=True)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/jellyfin/Users/AuthenticateByName' and json.loads(body) == {'Username':'fixture','Pw':'fixture'}:
            self.send_json({'AccessToken':'fixture-token', 'User':{'Id':USER}})
        elif self.path == '/jellyfin/Playlists' and 'Token="fixture-token"' in self.headers.get('Authorization', ''):
            data = json.loads(body)
            if data.get('IsPublic') is not False or data.get('Users') != [] or data.get('UserId') != USER or data.get('Ids') != [SONG, SONG]:
                self.send_error(400); return
            with playlist_lock:
                playlists[CREATED] = {'Id': CREATED, 'Name': data['Name'], 'Type': 'Playlist', 'MediaType': 'Audio', 'CanDelete': True, 'ChildCount': 2}
            self.send_json({'Id': CREATED})
        else: self.send_error(401)
    def do_DELETE(self):
        if self.path == '/jellyfin/Items/' + CREATED and 'Token="fixture-token"' in self.headers.get('Authorization', ''):
            with playlist_lock: playlists.pop(CREATED, None)
            self.send_response(204); self.end_headers()
        else: self.send_error(403)
    def send_json(self, obj):
        data = json.dumps(obj).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path == '/radio/live':
            # No Jellyfin credentials may cross into anonymous radio requests.
            if self.headers.get('Authorization'):
                with open(os.path.join(folder, 'radio-auth-failure'), 'w') as f: f.write('unexpected Authorization')
                self.send_error(403); return
            icy = self.headers.get('Icy-MetaData') == '1'
            with open(os.path.join(folder, 'radio-request'), 'w') as f: f.write('ICY' if icy else 'plain')
            self.send_response(200); self.send_header('Content-Type', 'audio/mpeg')
            self.send_header('icy-name', 'Fixture Radio'); self.send_header('icy-br', '64')
            if icy: self.send_header('icy-metaint', '1024')
            self.end_headers()
            with open(os.path.join(os.path.dirname(__file__), 'radio.mp3'), 'rb') as f: audio = f.read()
            metadata = b"StreamTitle='Fixture Artist - Live Track';"
            metadata = bytes([(len(metadata) + 15) // 16]) + metadata.ljust(((len(metadata) + 15) // 16) * 16, b'\0')
            cursor = 0
            try:
                for _ in range(500):
                    chunk = (audio + audio)[cursor:cursor + 1024]; cursor = (cursor + 1024) % len(audio)
                    self.wfile.write(chunk)
                    if icy: self.wfile.write(metadata)
                    self.wfile.flush(); time.sleep(0.128)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if 'Token="fixture-token"' not in self.headers.get('Authorization', ''):
            self.send_error(401); return
        if self.path.startswith('/jellyfin/UserViews'):
            self.send_json({'Items':[{'Id':'music','Name':'Music','CollectionType':'music'}]})
        elif self.path == '/jellyfin/System/Info/Public':
            self.send_json({'Version': '10.10.7'})
        elif self.path.startswith('/jellyfin/Playlists/'):
            self.send_json({'Items': [{'Id': SONG, 'Name': 'Playlist tone', 'Type': 'Audio', 'MediaType': 'Audio', 'AlbumArtist': 'OmaGAWD', 'Album': 'Verification', 'AlbumId': 'verification', 'RunTimeTicks': 450000000}] * 2, 'TotalRecordCount': 2})
        elif self.path.startswith('/jellyfin/Items') and ('IncludeItemTypes=Playlist' in self.path or 'Ids=' in self.path):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            with playlist_lock:
                rows = [dict(row) for key, row in playlists.items() if 'Ids' not in query or key == query['Ids'][0]]
            self.send_json({'Items': rows, 'TotalRecordCount': len(rows)})
        elif self.path.startswith('/jellyfin/Items'):
            self.send_json({'Items':[{'Id':SONG,'Name':'Streaming test tone','AlbumArtist':'OmaGAWD','Album':'Verification','AlbumId':'verification','RunTimeTicks':450000000,'IndexNumber':1}], 'TotalRecordCount':1})
        elif self.path.startswith('/jellyfin/Audio/'):
            audio_id = urllib.parse.urlsplit(self.path).path.split('/')[3]
            with audio_lock:
                audio_counts[audio_id] = audio_counts.get(audio_id, 0) + 1
                attempt = audio_counts[audio_id]
                with open(os.path.join(folder, 'audio-requests.jsonl'), 'a') as f:
                    f.write(json.dumps({'id': audio_id, 'attempt': attempt, 'range': self.headers.get('Range'), 'time': time.monotonic()}) + '\n')
            if audio_id in ('flaky', 'unavailable') and (audio_id == 'unavailable' or attempt <= 2):
                self.send_error(503); return
            if audio_id == 'unauthorized': self.send_error(401); return
            if audio_id == 'redirect-audio':
                self.send_response(302); self.send_header('Location', 'http://127.0.0.1:1/credentials-must-not-reach-here'); self.end_headers(); return
            if audio_id == 'slow-start' and attempt == 1: time.sleep(12)
            audio_path = large_path if audio_id == 'large' else path
            if audio_id == 'mid-delay':
                audio_path = os.path.join(folder, 'long-tone.wav')
                if not os.path.exists(audio_path):
                    with wave.open(path, 'rb') as original:
                        params, tone = original.getparams(), original.readframes(44100 * 45)
                    with wave.open(audio_path, 'wb') as output:
                        output.setparams(params)
                        for _ in range(4): output.writeframes(tone)
            size = os.path.getsize(audio_path); start, end = 0, size-1
            if self.headers.get('Range'):
                a,b = self.headers['Range'].removeprefix('bytes=').split('-'); start=int(a); end=min(int(b) if b else size-1,size-1)
            if start >= size: self.send_error(416); return
            if audio_id == 'mid-delay' and 4 * 1024 * 1024 <= start < 8 * 1024 * 1024:
                with audio_lock:
                    delay = audio_id not in audio_delayed
                    audio_delayed.add(audio_id)
                if delay: time.sleep(12)
            tag = '"changed"' if audio_id == 'changed' and attempt > 1 else '"fixture-v1"'
            first = start + 1 if audio_id == 'bad-range' else start
            self.send_response(206); self.send_header('Content-Type','audio/wav'); self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Range',f'bytes {first}-{end}/{size}'); self.send_header('Content-Length',str(end-start+1)); self.send_header('ETag',tag); self.end_headers()
            try:
                with open(audio_path,'rb') as f:
                    f.seek(start)
                    if audio_id == 'drop' and attempt == 1:
                        self.wfile.write(f.read(128 * 1024)); self.wfile.flush(); self.close_connection = True
                    else: self.wfile.write(f.read(end-start+1))
            except (BrokenPipeError,ConnectionResetError): pass
        elif self.path == '/jellyfin/redirect':
            self.send_response(302); self.send_header('Location','http://127.0.0.1:1/credentials-must-not-reach-here'); self.end_headers()
        else: self.send_error(404)
server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
with open(os.path.join(folder,'port'),'w') as f: f.write(str(server.server_port))
server.serve_forever()
