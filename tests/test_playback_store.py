import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from playback_store import PlaybackStore, validate
from test_backend import FakeMpv, Jellyfin, Player, song


def snapshot(local_path=None):
    row = dict(song(1), key='first')
    if local_path:
        row.update(id='local:one', source='local', path=str(local_path))
    return {'queue': [row, dict(row, key='duplicate')], 'index': 1, 'position': 42,
            'idle': False, 'folder': 'local' if local_path else 'music',
            'library': None if local_path else {'url': 'https://example.com', 'user': 'u'}}


class PlaybackStoreTests(unittest.TestCase):
    def test_atomic_private_snapshot_strips_secrets_and_preserves_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            store = PlaybackStore(Path(directory) / 'session.json')
            data = snapshot()
            data['password'] = data['library']['token'] = data['queue'][0]['token'] = 'private'
            try:
                store.write(data)
                self.assertNotIn('private', store.path.read_text())
                self.assertEqual(store.path.stat().st_mode & 0o777, 0o600)
                self.assertEqual([row['key'] for row in store.load()['queue']], ['first', 'duplicate'])
                before = store.path.read_bytes()
                with patch('playback_store.os.replace', side_effect=OSError('Disk full')):
                    with self.assertRaises(OSError): store.write(dict(data, position=50))
                self.assertEqual(store.path.read_bytes(), before)
                self.assertEqual(len(list(Path(directory).iterdir())), 1)
            finally: store.close(data)

    def test_invalid_and_oversized_sessions_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            store = PlaybackStore(Path(directory) / 'session.json')
            try:
                invalid = [dict(snapshot(), index=10), dict(snapshot(), position=float('nan')),
                           dict(snapshot(), library=None)]
                duplicate = snapshot()
                duplicate['queue'][1]['key'] = 'first'
                invalid.append(duplicate)
                secret_url = snapshot()
                secret_url['library']['url'] += '?token=secret'
                invalid.append(secret_url)
                for data in invalid:
                    store.path.write_text(json.dumps(data))
                    self.assertIsNone(store.load())
                store.path.write_bytes(b'x' * 257)
                with patch('playback_store.MAX_SESSION_BYTES', 256): self.assertIsNone(store.load())
                with patch('playback_store.MAX_QUEUE_TRACKS', 1):
                    with self.assertRaises(ValueError): validate(snapshot())
            finally: store.close(snapshot())

    def test_writes_coalesce_to_latest_and_recover_after_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            store = PlaybackStore(Path(directory) / 'session.json')
            started, release, finished = threading.Event(), threading.Event(), threading.Event()
            original = store.write
            written = []
            def delayed(data):
                written.append(data['position'])
                if len(written) == 1:
                    started.set()
                    if not release.wait(3): raise RuntimeError('Test timed out')
                    raise OSError('Disk full')
                original(data)
                finished.set()
            try:
                with patch.object(store, 'write', side_effect=delayed):
                    store.save(snapshot())
                    self.assertTrue(started.wait(3))
                    for position in range(43, 100): store.save(dict(snapshot(), position=position))
                    release.set()
                    self.assertTrue(finished.wait(3))
                    self.assertEqual(store.load()['position'], 99)
                    self.assertEqual(written, [42, 99])
                    self.assertIsInstance(store.take_error(), OSError)
                    self.assertIsNone(store.take_error())
            finally:
                release.set()
                store.close(dict(snapshot(), position=99))


class PlaybackRecoveryTests(unittest.TestCase):
    def player(self, directory, data, **kwargs):
        store = PlaybackStore(Path(directory) / 'session.json')
        store.write(data)
        player = Player(lambda _: None, FakeMpv, playback_store=store, **kwargs)
        self.addCleanup(player.close)
        return player

    def test_remote_restores_paused_and_resumes_only_for_original_account(self):
        with tempfile.TemporaryDirectory() as directory:
            player = self.player(directory, snapshot())
            self.assertIsNone(player.mpv)
            self.assertTrue(player.paused)
            self.assertFalse(player.idle)
            self.assertEqual((player.index, player.position), (1, 42))
            player.client = Jellyfin('https://example.com')
            player.client.user = 'other-user'
            player.handle({'cmd': 'play'})
            self.assertIsNone(player.mpv)
            player.client.user = 'u'
            player.remembered = True
            player.handle({'cmd': 'seek', 'seconds': 55})
            player.handle({'cmd': 'pause'})
            self.assertFalse(player.paused)
            self.assertEqual(player.mpv.start, 55)
            self.assertEqual(player.position, 55)
            player.close()
            restored = self.player(directory, snapshot())
            restored.handle({'cmd': 'remove', 'keys': ['duplicate']})
            self.assertFalse(restored.session_pending)
            self.assertTrue(restored.idle)
            restored.close()

    def test_local_restores_without_keyring_and_missing_file_stops_cleanly(self):
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / 'one.wav'
            audio.touch()
            local = Mock(prefer_local=False)
            player = self.player(directory, snapshot(audio), local=local)
            self.assertTrue(local.prefer_local)
            player.handle({'cmd': 'play'})
            self.assertEqual(player.mpv.start, 42)
            self.assertIsNone(player.client)
            self.assertIn(('set_property', 'http-header-fields', []), player.mpv.commands)
            player.handle({'cmd': 'stop'})
            audio.unlink()
            player.handle({'cmd': 'play'})
            self.assertTrue(player.idle)
            player.handle({'cmd': 'clear'})
            self.assertFalse(player.session_pending)
            player.close()

    def test_startup_keyring_failure_can_retry_without_replacing_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            account = Mock()
            account.load.side_effect = [RuntimeError('Keyring locked'),
                {'url': 'https://example.com', 'username': 'Example', 'token': 'saved', 'user': 'u', 'device': 'd'}]
            events = []
            player = self.player(directory, snapshot(), store=account)
            player.emit = events.append
            player.network({'cmd': 'restore'}, 0)
            self.assertIn({'type': 'restore_retry', 'value': True}, events)
            original = list(player.queue)
            player.handle({'cmd': 'remove', 'keys': ['first']})
            with patch.object(Jellyfin, 'request', return_value={}), patch.object(Jellyfin, 'libraries', return_value=[{'id': 'music'}]), patch.object(Jellyfin, 'songs', return_value=[]):
                player.network({'cmd': 'restore'}, 0)
            self.assertIn({'type': 'restore_retry', 'value': False}, events)
            self.assertEqual(player.queue, [original[1]])
            self.assertEqual(player.position, 42)
            self.assertIsNone(player.mpv)
            player.close()
