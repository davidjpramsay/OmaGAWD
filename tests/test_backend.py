import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend import Jellyfin, Player


class FakeMpv:
    def __init__(self, callback):
        self.commands = []
    def load(self, url, headers):
        self.send('set_property', 'http-header-fields', headers)
        self.send('loadfile', url, 'replace')
    def send(self, *args):
        self.commands.append(args)
    def close(self):
        pass


def song(i):
    return {'id': str(i), 'title': 'Song ' + str(i), 'artist': 'Artist', 'album': 'Album', 'duration': 180}


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.messages = []
        self.p = Player(self.messages.append, FakeMpv)
        self.p.client = Jellyfin('https://example.com/jellyfin')
        self.p.client.token = 'secret'
        self.p.songs = [song(i) for i in range(3)]
        self.p.handle({'cmd': 'add', 'ids': ['0', '1', '2']})
    def tearDown(self):
        self.p.client = None
        self.p.close()
    def test_replace_playlist_starts_first_selected_song(self):
        self.p.play(2)
        previous_keys = {s['key'] for s in self.p.queue}
        self.p.handle({'cmd': 'replace_play', 'ids': ['1', '0']})
        self.assertEqual([s['id'] for s in self.p.queue], ['0', '1'])
        self.assertFalse(previous_keys.intersection(s['key'] for s in self.p.queue))
        self.assertEqual(self.p.index, 0)
        self.assertFalse(self.p.paused)
        self.assertFalse(self.p.idle)
        self.assertEqual(self.p.position, 0)
        self.assertEqual([c for c in self.p.mpv.commands if c[0] == 'loadfile'][-1],
                         ('loadfile', 'https://example.com/jellyfin/Audio/0/stream?static=true', 'replace'))

    def test_replace_playlist_with_single_song(self):
        self.p.handle({'cmd': 'replace_play', 'ids': ['2']})
        self.assertEqual([s['id'] for s in self.p.queue], ['2'])
        self.assertEqual(self.p.index, 0)
        self.assertFalse(self.p.idle)

    def test_empty_replace_keeps_playing_queue(self):
        self.p.play(1)
        previous = list(self.p.queue)
        self.p.handle({'cmd': 'replace_play', 'ids': ['missing']})
        self.assertEqual(self.p.queue, previous)
        self.assertEqual(self.p.index, 1)
        self.assertFalse(self.p.idle)

    def test_append_does_not_interrupt_current_playback(self):
        self.p.play(1)
        self.p.position = 42
        commands = list(self.p.mpv.commands)
        current = self.p.queue[1]['key']
        self.p.handle({'cmd': 'add', 'ids': ['0', '2']})
        self.assertEqual([s['id'] for s in self.p.queue], ['0', '1', '2', '0', '2'])
        self.assertEqual(self.p.queue[self.p.index]['key'], current)
        self.assertEqual(self.p.position, 42)
        self.assertFalse(self.p.paused)
        self.assertEqual(self.p.mpv.commands, commands)

    def test_duplicate_entries_remove_independently(self):
        self.p.handle({'cmd': 'add', 'ids': ['0']})
        key = self.p.queue[0]['key']
        self.p.handle({'cmd': 'remove', 'keys': [key]})
        self.assertEqual([s['id'] for s in self.p.queue], ['1', '2', '0'])
    def test_remove_before_current_preserves_playing_track(self):
        self.p.play(2)
        self.p.handle({'cmd': 'remove', 'keys': [self.p.queue[0]['key']]})
        self.assertEqual(self.p.index, 1)
        self.assertEqual(self.p.queue[self.p.index]['id'], '2')
    def test_remove_current_stops_and_selects_successor(self):
        self.p.play(1)
        self.p.handle({'cmd': 'remove', 'keys': [self.p.queue[1]['key']]})
        self.assertTrue(self.p.idle)
        self.assertEqual(self.p.index, 1)
        self.assertEqual(self.p.queue[1]['id'], '2')
        self.assertIn(('stop',), self.p.mpv.commands)
    def test_reorder_preserves_current(self):
        self.p.play(1)
        self.p.handle({'cmd': 'move', 'index': 1, 'delta': -1})
        self.assertEqual(self.p.index, 0)
        self.assertEqual(self.p.queue[0]['id'], '1')
    def test_eof_repeat_modes(self):
        self.p.play(2)
        self.p.event({'event': 'end-file', 'reason': 'eof'})
        self.assertTrue(self.p.idle)
        self.p.repeat = 'all'
        self.p.event({'event': 'end-file', 'reason': 'eof'})
        self.assertEqual(self.p.index, 0)
        self.p.repeat = 'one'
        self.p.event({'event': 'end-file', 'reason': 'eof'})
        self.assertEqual(self.p.index, 0)
    def test_shuffle_excludes_current(self):
        self.p.play(1)
        self.p.shuffle = True
        self.p.next_track()
        self.assertNotEqual(self.p.index, 1)
    def test_token_not_in_stream_url_or_state(self):
        self.p.play(0)
        self.p.state()
        self.assertNotIn('secret', json.dumps(self.messages))
        load = next(c for c in self.p.mpv.commands if c[0] == 'loadfile')
        self.assertEqual(load[1], 'https://example.com/jellyfin/Audio/0/stream?static=true')
        self.assertIn(('set_property', 'http-header-fields', ['Authorization: ' + self.p.client.authorization()]), self.p.mpv.commands)
    def test_error_does_not_skip_entire_queue(self):
        self.p.play(0)
        self.p.event({'event': 'end-file', 'reason': 'error'})
        self.assertTrue(self.p.idle)
        self.assertEqual(self.p.index, 0)
        self.assertTrue(any(m['type'] == 'error' for m in self.messages))
    def test_clear_and_clamped_volume(self):
        self.p.play(0)
        self.p.handle({'cmd': 'volume', 'value': 900})
        self.assertEqual(self.p.volume, 100)
        self.p.handle({'cmd': 'clear'})
        self.assertEqual(self.p.queue, [])
        self.assertEqual(self.p.index, -1)
        self.assertTrue(self.p.idle)
    def test_stale_network_response_is_ignored(self):
        self.p.generation = 2
        with patch.object(Jellyfin, 'songs', return_value=[song(9)]):
            self.p.network({'cmd': 'library'}, 1)
        self.assertEqual(len(self.p.songs), 3)

    def test_library_denial_is_not_reported_as_bad_password(self):
        import urllib.error
        self.p.generation = 7
        def login(client, username, password):
            client.token, client.user = 'new-token', 'user'
        with patch.object(Jellyfin, 'login', login), patch.object(Jellyfin, 'libraries', side_effect=urllib.error.HTTPError('https://example.com/UserViews', 401, 'Unauthorized', {}, None)), patch.object(Player, 'revoke'):
            self.p.network({'cmd': 'login', 'url': 'https://example.com', 'username': 'u', 'password': 'p'}, 7)
        error = next(m['message'] for m in reversed(self.messages) if m['type'] == 'error')
        self.assertIn('Login succeeded', error)
        self.assertNotIn('password', error)

    def test_meter_silence_and_pause(self):
        self.p.idle, self.p.paused = False, False
        self.p.event({'request_id': 900, 'spectrum': [0.0] * 16})
        self.assertEqual(self.messages[-1], {'type': 'meter', 'levels': [0.0] * 16})
        self.p.event({'request_id': 900, 'spectrum': [0.5] * 16})
        self.assertEqual(self.messages[-1], {'type': 'meter', 'levels': [0.5] * 16})
        self.p.paused = True
        count = len(self.messages)
        self.p.event({'request_id': 900, 'data': {'lavfi.astats.Overall.RMS_level': '-10'}})
        self.assertEqual(len(self.messages), count)


