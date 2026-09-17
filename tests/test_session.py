import json
import unittest
from unittest.mock import Mock, patch
from test_backend import Jellyfin, Player, FakeMpv
from session_store import SessionStore


class SessionTests(unittest.TestCase):
    def test_store_sends_secret_over_stdin(self):
        client = Jellyfin('https://example.com')
        client.token, client.user = 'private-token', 'u'
        with patch('session_store.subprocess.run', return_value=Mock(returncode=0, stdout='', stderr='')) as run:
            SessionStore().save(client, 'david')
        args, kw = run.call_args
        self.assertNotIn('private-token', str(args))
        data = json.loads(kw['input'])
        self.assertEqual(data['token'], 'private-token')
        self.assertNotIn('password', data)
    def test_restore_uses_saved_device_and_never_password_login(self):
        store = Mock()
        store.load.return_value = {'url': 'https://example.com', 'username': 'david', 'token': 'saved', 'user': 'u', 'device': 'device1'}
        events = []
        p = Player(events.append, FakeMpv, store)
        with patch.object(Jellyfin, 'request', return_value={}), patch.object(Jellyfin, 'libraries', return_value=[]), patch.object(Jellyfin, 'login') as login, patch.object(Player, 'revoke') as revoke:
            p.network({'cmd': 'restore'}, 0)
            self.assertEqual(p.client.device, 'device1')
            self.assertEqual(p.client.token, 'saved')
            self.assertTrue(p.remembered)
            login.assert_not_called()
            p.close()
            revoke.assert_not_called()
        self.assertTrue(any(e['type'] == 'connected' for e in events))
    def test_restores_last_library_and_falls_back_if_missing(self):
        for saved_folder, expected in [('second', 'second'), ('removed', 'first')]:
            with self.subTest(folder=saved_folder):
                store, events = Mock(), []
                store.load.return_value = {'url': 'https://example.com', 'username': 'david',
                                          'token': 'saved', 'user': 'u', 'device': 'd', 'folder': saved_folder}
                p = Player(events.append, FakeMpv, store)
                with patch.object(Jellyfin, 'request', return_value={}), patch.object(Jellyfin, 'libraries',
                     return_value=[{'id': 'first'}, {'id': 'second'}]), patch.object(Jellyfin, 'songs', return_value=[]) as songs:
                    p.network({'cmd': 'restore'}, 0)
                    songs.assert_called_once_with(expected)
                    self.assertEqual(p.folder, expected)
                    self.assertTrue(any(e.get('type') == 'connected' and e.get('folder') == expected for e in events))
                p.close()

    def test_library_change_saved_without_resaving_on_refresh(self):
        store = Mock()
        p = Player(lambda event: None, FakeMpv, store)
        p.client = Jellyfin('https://example.com')
        p.remembered, p.username, p.folder = True, 'david', 'first'
        with patch.object(Jellyfin, 'songs', return_value=[]):
            p.network({'cmd': 'library', 'folder': 'second'}, 0)
            p.network({'cmd': 'library', 'folder': 'second'}, 0)
        store.save.assert_called_once_with(p.client, 'david', 'second')
        p.close()

    def test_successful_login_is_saved(self):
        store, events = Mock(), []
        p = Player(events.append, FakeMpv, store)
        def login(client, username, password): client.token, client.user = 'token', 'u'
        with patch.object(Jellyfin, 'login', login), patch.object(Jellyfin, 'libraries', return_value=[]):
            p.network({'cmd': 'login', 'url': 'https://example.com', 'username': 'david', 'password': 'private'}, 0)
        store.save.assert_called_once_with(p.client, 'david')
        self.assertTrue(p.remembered)
        p.close()
    def test_logout_forgets_saved_token(self):
        store = Mock()
        p = Player(lambda event: None, FakeMpv, store)
        p.handle({'cmd': 'logout'})
        p.work.shutdown(wait=True)
        store.clear.assert_called_once()
        self.assertFalse(p.remembered)
    def test_expired_session_is_removed(self):
        import urllib.error
        store = Mock()
        store.load.return_value = {'url': 'https://example.com', 'username': 'david', 'token': 'expired', 'user': 'u', 'device': 'device1'}
        events = []
        p = Player(events.append, FakeMpv, store)
        with patch.object(Jellyfin, 'request', side_effect=urllib.error.HTTPError('https://example.com/Users/Me',401,'Unauthorized',{},None)):
            p.network({'cmd':'restore'},0)
        store.clear.assert_called_once()
        self.assertTrue(any('expired' in e.get('message','') for e in events))
        p.close()
    def test_keyring_failure_does_not_block_login(self):
        store = Mock()
        store.save.side_effect = RuntimeError('System keyring unavailable.')
        events = []
        p = Player(events.append, FakeMpv, store)
        def login(client, username, password): client.token, client.user = 'token', 'u'
        with patch.object(Jellyfin,'login',login), patch.object(Jellyfin,'libraries',return_value=[]), patch.object(Player,'revoke'):
            p.network({'cmd':'login','url':'https://example.com','username':'u','password':'p'},0)
            self.assertFalse(p.remembered)
            self.assertTrue(any(e['type']=='connected' for e in events))
            p.close()
