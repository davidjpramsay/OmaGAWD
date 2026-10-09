import io
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit

import radio_library as radio
from radio_browser import RadioBrowser, MAX_BYTES
from radio_store import RadioStore
from playback_store import PlaybackStore, validate
from test_backend import Player, FakeMpv


def station(name='Sample Radio', url='https://radio.example/stream'):
    return radio.make_station(name, url)


class Response(io.BytesIO):
    headers = {}


class DiscoveryTests(unittest.TestCase):
    def test_search_filters_and_untrusted_directory_entries(self):
        payload = [dict(name='Sample Radio', url_resolved='https://radio.example/live', tags='rock', country='Australia', language='English'),
                   dict(name='Duplicate', url='https://radio.example/live'),
                   dict(name='File', url='file:///private'), dict(name='Local', url='http://127.0.0.1/audio'),
                   dict(name='Credential', url='https://user:password@example.com/audio'), None]
        opener = Mock()
        opener.open.return_value = Response(json.dumps(payload).encode())
        rows, more = RadioBrowser(opener=opener).search({'name': 'Sample', 'genre': 'rock', 'country': 'Australia', 'language': 'English'})
        self.assertEqual(len(rows), 1)
        self.assertFalse(more)
        params = parse_qs(urlsplit(opener.open.call_args.args[0].full_url).query)
        self.assertEqual(params['name'], ['Sample'])
        self.assertEqual(params['tag'], ['rock'])
        self.assertEqual(params['country'], ['Australia'])
        self.assertEqual(params['language'], ['English'])
        self.assertEqual(params['hidebroken'], ['true'])
        self.assertEqual(params['limit'], ['100'])
        self.assertIn('OmaGAWD/', opener.open.call_args.args[0].get_header('User-agent'))

    def test_failover_and_bounded_bodies(self):
        opener = Mock()
        opener.open.side_effect = [OSError('Offline'), Response(b'[]')]
        self.assertEqual(RadioBrowser(opener=opener).search({}), ([], False))
        self.assertEqual(opener.open.call_count, 2)
        opener.open.side_effect = lambda *args, **kwargs: Response(b' ' * (MAX_BYTES + 1))
        with self.assertRaises(RuntimeError): RadioBrowser(opener=opener).search({})
        for fields, offset in [([], 0), ({'name': 'a'*161}, 0), ({}, -1), ({}, 1), ({}, 1000)]:
            with self.assertRaises(ValueError): RadioBrowser(opener=opener).search(fields, offset)

    def test_pagination_and_invalid_shapes(self):
        opener = Mock()
        payload = [dict(name=str(i), url='https://radio.example/' + str(i)) for i in range(100)]
        opener.open.side_effect = lambda *args, **kwargs: Response(json.dumps(payload).encode())
        rows, more = RadioBrowser(opener=opener).search({}, 100)
        self.assertEqual(len(rows), 100)
        self.assertTrue(more)
        self.assertEqual(parse_qs(urlsplit(opener.open.call_args.args[0].full_url).query)['offset'], ['100'])
        self.assertFalse(RadioBrowser(opener=opener).search({}, 900)[1])
        for payload in ({}, [dict(name='Too many', url='https://radio.example')] * 101):
            opener.open.side_effect = lambda *args, **kwargs: Response(json.dumps(payload).encode())
            with self.assertRaises(RuntimeError): RadioBrowser(opener=opener).search({})


class SavedStationTests(unittest.TestCase):
    def test_private_atomic_save_deduplication_and_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'radio.json'
            store = RadioStore(path)
            custom = station()
            self.assertEqual(store.add(custom), custom['id'])
            self.assertEqual(store.add(station('Another name')), custom['id'])
            self.assertEqual(len(store.rows), 15)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(RadioStore(path).rows[-1], custom)
            before = path.read_bytes()
            with patch('radio_store.os.replace', side_effect=OSError('Disk full')):
                with self.assertRaises(OSError): store.remove(custom['id'])
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(store.rows[-1], custom)
            store.remove('radio:omarchy')
            self.assertNotIn('radio:omarchy', [s['id'] for s in RadioStore(path).rows])
            store.save([])
            self.assertEqual(RadioStore(path).rows, [])

    def test_damaged_data_backup_and_failed_backup_never_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'radio.json'
            path.write_text('broken')
            store = RadioStore(path)
            self.assertTrue(store.warning)
            self.assertEqual(next(path.parent.glob('radio.json.invalid-*')).read_text(), 'broken')
            store.add(station())
            path.write_text('private original')
            with patch.object(Path, 'rename', side_effect=OSError('Denied')):
                blocked = RadioStore(path)
            with self.assertRaises(RuntimeError): blocked.add(station())
            self.assertEqual(path.read_text(), 'private original')

    def test_bad_links_and_mismatched_saved_ids_are_rejected(self):
        bad = ('file:///etc/passwd', 'data:audio/mp3,xxx', 'ftp://example.com/audio', 'https://user:pw@example.com/audio',
               'https://example.com/audio?token=secret', 'https://example.com/audio#file', 'https://example.com/music.m3u',
               'https://example.com:bad/audio', 'https://example.com/\nstream', 'https://%31%32%37.0.0.1/audio')
        for url in bad:
            with self.assertRaises(ValueError, msg=url): station(url=url)
        custom = station()
        custom['id'] = 'radio:custom:fake'
        with self.assertRaises(ValueError): RadioStore.validate([custom])
        with patch('radio_store.MAX_STATIONS', 1):
            with self.assertRaises(ValueError): RadioStore(memory=True).save([station(), station(url='https://radio.example/two')])


class CustomPlaybackTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.p = Player(self.events.append, FakeMpv)
        self.p.handle({'cmd': 'library', 'folder': 'radio'})

    def tearDown(self): self.p.close()

    def test_manual_save_play_forget_and_session_restore(self):
        self.p.handle({'cmd': 'radio_save', 'name': 'Sample Radio', 'url': 'https://radio.example/stream'})
        custom = self.p.songs[-1]
        self.p.handle({'cmd': 'replace_play', 'ids': [custom['id']]})
        engine = self.p.mpv
        self.assertIn(('loadfile', 'https://radio.example/stream', 'replace'), engine.commands)
        self.assertIn(('set_property', 'http-header-fields', []), engine.commands)
        self.assertIn(('set_property', 'options/demuxer-lavf-o', {'protocol_whitelist': 'http,https,tcp,tls,crypto'}), engine.commands)
        self.p.handle({'cmd': 'radio_remove', 'id': custom['id']})
        self.assertNotIn(custom['id'], [s['id'] for s in self.p.songs])
        self.assertIs(self.p.mpv, engine)
        self.assertEqual(self.p.queue[0]['id'], custom['id'])
        saved = validate(self.p.session_snapshot())
        self.assertEqual(saved['queue'][0]['radioUrl'], 'https://radio.example/stream')
        with tempfile.TemporaryDirectory() as directory:
            store = PlaybackStore(Path(directory) / 'session.json'); store.write(saved)
            restored = Player(lambda event: None, FakeMpv, playback_store=store)
            try:
                self.assertTrue(restored.paused)
                self.assertIsNone(restored.mpv)
                restored.handle({'cmd': 'pause'})
                self.assertFalse(restored.paused)
            finally: restored.close()

    def test_discovered_station_append_and_save_without_interrupting(self):
        self.p.handle({'cmd': 'replace_play', 'ids': ['radio:omarchy']})
        engine = self.p.mpv
        self.p.radio_results = [station()]
        self.p.handle({'cmd': 'add', 'ids': [station()['id']]})
        self.assertIs(self.p.mpv, engine)
        self.p.handle({'cmd': 'radio_save', 'id': station()['id']})
        self.assertIn(station()['id'], [s['id'] for s in self.p.radios.rows])
        self.assertIs(self.p.mpv, engine)
        self.assertFalse(self.p.paused)

    def test_old_search_response_cannot_replace_new_results(self):
        started, release = threading.Event(), threading.Event()
        def search(fields, offset):
            if fields['name'] == 'old': started.set(); release.wait(3)
            return [station(fields['name'], 'https://radio.example/' + fields['name'])], False
        self.p.radio_browser = Mock(); self.p.radio_browser.search.side_effect = search
        self.p.handle({'cmd': 'radio_search', 'fields': {'name': 'old'}, 'request': 1})
        self.assertTrue(started.wait(1))
        self.p.handle({'cmd': 'radio_search', 'fields': {'name': 'new'}, 'request': 2})
        release.set(); self.p.radio_future.result(timeout=3)
        self.assertEqual([s['title'] for s in self.p.radio_results], ['new'])
        results = [e for e in self.events if e['type'] == 'radio_results']
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['request'], 2)

    def test_failed_search_leaves_saved_stations_and_playback_available(self):
        self.p.handle({'cmd': 'replace_play', 'ids': ['radio:omarchy']})
        self.p.radio_browser = Mock(); self.p.radio_browser.search.side_effect = RuntimeError('Offline')
        self.p.handle({'cmd': 'radio_search', 'fields': {}, 'request': 1})
        self.p.radio_future.result(timeout=3)
        self.assertEqual(len(self.p.songs), 14)
        self.assertFalse(self.p.idle)
        self.assertTrue(any(e['type'] == 'radio_error' for e in self.events))

    def test_cancel_clears_reconnect_snapshot_and_late_results(self):
        self.p.radio_results = [station()]
        self.p.handle({'cmd': 'radio_cancel', 'request': 5})
        self.assertEqual(self.p.radio_results, [])
        self.assertEqual(self.events[-1], {'type': 'radio_busy', 'value': False, 'request': 5})
        self.assertEqual(self.events[-2]['songs'], [])


if __name__ == '__main__': unittest.main()
