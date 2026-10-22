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
        elif self.path.startswith('/jellyfin/Audio/tone/stream') or self.path.startswith('/jellyfin/Audio/' + SONG + '/stream'):
            size = os.path.getsize(path); start, end = 0, size-1
            if self.headers.get('Range'):
                a,b = self.headers['Range'].removeprefix('bytes=').split('-'); start=int(a); end=min(int(b) if b else size-1,size-1)
            self.send_response(206); self.send_header('Content-Type','audio/wav'); self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Range',f'bytes {start}-{end}/{size}'); self.send_header('Content-Length',str(end-start+1)); self.end_headers()
            try:
                with open(path,'rb') as f: f.seek(start); self.wfile.write(f.read(end-start+1))
            except (BrokenPipeError,ConnectionResetError): pass
        elif self.path == '/jellyfin/redirect':
            self.send_response(302); self.send_header('Location','http://127.0.0.1:1/credentials-must-not-reach-here'); self.end_headers()
        else: self.send_error(404)
server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
with open(os.path.join(folder,'port'),'w') as f: f.write(str(server.server_port))
server.serve_forever()