class ApiTests(unittest.TestCase):
    def test_validation(self):
        for url in ['file:///etc/passwd', 'https://user:pass@host', 'https://host?api_key=secret', 'bad']:
            with self.assertRaises(ValueError):
                Jellyfin(url)
    def test_pagination_and_metadata_fallbacks(self):
        client = Jellyfin('https://example.com')
        client.user = 'user'
        with patch.object(client, 'request', side_effect=[
            {'Items': [{'Id': '1', 'Artists': ['A'], 'Name': '<b>literal</b>'}], 'TotalRecordCount': 2},
            {'Items': [{'Id': '2', 'RunTimeTicks': 10000000}], 'TotalRecordCount': 2}
        ]) as request:
            songs = client.songs('folder')
        self.assertEqual(len(songs), 2)
        self.assertEqual(songs[0]['artist'], 'A')
        self.assertEqual(songs[1]['duration'], 1)
        self.assertEqual(request.call_args_list[1].args[1]['StartIndex'], 1)
        self.assertEqual(request.call_args_list[0].args[1]['ParentId'], 'folder')
    def test_real_http_login_library_headers_and_base_path(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append((self.path, dict(self.headers), body))
                self.send_response(200); self.end_headers()
                self.wfile.write(b'{"AccessToken":"test-token","User":{"Id":"u"}}')
            def do_GET(self):
                requests.append((self.path, dict(self.headers), None))
                if 'Token="test-token"' not in self.headers.get('Authorization', ''):
                    self.send_error(401); return
                self.send_response(200); self.end_headers()
                self.wfile.write(b'{"Items":[{"Id":"m","Name":"Music","CollectionType":"music"},{"Id":"v","Name":"Movies","CollectionType":"movies"}]}')
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            client = Jellyfin('http://127.0.0.1:' + str(server.server_port) + '/jellyfin/')
            client.login('name', 'p@ss')
            self.assertEqual(client.libraries(), [{'id': 'm', 'name': 'Music'}])
            self.assertEqual(requests[0][0], '/jellyfin/Users/AuthenticateByName')
            self.assertEqual(requests[0][2], {'Username': 'name', 'Pw': 'p@ss'})
            self.assertIn('Token="test-token"', requests[1][1]['Authorization'])
            self.assertNotIn('X-Emby-Token', requests[1][1])
            self.assertEqual(requests[1][0], '/jellyfin/UserViews?UserId=u')
        finally:
            server.shutdown(); server.server_close()


if __name__ == '__main__': unittest.main()
