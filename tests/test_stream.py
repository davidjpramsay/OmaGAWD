"""End-to-end mpv decoding over an authenticated HTTP stream, with silent output."""
import io
import math
import struct
import shutil
import subprocess
import threading
import time
import unittest
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
from test_backend import Player, Jellyfin, song


@unittest.skipUnless(shutil.which('mpv'), 'mpv is required')
class StreamTests(unittest.TestCase):
    def test_authenticated_stream_decodes_and_reaches_eof(self):
        audio = io.BytesIO()
        with wave.open(audio, 'wb') as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(8000)
            wav.writeframes(b''.join(struct.pack('<h', int(12000 * math.sin(2 * math.pi * 440 * i / 8000))) for i in range(16000)))
        payload = audio.getvalue()
        received = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                received.append((self.path, self.headers.get('Authorization')))
                if 'Token="stream-token"' not in self.headers.get('Authorization', ''):
                    self.send_error(401); return
                self.send_response(200)
                self.send_header('Content-Type', 'audio/wav')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers(); self.wfile.write(payload)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        events = []
        player = Player(events.append)
        player.client = Jellyfin('http://127.0.0.1:' + str(server.server_port))
        player.client.token = 'stream-token'
        player.songs = [song(1)]
        real_popen = subprocess.Popen
        try:
            with patch('backend.subprocess.Popen', side_effect=lambda args, **kwargs: real_popen(args + ['--ao=null'], **kwargs)):
                player.handle({'cmd': 'add', 'ids': ['1']})
                player.handle({'cmd': 'play', 'index': 0})
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if any(e.get('position', 0) > .5 for e in events) and player.idle:
                    break
                player.handle({'cmd': 'meter'})
                time.sleep(.05)
            self.assertTrue(received, 'mpv must request the stream')
            self.assertEqual(received[0][0], '/Audio/1/stream?static=true')
            self.assertIn('Token="stream-token"', received[0][1])
            self.assertTrue(any(e.get('position', 0) > .5 for e in events), 'mpv must decode audio and report progress')
            self.assertTrue(any(e.get('type') == 'meter' and max(e['levels']) > 0.1 for e in events), 'visualizer must measure actual decoded audio')
            frames = [e['levels'] for e in events if e.get('type') == 'meter' and max(e['levels']) > .1]
            peak = max(range(16), key=lambda i: sum(f[i] for f in frames))
            self.assertIn(peak, (5, 6), '440 Hz must light its frequency band, not all bars equally')
            self.assertTrue(player.idle, 'playlist must stop after EOF without repeat')
            self.assertFalse(any(e.get('type') == 'error' for e in events))
        finally:
            player.client = None; player.close()
            server.shutdown(); server.server_close()
