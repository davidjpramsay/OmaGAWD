import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
from test_backend import Player, FakeMpv, Jellyfin, song
from local_library import LocalLibrary


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'requires ffmpeg')
class LocalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.music = self.root / 'music'
        self.music.mkdir()
        self.audio = self.music / '01 sample.flac'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.2',
                        '-metadata', 'title=Sample Track', '-metadata', 'artist=Test Artist',
                        '-metadata', 'album=Test Album', '-metadata', 'track=1/10', str(self.audio)], check=True)
        self.local = LocalLibrary(self.root / 'config/local.json')
    def tearDown(self):
        self.temp.cleanup()
    def test_tags_deduplication_saved_sources_and_changes(self):
        self.local.add([str(self.music), str(self.audio)])
        songs, skipped = self.local.scan()
        self.assertEqual(len(songs), 1)
        self.assertEqual(skipped, 0)
        self.assertEqual((songs[0]['title'], songs[0]['artist'], songs[0]['album'], songs[0]['track']),
                         ('Sample Track', 'Test Artist', 'Test Album', 1))
        self.assertGreater(songs[0]['duration'], 0)
        restored = LocalLibrary(self.local.path)
        self.assertTrue(restored.prefer_local)
        self.assertEqual(restored.scan()[0], songs)
        with patch('local_library.probe_output', side_effect=AssertionError('unchanged file should be cached')):
            self.assertEqual(self.local.scan()[0], songs)
        (self.music / 'bad.mp3').write_text('not audio')
        self.assertEqual(self.local.scan()[1], 1)
        self.audio.unlink()
        self.assertEqual(self.local.scan()[0], [])
    def test_forgetting_source_keeps_files_and_playback(self):
        events = []
        p = Player(events.append, FakeMpv, local=self.local)
        try:
            p.local_command({'cmd': 'local_add', 'paths': [str(self.music)]}, 0)
            p.handle({'cmd': 'replace_play', 'ids': [p.songs[0]['id']]})
            queue = list(p.queue)
            p.local_command({'cmd': 'local_remove', 'paths': [str(self.music)]}, 0)
            self.assertTrue(self.audio.exists())
            self.assertEqual(p.queue, queue)
            self.assertFalse(p.idle)
            self.assertEqual(p.songs, [])
            self.assertEqual(LocalLibrary(self.local.path).roots, [])
            self.assertIn({'type': 'local_sources', 'available': False, 'paths': []}, events)
        finally: p.close()

    def test_untagged_file_uses_filename_and_directory(self):
        audio = self.music / 'plain.wav'
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(self.audio), '-map_metadata', '-1', str(audio)], check=True)
        self.local.add([str(audio)])
        track = self.local.scan()[0][0]
        self.assertEqual(track['title'], 'plain')
        self.assertEqual(track['artist'], 'Unknown artist')
        self.assertEqual(track['album'], 'music')
    def test_offline_local_import_and_playback_clears_remote_headers(self):
        events = []
        p = Player(events.append, FakeMpv, local=self.local)
        try:
            p.client = Jellyfin('https://example.com')
            p.client.token = 'private-token'
            p.songs = [song(0)]
            p.handle({'cmd': 'replace_play', 'ids': ['0']})
            p.local_command({'cmd': 'local_add', 'paths': [str(self.music)]}, p.generation)
            self.assertIn({'type': 'local_sources', 'available': True, 'paths': [str(self.music)]}, events)
            p.client = None
            track = p.songs[0]
            p.handle({'cmd': 'replace_play', 'ids': [track['id']]})
            self.assertFalse(p.idle)
            self.assertIn(('set_property', 'http-header-fields', []), p.mpv.commands)
            self.assertIn(('loadfile', str(self.audio), 'replace'), p.mpv.commands)
            self.assertTrue(any(e.get('folder') == 'local' for e in events))
            p.local_command({'cmd': 'library', 'folder': 'local'}, p.generation)
            self.assertFalse(p.idle)
        finally:
            p.client = None
            p.close()
    def test_real_local_file_decodes_without_jellyfin(self):
        from backend import Mpv
        events = []
        p = Player(events.append, Mpv, local=self.local)
        real_popen = subprocess.Popen
        try:
            p.local_command({'cmd': 'local_add', 'paths': [str(self.audio)]}, 0)
            with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: real_popen(args + ['--ao=null'], **kw)):
                p.handle({'cmd': 'replace_play', 'ids': [p.songs[0]['id']]})
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not (p.idle and any(e.get('duration', 0) > 0 for e in events)):
                time.sleep(.05)
            self.assertTrue(any(e.get('duration', 0) > 0 for e in events))
            self.assertTrue(p.idle)
            self.assertFalse(any(e.get('type') == 'error' for e in events))
        finally: p.close()

    def test_folder_picker_uses_desktop_defaults_and_imports_selection(self):
        events = []
        p = Player(events.append, FakeMpv, local=self.local)
        real_run = subprocess.run
        calls = []
        def run(args, **kwargs):
            if args[0] == 'zenity':
                calls.append((args, kwargs))
                return Mock(returncode=0, stdout=str(self.music) + '\n', stderr='')
            return real_run(args, **kwargs)
        try:
            with patch('backend.subprocess.run', side_effect=run):
                p.local_command({'cmd': 'choose_folder'}, 0)
            self.assertIn('--directory', calls[0][0])
            self.assertNotIn('env', calls[0][1])
            self.assertEqual(len(p.songs), 1)
            self.assertEqual(events[-1], {'type': 'picker_closed'})
        finally: p.close()

    def test_cancelled_picker_does_not_add_sources(self):
        events = []
        p = Player(events.append, FakeMpv, local=self.local)
        try:
            with patch('backend.subprocess.run', return_value=Mock(returncode=1)):
                p.local_command({'cmd': 'choose_folder'}, 0)
            self.assertEqual(self.local.roots, [])
            self.assertFalse(any(e.get('type') == 'error' for e in events))
            self.assertEqual(events[-1], {'type': 'picker_closed'})
        finally: p.close()

    def test_restore_local_source_without_jellyfin(self):
        self.local.add([str(self.music)])
        store = Mock(); store.load.return_value = None
        events = []
        p = Player(events.append, FakeMpv, store, self.local)
        try:
            p.network({'cmd': 'restore'}, 0)
            self.assertEqual(len(p.songs), 1)
            self.assertTrue(any(e.get('folder') == 'local' for e in events))
        finally: p.close()
    def test_saved_local_source_wins_over_jellyfin_on_restart(self):
        self.local.add([str(self.music)])
        store = Mock()
        store.load.return_value = {'url':'https://example.com','username':'test','token':'token','user':'u','device':'d','folder':'remote'}
        p = Player(lambda e: None, FakeMpv, store, self.local)
        try:
            with patch.object(Jellyfin, 'request', return_value={}), patch.object(Jellyfin, 'libraries', return_value=[{'id':'remote','name':'Music'}]), patch.object(Jellyfin, 'songs') as remote:
                p.network({'cmd':'restore'},0)
                remote.assert_not_called()
                self.assertEqual(p.songs[0]['source'], 'local')
        finally: p.close()
