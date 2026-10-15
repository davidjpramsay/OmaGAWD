"""Daily-use sequences against real mpv and isolated persistent settings."""
import json
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from backend import Mpv, Player
from collection_store import CollectionStore
from drop_receiver import paths_from_uris
from local_library import LocalLibrary
from playback_store import PlaybackStore
from preferences import Preferences
import radio_library as radio


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate(): return True
        time.sleep(.02)
    return predicate()


class DailyUseTests(unittest.TestCase):
    def test_drop_source_switch_save_and_full_restart_preserve_music(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); album = root / 'Album'; album.mkdir()
            for i in range(2):
                subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=4',
                                '-metadata', 'artist=Fixture Artist', '-metadata', 'album=Continuous Album',
                                '-metadata', 'title=Part ' + str(i + 1), '-metadata', 'track=' + str(i + 1),
                                '-metadata', 'REPLAYGAIN_ALBUM_GAIN=-6 dB', str(album / (str(i) + '.flac'))], check=True)
            added = root / 'Added'; added.mkdir(); (added / 'copy.flac').write_bytes((album / '0.flac').read_bytes())
            local = LocalLibrary(root / 'local.json'); local.add([str(album)])
            prefs = Preferences(root / 'preferences.json')
            events = []
            def player():
                return Player(events.append, Mpv, local=LocalLibrary(local.path), preferences=prefs,
                              playback_store=PlaybackStore(root / 'session.json'), collections=CollectionStore(root / 'collections.json'))
            p = player(); original_popen = subprocess.Popen
            try:
                p.local_command({'cmd': 'library', 'folder': 'local'}, p.generation)
                p.handle({'cmd': 'normalization', 'value': True})
                with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: original_popen(args + ['--ao=null'], **kw)):
                    p.handle({'cmd': 'replace_play', 'ids': [row['id'] for row in p.songs]})
                self.assertTrue(wait_for(lambda: p.file_loaded and p.position > .15))
                engine, keys = p.mpv, [r['key'] for r in p.queue]
                p.handle({'cmd': 'playlist_save', 'name': 'Daily GAWD'}); p.collection_future.result(timeout=3)
                p.handle({'cmd': 'library', 'folder': 'radio'})
                self.assertIs(p.mpv, engine); self.assertEqual([r['key'] for r in p.queue], keys)
                paths = paths_from_uris(added.as_uri().encode())
                with patch('backend.run_bounded', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(paths).encode())):
                    p.local_command({'cmd': 'choose_drop'}, p.generation)
                self.assertIs(p.mpv, engine); self.assertEqual([r['key'] for r in p.queue], keys)
                self.assertEqual(len(p.songs), 3)
                p.handle({'cmd': 'pause'})
                self.assertTrue(wait_for(lambda: p.paused))
                p.handle({'cmd': 'seek', 'seconds': 1.25})
                self.assertTrue(wait_for(lambda: abs(p.position - 1.25) < .1))
                position = p.position
                p.close(); p = player()
                self.assertIsNone(p.mpv); self.assertTrue(p.paused); self.assertTrue(p.session_pending)
                self.assertEqual([r['key'] for r in p.queue], keys)
                self.assertAlmostEqual(p.position, position, delta=.15)
                self.assertTrue(p.normalization)
                saved = p.collections.summary()['playlists'][0]['id']
                p.handle({'cmd': 'collection_load', 'id': saved, 'play': False})
                self.assertTrue(p.paused); self.assertIsNone(p.mpv); self.assertEqual(p.position, 0)
                before = list(p.queue)
                p.handle({'cmd': 'playlist_delete', 'id': saved}); p.collection_future.result(timeout=3)
                self.assertEqual(p.queue, before); self.assertTrue((album / '0.flac').exists())
                self.assertFalse(any(e.get('type') == 'error' for e in events), events)
            finally: p.close()

    def test_radio_failure_then_retry_recovers_with_fresh_engine(self):
        with tempfile.TemporaryDirectory() as d:
            audio = Path(d) / 'radio.wav'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=2', str(audio)], check=True)
            payload = audio.read_bytes(); healthy = threading.Event()
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args): pass
                def do_GET(self):
                    if not healthy.is_set(): self.send_error(503); return
                    self.send_response(200); self.send_header('Content-Type', 'audio/wav')
                    self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            p = Player(lambda _: None, Mpv); original_popen = subprocess.Popen
            station = radio.make_station('Fixture Radio', 'http://127.0.0.1:' + str(server.server_port) + '/stream')
            p.songs = [station]
            try:
                with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: original_popen(args + ['--ao=null'], **kw)):
                    p.handle({'cmd': 'replace_play', 'ids': [station['id']]})
                    failed_engine = p.mpv
                    self.assertTrue(wait_for(lambda: p.radio_status == 'unavailable'))
                    healthy.set(); p.handle({'cmd': 'radio_retry'})
                    self.assertTrue(wait_for(lambda: p.radio_status == 'playing'))
                self.assertIsNot(p.mpv, failed_engine)
                self.assertEqual((p.position, p.duration), (0, 0))
            finally: p.close(); server.shutdown(); server.server_close()
