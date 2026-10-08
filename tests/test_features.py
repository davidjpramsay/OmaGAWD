import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from test_backend import FakeMpv, Player, song
from preferences import Preferences
from local_library import LocalLibrary


class FeatureTests(unittest.TestCase):
    def test_preferences_round_trip_and_no_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            prefs = Preferences(Path(directory) / 'playback.json')
            player = Player(lambda _: None, FakeMpv, preferences=prefs)
            try:
                player.handle({'cmd': 'volume', 'value': 37})
                player.handle({'cmd': 'shuffle'})
                player.handle({'cmd': 'repeat'})
                player.handle({'cmd': 'repeat'})
            finally:
                player.close()
            restored = Player(lambda _: None, FakeMpv, preferences=prefs)
            try:
                self.assertEqual((restored.volume, restored.shuffle, restored.repeat), (37, True, 'one'))
                self.assertEqual(restored.queue, [])
                self.assertEqual(set(json.loads(prefs.path.read_text())), {'volume', 'shuffle', 'repeat'})
            finally:
                restored.close()

    def test_invalid_preferences_and_atomic_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            prefs = Preferences(Path(directory) / 'playback.json')
            defaults = prefs.load()
            for raw in ('{', '[]', 'x' * 4097, '{"volume":NaN,"shuffle":"yes","repeat":"wrong"}', '{"volume":true}'):
                prefs.path.write_text(raw)
                self.assertEqual(prefs.load(), defaults)
            prefs.save(40, True, 'all')
            before = prefs.path.read_bytes()
            with patch('preferences.os.replace', side_effect=OSError('Disk full')):
                with self.assertRaises(OSError): prefs.save(50, False, 'off')
            self.assertEqual(prefs.path.read_bytes(), before)
            self.assertEqual(len(list(Path(directory).iterdir())), 1)

    def test_save_failure_keeps_live_settings(self):
        messages = []
        with tempfile.TemporaryDirectory() as directory:
            prefs = Preferences(Path(directory) / 'playback.json')
            player = Player(messages.append, FakeMpv, preferences=prefs)
            try:
                with patch.object(prefs, 'save', side_effect=OSError):
                    player.handle({'cmd': 'volume', 'value': 25})
                self.assertEqual(player.volume, 25)
                self.assertTrue(any(m['type'] == 'error' for m in messages))
                with self.assertRaises(ValueError): player.handle({'cmd': 'volume', 'value': float('nan')})
                self.assertEqual(player.volume, 25)
            finally: player.close()

    def test_visibility_preserves_playback(self):
        player = Player(lambda _: None, FakeMpv)
        try:
            player.mpv = FakeMpv(None)
            player.queue = [dict(song(1), key='one')]
            player.index, player.position, player.idle, player.paused = 0, 42, False, False
            player.handle({'cmd': 'visibility', 'visible': True})
            self.assertTrue(player.mpv.meter_enabled)
            player.handle({'cmd': 'visibility', 'visible': False})
            self.assertFalse(player.mpv.meter_enabled)
            self.assertEqual((player.index, player.position, player.paused), (0, 42, False))
            player.handle({'cmd': 'visibility', 'visible': True})
            player.handle({'cmd': 'pause'})
            self.assertFalse(player.mpv.meter_enabled)
            player.handle({'cmd': 'pause'})
            self.assertTrue(player.mpv.meter_enabled)
            player.handle({'cmd': 'stop'})
            self.assertFalse(player.mpv.meter_enabled)
        finally: player.close()

    def test_local_limit_counts_unique_paths_before_probing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for i in range(3): (root / f'{i}.mp3').touch()
            local = LocalLibrary(root / 'local.json')
            local.roots = [str(root), str(root / '0.mp3')]
            with patch('local_library.MAX_LOCAL_TRACKS', 2), patch('local_library.probe_output') as probe:
                with self.assertRaisesRegex(ValueError, 'exceeds 2 tracks'): local.scan()
                probe.assert_not_called()
            metadata = b'{"streams":[{"codec_type":"audio"}],"format":{}}'
            with patch('local_library.MAX_LOCAL_TRACKS', 3), patch('local_library.probe_output', return_value=metadata) as probe:
                songs, skipped = local.scan()
                self.assertEqual((len(songs), skipped, probe.call_count), (3, 0, 3))

    def test_real_mpv_meter_removal_and_resume(self):
        import math
        import struct
        import subprocess
        import time
        import wave
        from backend import Mpv
        def wait_for(predicate):
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                if predicate(): return True
                time.sleep(.02)
            return False
        original_popen = subprocess.Popen
        def silent_process(args, **kwargs):
            return original_popen(args + ['--ao=null'], **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / 'tone.wav'
            with wave.open(str(audio), 'wb') as stream:
                stream.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
                second = b''.join(struct.pack('<h', int(10000 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(48000))
                stream.writeframes(second * 15)
            events = []
            with patch('backend.subprocess.Popen', side_effect=silent_process):
                engine = Mpv(events.append)
            try:
                engine.load(str(audio), [])
                engine.set_meter(True)
                self.assertTrue(wait_for(lambda: max(engine.spectrum) > .1), 'Real spectrum did not start')
                engine.set_meter(False)
                engine.send('get_property', 'af')
                self.assertTrue(wait_for(lambda: any(e.get('data') == [] for e in events)), 'Analysis filter remained installed')
                self.assertEqual(engine.spectrum, [0.0] * 16)
                positions = lambda: [e['data'] for e in events if e.get('name') == 'time-pos' and isinstance(e.get('data'), (int, float))]
                self.assertTrue(wait_for(lambda: bool(positions())))
                before = positions()[-1]
                self.assertTrue(wait_for(lambda: positions()[-1] > before + .15), 'Playback stopped while hidden')
                engine.set_meter(True)
                self.assertTrue(wait_for(lambda: max(engine.spectrum) > .1), 'Spectrum did not resume')
            finally:
                engine.close()
