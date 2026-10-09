import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import update_check as updates
from playback_store import PlaybackStore
from test_backend import Player, FakeMpv, song


class Response(io.BytesIO):
    headers = {}


class ReleaseChecks(unittest.TestCase):
    def test_omarchy_only_numeric_order_and_safe_links(self):
        rows = [
            {'tag_name': 'macos-v99.0.0', 'body': 'Mac'},
            {'tag_name': 'omarchy-v0.9.0'},
            {'tag_name': 'omarchy-v0.10.0', 'html_url': 'javascript:alert(1)', 'body': '<b>Plain text</b>\x00'},
            {'tag_name': 'omarchy-v0.11.0', 'prerelease': True},
            {'tag_name': 'omarchy-v0.12.0', 'draft': True},
            {'tag_name': 'omarchy-v0.99.0;bad'}, None]
        result = updates.release_info(rows, '0.9.9')
        self.assertTrue(result['available'])
        self.assertEqual(result['latest'], '0.10.0')
        self.assertEqual(result['notes'], 'Plain text')
        self.assertEqual(result['url'], 'https://github.com/davidjpramsay/OmaGAWD/releases/tag/omarchy-v0.10.0')
        self.assertFalse(updates.release_info(rows, '0.10.0')['available'])
        self.assertFalse(updates.release_info(rows, '0.13.0')['available'])
        with self.assertRaises(ValueError): updates.release_info({}, '0.9.0')
        with self.assertRaises(ValueError): updates.release_info([{'tag_name': 'macos-v1.0.0'}], '0.9.0')
        for value in ['1.0', '01.0.0', '1.0.0-beta', '9999999.0.0']:
            with self.assertRaises(ValueError): updates.version(value)

    def test_bounded_response_deadline_and_failure(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(updates, 'managed_install', return_value=False):
            (Path(directory) / 'manifest.json').write_text('{"version":"0.7.2"}')
            opener = Mock()
            opener.open.return_value = Response(json.dumps([{'tag_name': 'omarchy-v0.8.0', 'body': 'x' * 20000}]).encode())
            result = updates.check(directory, opener)
            self.assertEqual(len(result['notes']), 4000)
            self.assertFalse(result['managed'])
            request = opener.open.call_args.args[0]
            self.assertEqual(request.full_url, updates.RELEASES)
            self.assertIsNone(request.get_header('Authorization'))
            opener.open.return_value = Response(b' ' * (updates.MAX_BYTES + 1))
            with self.assertRaises(ValueError): updates.check(directory, opener)
            opener.open.return_value = Response(b'[]')
            with self.assertRaises(ValueError): updates.check(directory, opener, clock=Mock(side_effect=[0, 0, 11]))
            opener.open.side_effect = OSError('Offline')
            with self.assertRaises(OSError): updates.check(directory, opener)
        self.assertIsNone(updates.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://elsewhere.example'))

    def test_only_official_installed_checkout_can_update(self):
        with tempfile.TemporaryDirectory() as home:
            installed = Path(home) / '.config/omarchy/plugins/david.omaamp'
            installed.mkdir(parents=True)
            with patch.object(updates.subprocess, 'run') as run:
                self.assertFalse(updates.managed_install(installed, home))
                (installed / '.git').mkdir()
                run.return_value.stdout = b'git@github.com:davidjpramsay/OmaGAWD.git\n'
                self.assertTrue(updates.managed_install(installed, home))
                self.assertFalse(updates.managed_install(Path(home) / 'preview', home))
                run.return_value.stdout = b'https://github.com/someone/fork.git\n'
                self.assertFalse(updates.managed_install(installed, home))
            installed.rename(installed.with_name('checkout'))
            installed.symlink_to(installed.with_name('checkout'), target_is_directory=True)
            self.assertFalse(updates.managed_install(installed, home))

    def test_native_updater_keeps_confirmation_and_reloads_only_when_changed(self):
        with patch.object(updates, 'managed_install', return_value=True), \
             patch.object(updates.subprocess, 'check_output', side_effect=[b'old', b'new']), \
             patch.object(updates.subprocess, 'run') as run:
            updates.apply(Path('/sample'))
            self.assertEqual(run.call_args_list[0].args[0], ['omarchy', 'plugin', 'update', 'david.omaamp'])
            self.assertEqual(run.call_args_list[1].args[0], ['omarchy', 'restart', 'shell'])
            self.assertEqual(run.call_args_list[2].args[0], ['omarchy-shell', 'shell', 'summon', 'david.omaamp', '{}'])
        with patch.object(updates, 'managed_install', return_value=True), \
             patch.object(updates.subprocess, 'check_output', return_value=b'unchanged'), \
             patch.object(updates.subprocess, 'run') as run:
            updates.apply(Path('/sample'))
            self.assertEqual(run.call_count, 1)
        with patch.object(updates, 'managed_install', return_value=False), patch.object(updates.subprocess, 'Popen') as spawn:
            with self.assertRaises(RuntimeError): updates.launch(Path('/preview'))
            spawn.assert_not_called()
        with patch.object(updates, 'managed_install', return_value=True), patch.object(updates.shutil, 'which', return_value='/sample/launcher'), patch.object(updates.subprocess, 'Popen') as spawn:
            spawn.return_value.wait.return_value = 1
            with self.assertRaises(RuntimeError): updates.launch(Path('/sample'))
            spawn.return_value.wait.return_value = 0
            updates.launch(Path('/sample'))
            self.assertEqual(spawn.call_args.args[0][:2], ['omarchy-launch-terminal', '/usr/bin/python3'])
            self.assertEqual(spawn.call_args.args[0][-1], '--apply')


class UpdatePlayback(unittest.TestCase):
    def test_prepare_pauses_and_flushes_position_before_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            store = PlaybackStore(Path(directory) / 'session.json')
            messages = []
            player = Player(messages.append, FakeMpv, playback_store=store)
            player.queue = [dict(song(1), id='local:sample', key='saved', source='local', path='/sample.mp3')]
            player.index = 0; player.idle = False; player.position = 47
            player.mpv = FakeMpv(player.event)
            player.paused = False
            try:
                player.handle({'cmd': 'prepare_update', 'request': 17})
                self.assertTrue(player.paused)
                self.assertFalse(player.idle)
                self.assertEqual(player.position, 47)
                self.assertEqual(store.load()['position'], 47)
                self.assertEqual(messages[-1]['type'], 'update_ready')
                self.assertEqual(messages[-1]['request'], 17)
                self.assertIn(('set_property', 'pause', True), player.mpv.commands)
                with patch.object(store, 'write', side_effect=OSError('disk full')):
                    messages.clear()
                    player.handle({'cmd': 'prepare_update'})
                    self.assertEqual(messages[-1]['type'], 'update_error')
                    self.assertFalse(any(row['type'] == 'update_ready' for row in messages))
            finally:
                player.close()
