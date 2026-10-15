"""Hosted playlists use a disposable authenticated server, never a real account."""
import json
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import urlsplit, parse_qs

import jellyfin_playlists as hosted
from backend import Jellyfin, Player, Mpv
from test_backend import FakeMpv
from playback_store import identity


def key(n): return uuid.UUID(int=n).hex


def item(n, title=None):
    return {'Id': key(n), 'Name': title or 'Track ' + str(n), 'Type': 'Audio', 'MediaType': 'Audio',
            'AlbumArtist': 'Fixture', 'Album': 'Album', 'RunTimeTicks': 3_000_000, 'PlaylistItemId': key(n)}


def wait_for(predicate):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if predicate(): return True
        time.sleep(.01)
    return predicate()


class HostedTests(unittest.TestCase):
    def setUp(self):
        self.calls = []; self.created = []; self.deleted = False
        self.can_delete = True; self.delete_status = 204; self.bad_delete_reply = False
        self.delete_item = {'Id': key(10), 'Type': 'Playlist', 'MediaType': 'Audio', 'CanDelete': True}
        self.items = [item(1), item(2), item(1)]
        self.deny = False; self.fail_preview = False; self.bad_creation_reply = False
        self.server_version = '10.11.0'
        self.gate = None; self.entered = threading.Event()
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def answer(self, data):
                raw = json.dumps(data).encode(); self.send_response(200)
                self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw)))
                self.end_headers(); self.wfile.write(raw)
            def do_GET(self):
                owner.calls.append(('GET', self.path, self.headers.get('Authorization')))
                path = urlsplit(self.path).path
                if ('/Playlists/' in path or 'Ids=' in self.path) and owner.gate:
                    owner.entered.set(); owner.gate.wait(3)
                if owner.deny: self.send_error(403); return
                if path == '/jellyfin/System/Info/Public': self.answer({'Version':owner.server_version})
                elif path == '/jellyfin/Items':
                    if 'Ids=' in self.path: self.answer({'Items': [dict(owner.delete_item, CanDelete=owner.can_delete)], 'TotalRecordCount': 1})
                    else: self.answer({'Items': [] if owner.deleted else [{'Id': key(10), 'Name': 'Server mix', 'Type': 'Playlist', 'MediaType': 'Audio', 'ChildCount': 3, 'CanDelete': owner.can_delete}], 'TotalRecordCount': 0 if owner.deleted else 1})
                elif '/Playlists/' in path:
                    if owner.fail_preview: self.send_error(404); return
                    params = parse_qs(urlsplit(self.path).query); offset = int(params['StartIndex'][0]); limit = int(params['Limit'][0])
                    self.answer({'Items': owner.items[offset:offset+limit], 'TotalRecordCount': len(owner.items)})
                elif '/Audio/' in path:
                    raw = owner.audio
                    self.send_response(200); self.send_header('Content-Type', 'audio/wav'); self.send_header('Content-Length', str(len(raw)))
                    self.end_headers(); self.wfile.write(raw)
                else: self.send_error(404)
            def do_DELETE(self):
                owner.calls.append(('DELETE', self.path, self.headers.get('Authorization')))
                if owner.deny or owner.delete_status != 204:
                    self.send_error(403 if owner.deny else owner.delete_status); return
                if self.path != '/jellyfin/Items/' + key(10): self.send_error(400); return
                owner.deleted = True
                if owner.bad_delete_reply:
                    self.send_response(200); self.send_header('Content-Length', '7'); self.end_headers(); self.wfile.write(b'invalid')
                else:
                    self.send_response(204); self.send_header('Content-Length', '0'); self.end_headers()
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.calls.append(('POST', self.path, self.headers.get('Authorization')))
                if owner.deny: self.send_error(403); return
                owner.created.append(body)
                owner.items = [item(uuid.UUID(s).int) for s in body['Ids']]
                self.answer({'Id': 'invalid' if owner.bad_creation_reply else key(11)})
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.client = Jellyfin('http://127.0.0.1:' + str(self.server.server_port) + '/jellyfin')
        self.client.user, self.client.token = key(100), 'fixture-token'
        self.events = []; self.player = Player(self.events.append, FakeMpv)
        self.player.client = self.client
        self.player.queue_identity = identity(self.client)
        self.player.queue = [dict(hosted.music_row(item(1)), key='current')]
        self.player.play(0); self.player.position = 42

    def tearDown(self):
        if self.gate: self.gate.set()
        self.player.client = None; self.player.close()
        self.server.shutdown(); self.server.server_close()

    def run_command(self, cmd, **kw):
        self.player.handle(dict(cmd=cmd, request=1, **kw))
        self.player.hosted_work.submit(lambda: None).result(timeout=4)

    def test_delete_confirmed_playlist_keeps_playing_queue_and_audio(self):
        self.run_command('hosted_list')
        engine, queue, commands = self.player.mpv, list(self.player.queue), list(self.player.mpv.commands)
        self.run_command('hosted_delete', id=key(10), confirmed=True)
        self.assertTrue(self.deleted); self.assertEqual(self.player.hosted_playlists, [])
        self.assertTrue(any(e['type'] == 'hosted_deleted' for e in self.events))
        self.assertEqual(next(e for e in reversed(self.events) if e['type'] == 'hosted_items')['songs'], [])
        self.assertIs(self.player.mpv, engine); self.assertEqual(self.player.queue, queue)
        self.assertEqual(self.player.position, 42); self.assertEqual(self.player.mpv.commands, commands)
        self.assertEqual([c[1] for c in self.calls if c[0] == 'DELETE'], ['/jellyfin/Items/' + key(10)])
        self.assertTrue(all('fixture-token' in c[2] and 'fixture-token' not in c[1] for c in self.calls))

    def test_delete_requires_confirmation_selection_and_fresh_permission(self):
        self.run_command('hosted_list'); self.calls.clear()
        for value in (None, False, 1, 'true'):
            self.run_command('hosted_delete', id=key(10), confirmed=value)
        self.run_command('hosted_delete', id=key(99), confirmed=True)
        self.assertEqual(self.calls, [])
        for permission in (False, None, 1, 'true'):
            self.can_delete = permission
            self.run_command('hosted_delete', id=key(10), confirmed=True)
        self.assertFalse(any(c[0] == 'DELETE' for c in self.calls))
        self.assertFalse(self.deleted); self.assertEqual(len(self.player.hosted_playlists), 1)
        self.assertIn('permission', next(e['message'] for e in reversed(self.events) if e['type'] == 'hosted_error'))

    def test_delete_rejects_non_playlist_wrong_id_or_non_music(self):
        self.run_command('hosted_list')
        for changed in ({'Type': 'Audio'}, {'Type': None}, {'MediaType': 'Video'}, {'MediaType': None}, {'Id': key(1)}, {'Id': 'bad'}):
            self.delete_item = dict(Id=key(10), Type='Playlist', MediaType='Audio')
            self.delete_item.update(changed)
            self.run_command('hosted_delete', id=key(10), confirmed=True)
        self.assertFalse(any(c[0] == 'DELETE' for c in self.calls)); self.assertFalse(self.deleted)

    def test_delete_server_denial_and_uncertain_response_do_not_retry(self):
        self.run_command('hosted_list')
        self.delete_status = 403
        self.run_command('hosted_delete', id=key(10), confirmed=True)
        self.assertFalse(self.deleted); self.assertEqual(len(self.player.hosted_playlists), 1)
        self.delete_status = 204; self.bad_delete_reply = True
        self.run_command('hosted_delete', id=key(10), confirmed=True)
        self.assertTrue(self.deleted); self.assertEqual(len(self.player.hosted_playlists), 1)
        self.assertEqual(len([c for c in self.calls if c[0] == 'DELETE']), 2)
        self.assertIn('could not be confirmed', next(e['message'] for e in reversed(self.events) if e['type'] == 'hosted_error'))
        self.run_command('hosted_list'); self.assertEqual(self.player.hosted_playlists, [])

    def test_account_change_during_delete_permission_check_cancels_mutation(self):
        self.run_command('hosted_list')
        self.gate = threading.Event()
        self.player.handle({'cmd': 'hosted_delete', 'id': key(10), 'confirmed': True, 'request': 2})
        self.assertTrue(self.entered.wait(1))
        with self.player.lock: self.player.client = Jellyfin('https://other.example'); self.player.clear_hosted()
        self.gate.set(); self.player.hosted_work.submit(lambda: None).result(timeout=4)
        self.assertFalse(any(c[0] == 'DELETE' for c in self.calls))
        self.assertFalse(any(e['type'] == 'hosted_deleted' for e in self.events))

    def test_read_and_private_creation_preserve_playback_order_and_duplicates(self):
        engine, queue = self.player.mpv, list(self.player.queue)
        self.run_command('hosted_list')
        self.assertEqual(self.player.hosted_playlists[0]['name'], 'Server mix')
        self.run_command('hosted_items', id=key(10))
        result = next(e for e in reversed(self.events) if e['type'] == 'hosted_items')
        self.assertEqual([r['id'] for r in result['songs']], [key(1), key(2), key(1)])
        self.assertEqual([r['entry'] for r in result['songs']], ['0', '1', '2'])
        self.assertIs(self.player.mpv, engine); self.assertEqual(self.player.queue, queue); self.assertEqual(self.player.position, 42)
        self.player.queue = [dict(hosted.music_row(item(n)), key='row'+str(i)) for i,n in enumerate((1,2,1))]
        queue = list(self.player.queue)
        self.run_command('hosted_create', name='GAWD mix')
        self.assertEqual(self.created, [{'Name': 'GAWD mix', 'Ids': [key(1), key(2), key(1)], 'UserId': key(100), 'MediaType': 'Audio', 'IsPublic': False, 'Users': []}])
        self.assertEqual(self.player.queue, queue); self.assertIs(self.player.mpv, engine); self.assertEqual(self.player.position, 42)
        self.assertTrue(all('Token="fixture-token"' in c[2] for c in self.calls))
        self.assertTrue(any(e['type'] == 'hosted_created' for e in self.events))

    def test_load_paused_and_explicit_play_keep_all_entries(self):
        self.run_command('hosted_load', id=key(10), play=False)
        self.assertTrue(self.player.paused); self.assertIsNone(self.player.mpv)
        self.assertEqual([r['id'] for r in self.player.queue], [key(1),key(2),key(1)])
        self.assertEqual(len({r['key'] for r in self.player.queue}), 3)
        self.run_command('hosted_load', id=key(10), play=True, index=2)
        self.assertFalse(self.player.paused); self.assertEqual(self.player.index, 2)
        self.assertEqual(self.player.queue_identity, identity(self.client))

    def test_local_radio_foreign_account_and_invalid_names_never_post(self):
        original = list(self.player.queue)
        for row in (dict(original[0], source='local', path='/private/song.flac'),
                    dict(original[0], source='radio', radioUrl='https://radio.example/live'),
                    dict(original[0], id='/private/song.flac')):
            self.player.queue = [row]; self.run_command('hosted_create', name='Blocked')
        self.player.queue = original
        self.run_command('hosted_create', name='bad\nname')
        self.player.queue_identity = {'url': self.client.url, 'user': key(999)}
        self.run_command('hosted_create', name='Foreign')
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_permission_empty_and_non_music_failures_keep_current_queue(self):
        engine, queue = self.player.mpv, list(self.player.queue)
        self.deny = True; self.run_command('hosted_load', id=key(10), play=True)
        self.assertIn('permissions', next(e['message'] for e in reversed(self.events) if e['type']=='hosted_error'))
        self.deny = False
        for rows in ([], [dict(item(1), Type='Video')], [dict(item(1), Id='not-a-guid')]):
            self.items = rows; self.run_command('hosted_load', id=key(10), play=True)
            self.assertEqual(self.player.queue, queue); self.assertIs(self.player.mpv, engine)
        self.assertEqual(self.player.position, 42)

    def test_load_does_not_overwrite_new_playback_or_apply_to_another_account(self):
        self.gate = threading.Event(); engine, queue = self.player.mpv, list(self.player.queue)
        self.player.handle({'cmd':'hosted_load','id':key(10),'play':True,'request':1})
        self.assertTrue(self.entered.wait(1))
        self.player.handle({'cmd':'pause'})
        self.gate.set(); self.player.hosted_work.submit(lambda: None).result(timeout=4)
        self.assertEqual(self.player.queue, queue); self.assertIs(self.player.mpv, engine); self.assertTrue(self.player.paused)
        self.assertTrue(any('playback changed' in e.get('message','') for e in self.events))
        self.gate.clear(); self.entered.clear(); self.events.clear()
        self.player.handle({'cmd':'hosted_items','id':key(10),'request':2}); self.assertTrue(self.entered.wait(1))
        with self.player.lock: self.player.client = Jellyfin('https://other.example'); self.player.clear_hosted()
        self.gate.set(); self.player.hosted_work.submit(lambda: None).result(timeout=4)
        self.assertFalse(any(e['type']=='hosted_items' for e in self.events))

    def test_pending_reads_coalesce_and_repeat_create_is_blocked(self):
        self.gate = threading.Event()
        self.player.handle({'cmd':'hosted_items','id':key(10),'request':1}); self.assertTrue(self.entered.wait(1))
        for n in range(2,32): self.player.handle({'cmd':'hosted_items','id':key(10),'request':n})
        self.player.handle({'cmd':'hosted_create','name':'Blocked while busy','request':32})
        self.gate.set(); self.player.hosted_work.submit(lambda: None).result(timeout=4)
        self.assertEqual(len([c for c in self.calls if '/Playlists/' in c[1]]), 2)
        self.assertEqual([e['request'] for e in self.events if e['type']=='hosted_items'], [31])
        self.assertFalse(self.created)

    def test_create_success_is_acknowledged_even_if_preview_fails(self):
        self.fail_preview = True
        self.run_command('hosted_create', name='Created once')
        self.assertEqual(len(self.created), 1)
        self.assertTrue(any(e['type']=='hosted_created' for e in self.events))
        self.assertTrue(any('Playlist created' in e.get('message','') for e in self.events))

    def test_invalid_creation_reply_never_retries_the_write(self):
        self.bad_creation_reply = True
        self.run_command('hosted_create', name='Created with lost confirmation')
        self.assertEqual(len(self.created), 1)
        self.assertTrue(any('may already exist' in e.get('message','') for e in self.events))
        self.run_command('hosted_list')
        self.assertEqual(len(self.created), 1)

    def test_older_or_unknown_server_cannot_silently_create_public_playlists(self):
        for version in ('10.8.13', '', 'invalid', None):
            self.server_version = version
            self.run_command('hosted_create', name='Must remain private')
        self.assertFalse(self.created)
        self.assertFalse(any(c[0]=='POST' for c in self.calls))
        self.assertTrue(any('10.9' in e.get('message','') for e in self.events))

    def test_real_hosted_playback_uses_authenticated_relay(self):
        with tempfile.TemporaryDirectory() as d:
            audio = Path(d)/'fixture.wav'
            subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','sine=duration=0.3',str(audio)],check=True)
            self.audio = audio.read_bytes(); self.items = [item(1)]
            self.player.discard_engine(); self.player.mpv_factory = Mpv
            original = subprocess.Popen
            output = Path(d)/'played.wav'
            with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: original(args+['--ao=pcm', '--ao-pcm-file='+str(output)],**kw)):
                self.run_command('hosted_load', id=key(10), play=True)
            self.assertFalse(any(e['type']=='hosted_error' for e in self.events), [e.get('message') for e in self.events if e['type']=='hosted_error'])
            # mpv initially reports idle before loading. Require a stream request
            # before accepting EOF, and verify decoded output without relying on
            # progress ticks that may not arrive for a very short song.
            self.assertTrue(wait_for(lambda: self.player.idle and any('/Audio/' in c[1] for c in self.calls)))
            self.assertTrue(any('/Audio/' in c[1] and 'Token="fixture-token"' in c[2] for c in self.calls))
            self.player.discard_engine()
            with wave.open(str(output), 'rb') as wav:
                self.assertAlmostEqual(wav.getnframes()/wav.getframerate(), .3, delta=.02)
            self.assertFalse(any(e['type']=='hosted_error' for e in self.events))


