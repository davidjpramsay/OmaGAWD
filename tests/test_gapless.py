import subprocess
import tempfile
import time
import unittest
import threading
import math
import struct
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from test_backend import Player, FakeMpv, Jellyfin, song
from backend import Mpv
from local_library import LocalLibrary
from stream_proxy import StreamProxy


class GaplessFake(FakeMpv):
    supports_gapless = True
    def clear_next(self): self.commands.append(('clear-next',))
    def append_next(self, url, headers, local): self.commands.append(('append-next', url, headers, local))
    def advance_prefetch(self): self.commands.append(('advance-prefetch',))


class GaplessTests(unittest.TestCase):
    def test_pause_during_gapless_transition_is_preserved(self):
        p = Player(lambda _: None, GaplessFake)
        p.client = Jellyfin('https://example.com'); p.client.user = 'u'
        p.songs = [song(i) for i in range(2)]
        try:
            p.handle({'cmd': 'replace_play', 'ids': ['0', '1']})
            p.event({'event': 'file-loaded'})
            p.event({'event': 'end-file', 'reason': 'eof'})
            p.handle({'cmd': 'pause'})
            self.assertTrue(p.paused)
            p.event({'event': 'start-file'})
            self.assertEqual(p.index, 1)
            self.assertTrue(p.paused)
        finally: p.client = None; p.close()

    def test_real_live_normalization_balances_untagged_music_and_ignores_tags(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            amplitudes = {}
            for name, gain, enabled, tagged in [('quiet_off', .1, False, False), ('loud_off', 4, False, False),
                                               ('quiet_on', .1, True, False), ('loud_on', 4, True, False),
                                               ('tagged_off', 4, False, True)]:
                audio, output = root / (name + '.flac'), root / (name + '.wav')
                args = ['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=4', '-af', 'volume=' + str(gain)]
                if tagged: args += ['-metadata', 'REPLAYGAIN_TRACK_GAIN=-20 dB', '-metadata', 'REPLAYGAIN_ALBUM_GAIN=-20 dB']
                subprocess.run(args + [str(audio)], check=True)
                local = LocalLibrary(root / (name + '.json')); local.add([str(audio)])
                p = Player(lambda _: None, Mpv, local=local); popen = subprocess.Popen
                try:
                    p.local_command({'cmd': 'library', 'folder': 'local'}, 0)
                    p.handle({'cmd': 'normalization', 'value': enabled})
                    p.handle({'cmd': 'volume', 'value': 100})
                    with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: popen(args + ['--ao=pcm', '--untimed', '--ao-pcm-file=' + str(output), '--audio-format=s16'], **kw)):
                        p.handle({'cmd': 'replace_play', 'ids': [p.songs[0]['id']]})
                    deadline = time.monotonic() + 6
                    while time.monotonic() < deadline and not p.idle: time.sleep(.02)
                    self.assertTrue(p.idle, name)
                finally: p.close()
                with wave.open(str(output), 'rb') as f:
                    duration = f.getnframes() / f.getframerate()
                    samples = struct.unpack('<' + 'h' * (f.getnframes() * f.getnchannels()), f.readframes(f.getnframes()))
                self.assertAlmostEqual(duration, 4, delta=.05, msg=name)
                amplitudes[name] = math.sqrt(sum(v*v for v in samples) / len(samples))
                if enabled: self.assertLess(max(abs(v) for v in samples) / 32768, .85, name)
            self.assertGreater(amplitudes['loud_off'] / amplitudes['quiet_off'], 35)
            self.assertAlmostEqual(20 * math.log10(amplitudes['quiet_on'] / amplitudes['loud_on']), 0, delta=1)
            self.assertAlmostEqual(amplitudes['tagged_off'] / amplitudes['loud_off'], 1, delta=.01)

    def test_real_mixed_local_to_authenticated_stream_preserves_policy_and_audio(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); audio = root / 'local.wav'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=0.6', str(audio)], check=True)
            payload = audio.read_bytes(); received = []
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args): pass
                def do_GET(self):
                    received.append((self.path, self.headers.get('Authorization')))
                    if 'Token="private-stream"' not in self.headers.get('Authorization', ''): self.send_error(401); return
                    self.send_response(200); self.send_header('Content-Type', 'audio/wav'); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
            events = []; p = Player(events.append, Mpv); popen = subprocess.Popen
            p.client = Jellyfin(f'http://127.0.0.1:{server.server_port}'); p.client.user, p.client.token = 'u', 'private-stream'
            p.queue_identity = {'url': p.client.url, 'user': 'u'}
            p.queue = [dict(song(0), source='local', id='local:one', path=str(audio), duration=.6, key='local'), dict(song(1), duration=.6, key='remote')]
            try:
                with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: popen(args + ['--ao=null'], **kw)): p.play(0)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and not (p.index == 1 and p.idle): time.sleep(.02)
                self.assertEqual(p.index, 1); self.assertTrue(p.idle); self.assertTrue(received)
                self.assertTrue(all('Token="private-stream"' in h for _,h in received))
                self.assertTrue(any(e.get('index') == 1 and e.get('position', 0) > .1 for e in events))
                self.assertFalse(any(e.get('type') == 'error' for e in events))
            finally: p.client = None; p.close(); server.shutdown(); server.server_close()

    def test_auto_transition_queue_edits_repeat_and_disable(self):
        p = Player(lambda _: None, GaplessFake); p.client = Jellyfin('https://example.com'); p.client.user = 'u'
        p.songs = [song(i) for i in range(3)]
        try:
            p.handle({'cmd': 'replace_play', 'ids': ['0','1','2']}); p.event({'event': 'file-loaded'})
            self.assertEqual(p.prepared_next, p.queue[1]['key'])
            first = p.mpv; loads = len([c for c in first.commands if c[0] == 'loadfile'])
            p.event({'event': 'end-file', 'reason': 'eof'}); p.event({'event': 'start-file'}); p.event({'event': 'file-loaded'})
            self.assertEqual(p.index, 1); self.assertIs(p.mpv, first)
            self.assertEqual(len([c for c in first.commands if c[0] == 'loadfile']), loads)
            p.handle({'cmd': 'remove', 'keys': [p.queue[2]['key']]}); self.assertIsNone(p.prepared_next)
            p.handle({'cmd': 'repeat'}); self.assertEqual(p.prepared_next, p.queue[0]['key'])
            p.handle({'cmd': 'repeat'}); self.assertEqual(p.prepared_next, p.queue[1]['key'])
            p.handle({'cmd': 'gapless', 'value': False}); self.assertIsNone(p.prepared_next)
        finally: p.client = None; p.close()

    def test_radio_stays_live_and_status_retry_uses_fresh_engine(self):
        p = Player(lambda _: None, GaplessFake)
        try:
            p.handle({'cmd': 'library', 'folder': 'radio'}); p.handle({'cmd': 'replace_play', 'ids': ['radio:omarchy']})
            self.assertEqual(p.radio_status, 'connecting'); engine = p.mpv
            p.event({'event': 'file-loaded'}); self.assertEqual(p.radio_status, 'playing'); self.assertIsNone(p.prepared_next)
            p.event({'event': 'property-change', 'name': 'paused-for-cache', 'data': True}); self.assertEqual(p.radio_status, 'buffering')
            p.event({'event': 'property-change', 'name': 'paused-for-cache', 'data': False}); self.assertEqual(p.radio_status, 'playing')
            p.handle({'cmd': 'pause'}); self.assertEqual(p.radio_status, 'paused')
            p.event({'event': 'end-file', 'reason': 'error'}); self.assertEqual(p.radio_status, 'unavailable')
            p.handle({'cmd': 'radio_retry'}); self.assertEqual(p.radio_status, 'connecting'); self.assertIsNot(p.mpv, engine)
        finally: p.close()

    def test_prefetch_keeps_current_authenticated_route_then_promotes(self):
        relay = StreamProxy()
        try:
            current = relay.stream('https://example.com/current', {'Authorization': 'secret'})
            route = relay.route
            following = relay.prefetch('https://example.com/next', {'Authorization': 'secret'})
            self.assertIs(relay.route, route); self.assertNotEqual(current, following)
            self.assertNotIn('secret', following)
            next_route = relay.next_route; relay.advance(); self.assertIs(relay.route, next_route); self.assertIsNone(relay.next_route)
        finally: relay.close()

    def test_real_mpv_continues_two_tracks_without_replace_or_idle_between(self):
        for enabled in (False, True):
            with tempfile.TemporaryDirectory() as d:
                root = Path(d)
                for i in range(2):
                    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', f'sine=frequency={440+i*100}:duration=0.6', '-metadata', 'album=Continuous', str(root / f'{i}.flac')], check=True)
                local = LocalLibrary(root / 'local.json'); local.add([str(root)])
                events = []; p = Player(events.append, Mpv, local=local); popen = subprocess.Popen
                try:
                    p.local_command({'cmd': 'library', 'folder': 'local'}, 0)
                    p.handle({'cmd': 'normalization', 'value': enabled})
                    output = root / 'continuous.wav'
                    audio_options = ['--ao=pcm', '--ao-pcm-file=' + str(output), '--audio-format=s16'] if enabled else ['--ao=null']
                    with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: popen(args + audio_options, **kw)):
                        p.handle({'cmd': 'replace_play', 'ids': [r['id'] for r in p.songs]})
                    engine = p.mpv
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline and not (p.index == 1 and p.idle): time.sleep(.02)
                    self.assertIs(p.mpv, engine); self.assertEqual(p.index, 1); self.assertTrue(p.idle)
                    states = [e for e in events if e.get('type') == 'state']
                    if not enabled:
                        first_started = next(i for i,s in enumerate(states) if s['index'] == 0 and s['position'] > .1)
                        second_started = next(i for i,s in enumerate(states) if s['index'] == 1 and s['position'] > .1)
                        self.assertFalse(any(s['idle'] for s in states[first_started:second_started]))
                    self.assertFalse(any(e.get('type') == 'error' for e in events))
                    if enabled:
                        # Short tracks can fit inside the loudness lookahead. Check
                        # the rendered audio itself, rather than IPC progress ticks.
                        p.discard_engine()
                        with wave.open(str(output), 'rb') as f:
                            rate, channels = f.getframerate(), f.getnchannels()
                            samples = struct.unpack('<' + 'h' * (f.getnframes() * channels), f.readframes(f.getnframes()))[::channels]
                        self.assertAlmostEqual(len(samples) / rate, 1.2, delta=.05)
                        for start, expected in ((.1, 440), (.7, 540)):
                            window = samples[int(start * rate):int((start + .3) * rate)]
                            crossings = sum(a <= 0 < b for a,b in zip(window, window[1:]))
                            self.assertAlmostEqual(crossings / .3, expected, delta=10)
                finally: p.close()
