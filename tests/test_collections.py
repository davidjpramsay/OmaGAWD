import json
import tempfile
import unittest
import threading
from pathlib import Path
from unittest.mock import patch
from collection_store import CollectionStore
from preferences import Preferences
from test_backend import Player, FakeMpv, Jellyfin, song
from test_playback_store import snapshot
from drop_receiver import paths_from_uris, read_drop, MAX_BYTES


class CollectionTests(unittest.TestCase):
    def test_clearing_history_allows_same_album_to_be_remembered_again(self):
        p = Player(lambda _: None, FakeMpv)
        p.client = Jellyfin('https://example.com'); p.client.user = 'u'
        p.songs = [dict(song(i), albumId='album') for i in range(2)]
        try:
            p.handle({'cmd': 'replace_play', 'ids': ['0', '1']})
            p.event({'event': 'file-loaded'})
            p.collection_work.submit(lambda: None).result()
            p.handle({'cmd': 'recent_clear'}); p.collection_future.result(timeout=2)
            self.assertEqual(p.collections.summary()['recent'], [])
            p.play(1); p.event({'event': 'file-loaded'})
            p.collection_work.submit(lambda: None).result()
            self.assertEqual(len(p.collections.summary()['recent']), 1)
        finally: p.client = None; p.close()

    def test_collection_edit_work_is_single_in_flight(self):
        gate = threading.Event(); entered = threading.Event(); events = []
        store = CollectionStore(memory=True); p = Player(events.append, FakeMpv, collections=store)
        p.client = Jellyfin('https://example.com'); p.client.user = 'u'
        p.queue, p.queue_identity = snapshot()['queue'], snapshot()['library']
        original = store.add
        def delayed(*args): entered.set(); gate.wait(2); return original(*args)
        try:
            with patch.object(store, 'add', side_effect=delayed):
                p.handle({'cmd': 'playlist_save', 'name': 'First'}); self.assertTrue(entered.wait(1))
                p.handle({'cmd': 'playlist_save', 'name': 'Second'})
                self.assertIn('still being saved', events[-1]['message'])
                gate.set(); p.collection_future.result(timeout=2)
            self.assertEqual([r['name'] for r in store.summary()['playlists']], ['First'])
        finally: gate.set(); p.client = None; p.close()

    def test_named_playlists_are_private_strip_secrets_and_roll_back_save_failure(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'collections.json'; store = CollectionStore(path)
            data = snapshot(); data['queue'][0]['token'] = 'private-token'; data['library']['password'] = 'private-password'
            key = store.add('Driving', data)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn('private-', path.read_text())
            self.assertEqual(CollectionStore(path).get('playlists', key)['queue'][0]['title'], 'Song 1')
            before = path.read_bytes()
            with patch('collection_store.os.replace', side_effect=OSError('Full')):
                with self.assertRaises(OSError): store.rename(key, 'Changed')
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(store.summary()['playlists'][0]['name'], 'Driving')
            store.rename(key, 'GAWD'); self.assertEqual(store.summary()['playlists'][0]['name'], 'GAWD')
            with self.assertRaises(ValueError): store.add('gawd', data)
            store.remove(key); self.assertEqual(store.summary()['playlists'], [])

    def test_limits_recovery_and_recent_deduplication(self):
        store = CollectionStore(memory=True)
        with patch('collection_store.MAX_PLAYLISTS', 1):
            store.add('One', snapshot())
            with self.assertRaises(ValueError): store.add('Two', snapshot())
        with patch('collection_store.MAX_SESSION_BYTES', 20):
            with self.assertRaises(ValueError): store.rename(store.data['playlists'][0]['id'], 'Longer')
        for group in ('a', 'b', 'a'): store.recent(group, group, snapshot())
        self.assertEqual([r['name'] for r in store.summary()['recent']], ['a', 'b'])
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'collections.json'; path.write_text('broken')
            restored = CollectionStore(path)
            self.assertTrue(restored.warning); self.assertTrue(list(Path(d).glob('*.damaged-*')))
            restored.add('Recovered', snapshot())
            path.write_text('broken')
            with patch('pathlib.Path.rename', side_effect=OSError('Read-only')): blocked = CollectionStore(path)
            with self.assertRaises(RuntimeError): blocked.add('Blocked', snapshot())
            self.assertEqual(path.read_text(), 'broken')

    def test_loading_enforces_account_and_forgetting_keeps_queue_and_media(self):
        with tempfile.TemporaryDirectory() as d:
            audio = Path(d) / 'song.flac'; audio.write_bytes(b'fixture')
            store = CollectionStore(memory=True); remote = store.add('Remote', snapshot()); local = store.add('Local', snapshot(audio))
            events = []; p = Player(events.append, FakeMpv, collections=store)
            try:
                p.queue = [dict(song(0), key='current')]; before = list(p.queue)
                p.handle({'cmd': 'collection_load', 'id': remote, 'play': False})
                self.assertEqual(p.queue, before)
                self.assertIn('Jellyfin account', events[-1]['message'])
                p.client = Jellyfin('https://example.com'); p.client.user = 'u'
                p.handle({'cmd': 'collection_load', 'id': remote, 'play': False})
                self.assertTrue(p.paused); self.assertIsNone(p.mpv); self.assertEqual(p.position, 0)
                p.handle({'cmd': 'collection_load', 'id': local, 'play': True})
                self.assertFalse(p.idle); queue = list(p.queue); engine = p.mpv
                p.handle({'cmd': 'playlist_delete', 'id': local}); p.collection_work.shutdown(wait=True)
                self.assertEqual(p.queue, queue); self.assertIs(p.mpv, engine); self.assertTrue(audio.exists())
            finally: p.client = None; p.close()

    def test_history_records_album_once_and_can_be_disabled_and_cleared(self):
        p = Player(lambda _: None, FakeMpv)
        p.client = Jellyfin('https://example.com'); p.client.user = 'u'
        p.songs = [dict(song(i), albumId='album') for i in range(2)]
        try:
            p.handle({'cmd': 'replace_play', 'ids': ['0','1']})
            p.event({'event': 'file-loaded'})
            p.play(1); p.event({'event': 'file-loaded'})
            p.collection_work.submit(lambda: None).result()
            recent = p.collections.summary()['recent']; self.assertEqual(len(recent), 1); self.assertEqual(recent[0]['count'], 2)
            p.handle({'cmd': 'keep_recent', 'value': False})
            p.songs = [dict(song(2), albumId='other')]; p.handle({'cmd': 'replace_play', 'ids': ['2']}); p.event({'event': 'file-loaded'})
            self.assertEqual(p.collections.summary()['recent'], recent)
            p.handle({'cmd': 'recent_clear'}); p.collection_work.submit(lambda: None).result()
            self.assertEqual(p.collections.summary()['recent'], [])
        finally: p.client = None; p.close()

    def test_new_settings_round_trip_and_apply_without_restarting_audio(self):
        with tempfile.TemporaryDirectory() as d:
            prefs = Preferences(Path(d) / 'playback.json'); p = Player(lambda _: None, FakeMpv, preferences=prefs)
            p.queue = [dict(song(0), key='first')]; p.client = Jellyfin('https://example.com')
            try:
                p.play(0); engine = p.mpv
                p.handle({'cmd': 'gapless', 'value': False}); p.handle({'cmd': 'replay_gain', 'value': 'album'}); p.handle({'cmd': 'keep_recent', 'value': False})
                self.assertIs(p.mpv, engine)
                self.assertIn(('set_property', 'options/replaygain', 'album'), engine.commands)
                restored = prefs.load(); self.assertFalse(restored['gapless']); self.assertEqual(restored['replayGain'], 'album'); self.assertFalse(restored['keepRecent'])
                with self.assertRaises(ValueError): p.handle({'cmd': 'replay_gain', 'value': 'invalid'})
            finally: p.client = None; p.close()


class DropTests(unittest.TestCase):
    def test_async_drop_reader_bounds_payload_and_stalled_offers(self):
        import gi
        gi.require_version('Gdk', '4.0')
        from gi.repository import Gio, GLib
        class Offer:
            def __init__(self, body, stalled=False): self.body, self.stalled, self.finished = body, stalled, []
            def read_async(self, types, priority, cancel, callback):
                self.types = types
                if not self.stalled: GLib.idle_add(lambda: (callback(self, None), False)[1])
            def read_finish(self, result): return Gio.MemoryInputStream.new_from_data(self.body, None), 'text/uri-list'
            def finish(self, action): self.finished.append(action)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'song.flac'; path.write_bytes(b'fixture')
            for body, stalled, good in ((path.as_uri().encode(), False, True), (b'x' * (MAX_BYTES + 1), False, False), (b'', True, False)):
                offer = Offer(body, stalled); result = []; loop = GLib.MainLoop()
                def completed(value): result.append(value); loop.quit()
                with patch('drop_receiver.READ_TIMEOUT_MS', 25):
                    read_drop(offer, completed, completed); loop.run()
                self.assertEqual(len(offer.finished), 1)
                self.assertEqual(offer.types, ['text/uri-list'])
                if good: self.assertEqual(result, [[str(path)]])
                else: self.assertIsInstance(result[0], str)

    def test_bounded_local_uri_lists_validate_all_before_import(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); path = root / 'song with spaces.MP3'; path.write_bytes(b'fixture'); folder = root / 'album'; folder.mkdir()
            raw = ('# comment\r\n' + path.as_uri() + '\r\n' + folder.as_uri() + '\r\n' + path.as_uri()).encode()
            self.assertEqual(paths_from_uris(raw), [str(path), str(folder)])
            for raw in (b'x' * (MAX_BYTES + 1), b'https://example.com/song.mp3', b'file://nas/music.mp3', b'file:///tmp/%00.mp3', b'\xff'):
                with self.subTest(raw=raw[:30]), self.assertRaises((ValueError, OSError)): paths_from_uris(raw)
            script = root / 'script.avs'; script.write_text('BlankClip()')
            with self.assertRaises(ValueError): paths_from_uris((path.as_uri() + '\n' + script.as_uri()).encode())
            disguised = root / 'disguised.mp3'; disguised.symlink_to(script)
            with self.assertRaises(ValueError): paths_from_uris(disguised.as_uri().encode())