class HostedBounds(unittest.TestCase):
    def test_limits_paging_cancellation_and_duplicate_playlist_ids(self):
        client = Mock(); client.user = key(100); client.response_bytes = 2
        client.request.return_value = {'Items':[{'Id':key(10),'Name':'One'},{'Id':key(10),'Name':'Again'}], 'TotalRecordCount':2}
        with self.assertRaisesRegex(ValueError,'repeated'): hosted.catalog(client)
        with patch('jellyfin_playlists.MAX_BYTES',1), self.assertRaisesRegex(ValueError,'safety limit'): hosted.catalog(client)
        client.request.return_value = {'Items':[], 'TotalRecordCount':1}
        with self.assertRaisesRegex(ValueError,'incomplete'): hosted.tracks(client,key(10))
        client.request.return_value = {'Items':[], 'TotalRecordCount':100001}
        with self.assertRaisesRegex(ValueError,'safety limit'): hosted.tracks(client,key(10))
        client.request.reset_mock()
        with self.assertRaises(hosted.Cancelled): hosted.catalog(client,lambda:True)
        client.request.assert_not_called()

    def test_repeated_track_pages_are_preserved_and_bounded(self):
        client = Mock(); client.user = key(100); client.response_bytes = 2
        client.request.return_value = {'Items':[item(1)], 'TotalRecordCount':3}
        self.assertEqual(len(hosted.tracks(client,key(10))),3)
        self.assertEqual([c.args[1]['StartIndex'] for c in client.request.call_args_list],[0,1,2])
