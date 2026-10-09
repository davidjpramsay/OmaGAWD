"""Radio is public, live, and independent of Jellyfin account restoration."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import radio_library as radio
from playback_store import PlaybackStore, validate
from test_backend import FakeMpv, Jellyfin, Player, song


class RadioTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.p = Player(self.events.append, FakeMpv)
        self.p.handle({'cmd': 'library', 'folder': 'radio'})

    def tearDown(self):
        self.p.client = None
        self.p.close()

    def tune(self, station='radio:omarchy'):
        self.p.handle({'cmd': 'replace_play', 'ids': [station]})

    def test_catalog_has_unique_ids_and_only_trusted_https_streams(self):
        self.assertEqual(len(self.p.songs), 14)
        self.assertEqual(len({s['id'] for s in self.p.songs}), 14)
        for row in self.p.songs:
            self.assertTrue(radio.stream(row['id']).startswith('https://radio.cliamp.stream/'))
            self.assertEqual(row['duration'], 0)
        for bad in ('https://example.com', 'radio:../secret', 'radio:unknown'):
            with self.assertRaises(ValueError): radio.stream(bad)

    def test_radio_plays_without_an_account_or_authentication_and_cannot_seek(self):
        self.tune()
        self.assertFalse(self.p.idle)
        self.assertEqual(self.p.mpv.start, 0)
        self.assertIn(('set_property', 'http-header-fields', []), self.p.mpv.commands)
        before = list(self.p.mpv.commands)
        self.p.handle({'cmd': 'seek', 'seconds': 200})
        self.assertEqual(before, self.p.mpv.commands)
        for prop in ('time-pos', 'duration'):
            self.p.event({'event': 'property-change', 'name': prop, 'data': 200})
        self.assertEqual((self.p.position, self.p.duration), (0, 0))

    def test_append_preserves_playback_and_station_switch_resets_metadata(self):
        self.tune()
        engine = self.p.mpv
        self.p.event({'event': 'property-change', 'name': 'metadata', 'data': {'icy-title': 'Artist - Track'}})
        self.p.handle({'cmd': 'add', 'ids': ['radio:lofi']})
        self.assertIs(self.p.mpv, engine)
        self.assertEqual(self.p.radio_title, 'Artist - Track')
        self.p.handle({'cmd': 'next'})
        self.assertIsNot(self.p.mpv, engine)
        self.assertEqual(self.p.radio_title, '')
        self.assertEqual(self.p.queue[self.p.index]['id'], 'radio:lofi')

    def test_metadata_is_bounded_and_cleared_when_station_stops_sending_it(self):
        self.tune()
        self.p.event({'event': 'property-change', 'name': 'metadata', 'data': {'StreamTitle': '\n' + 'a' * 900}})
        self.assertLessEqual(len(self.p.radio_title), 512)
        self.assertNotIn('\n', self.p.radio_title)
        self.p.event({'event': 'property-change', 'name': 'metadata', 'data': {}})
        self.assertEqual(self.p.radio_title, '')

    def test_media_controls_show_live_title_without_a_finite_length(self):
        from mpris import Mpris, PLAYER
        self.tune()
        self.p.radio_title = 'Sample Artist - Sample Track'
        media = Mpris.__new__(Mpris)
        media.player = self.p
        properties = media.properties(PLAYER)
        metadata = properties['Metadata'].unpack()
        self.assertEqual(metadata['xesam:title'], self.p.radio_title)
        self.assertEqual(metadata['xesam:album'], 'Omarchy')
        self.assertNotIn('mpris:length', metadata)
        self.assertFalse(properties['CanSeek'].unpack())

    def test_resume_reconnects_to_live_and_failed_station_does_not_skip(self):
        self.tune()
        engine = self.p.mpv
        self.p.handle({'cmd': 'pause'})
        self.assertTrue(self.p.paused)
        self.p.handle({'cmd': 'pause'})
        self.assertIsNot(engine, self.p.mpv)
        self.assertFalse(self.p.paused)
        self.p.handle({'cmd': 'add', 'ids': ['radio:lofi']})
        self.p.event({'event': 'end-file', 'reason': 'error'})
        self.assertTrue(self.p.idle)
        self.assertEqual(self.p.index, 0)
        self.assertIn('Radio station', self.events[-2]['message'])

    def test_switching_library_does_not_interrupt_playback_or_inherit_jellyfin_auth(self):
        self.p.client = Jellyfin('https://example.com')
        self.p.client.user, self.p.client.token = 'user', 'private-token'
        self.p.songs = [song(1)]
        self.p.handle({'cmd': 'replace_play', 'ids': ['1']})
        engine = self.p.mpv
        self.p.position = 42
        self.p.handle({'cmd': 'library', 'folder': 'radio'})
        self.assertIs(self.p.mpv, engine)
        self.assertEqual(self.p.position, 42)
        self.p.bitrate = 1072000
        self.tune()
        self.assertIsNot(engine, self.p.mpv)
        self.assertNotIn('private-token', str(self.p.mpv.commands))
        self.assertIsNone(self.p.queue_identity)
        self.assertEqual(self.p.bitrate, 0)

    def test_snapshot_preserves_radio_and_rejects_untrusted_station_urls(self):
        self.tune()
        data = self.p.session_snapshot()
        data['position'] = 42
        data['queue'][0]['path'] = 'https://evil.example/stream'
        restored = validate(data)
        self.assertEqual(restored['folder'], 'radio')
        self.assertEqual(restored['position'], 0)
        self.assertEqual(restored['queue'][0]['source'], 'radio')
        self.assertNotIn('path', restored['queue'][0])
        data['queue'][0]['id'] = 'radio:evil'
        with self.assertRaises(ValueError): validate(data)

    def test_radio_restores_before_failed_keyring_without_autoplay(self):
        self.tune()
        with tempfile.TemporaryDirectory() as directory:
            store = PlaybackStore(Path(directory) / 'session.json')
            store.write(self.p.session_snapshot())
            keyring = Mock()
            keyring.load.side_effect = RuntimeError('Keyring locked')
            p = Player(self.events.append, FakeMpv, store=keyring, playback_store=store)
            try:
                p.network({'cmd': 'restore'}, p.generation)
                self.assertEqual(p.folder, 'radio')
                self.assertEqual(len(p.songs), 14)
                self.assertTrue(p.paused)
                self.assertIsNone(p.mpv)
                p.handle({'cmd': 'pause'})
                self.assertFalse(p.paused)
            finally: p.close()

    def test_remote_restore_preserves_radio_source_and_mixed_queue_identity(self):
        self.tune()
        self.p.store = Mock()
        self.p.store.load.return_value = dict(url='https://example.com', username='user', token='token', user='u', device='d')
        with patch('backend.Jellyfin.request', return_value={}), patch('backend.Jellyfin.libraries', return_value=[{'id': 'music', 'name': 'Music'}]), patch('backend.Jellyfin.songs') as fetch:
            self.p.network({'cmd': 'restore'}, self.p.generation)
            fetch.assert_not_called()
        self.assertEqual(self.p.folder, 'radio')
        self.assertTrue(next(e for e in reversed(self.events) if e['type'] == 'connected')['preserveRadio'])
        self.p.songs = [song(1)]
        self.p.handle({'cmd': 'add', 'ids': ['1']})
        restored = validate(self.p.session_snapshot())
        self.assertEqual(restored['library']['user'], 'u')
        self.assertEqual(restored['queue'][0]['source'], 'radio')


if __name__ == '__main__': unittest.main()
