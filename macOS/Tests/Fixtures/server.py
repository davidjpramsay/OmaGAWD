#!/usr/bin/env python3
"""Disposable Jellyfin/range server. Fixture credentials only; binds loopback."""
import http.server, json, math, os, struct, sys, wave
folder = sys.argv[1]
os.makedirs(folder, exist_ok=True)
path = os.path.join(folder, 'OmaGAWD test tone.wav')
with wave.open(path, 'wb') as f:
    f.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
    f.writeframes(b''.join(struct.pack('<h', int(1200 * math.sin(i * 440 * 2 * math.pi / 44100))) for i in range(44100 * 30)))
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): print(fmt % args, flush=True)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/jellyfin/Users/AuthenticateByName' and json.loads(body) == {'Username':'fixture','Pw':'fixture'}:
            self.send_json({'AccessToken':'fixture-token', 'User':{'Id':'fixture-user'}})
        else: self.send_error(401)
    def send_json(self, obj):
        data = json.dumps(obj).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if 'Token="fixture-token"' not in self.headers.get('Authorization', ''):
            self.send_error(401); return
        if self.path.startswith('/jellyfin/UserViews'):
            self.send_json({'Items':[{'Id':'music','Name':'Music','CollectionType':'music'}]})
        elif self.path.startswith('/jellyfin/Items'):
            self.send_json({'Items':[{'Id':'tone','Name':'Streaming test tone','AlbumArtist':'OmaGAWD','Album':'Verification','AlbumId':'verification','RunTimeTicks':300000000,'IndexNumber':1}], 'TotalRecordCount':1})
        elif self.path.startswith('/jellyfin/Audio/tone/stream'):
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
