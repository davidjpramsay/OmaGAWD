"""Portal requests and the native manager's bounded, acknowledged source edits."""
import json
import shutil
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, Mock

from gi.repository import GLib
from file_picker import FilePicker, selected_paths
from local_music_window import LocalMusicWindow, action_from_json, theme_css, MAX_ACTION
from local_library import LocalLibrary
from test_backend import Player, FakeMpv, song


class Connection:
    def __init__(self): self.calls = []; self.subscriptions = {}; self.unsubscribed = []
    def get_unique_name(self): return ':1.42'
    def signal_subscribe(self, *args):
        key = len(self.subscriptions)+1; self.subscriptions[key] = args; return key
    def signal_unsubscribe(self, key): self.unsubscribed.append(key)
    def call(self, *args): self.calls.append(args)
    def call_finish(self, result): return result


class PortalTests(unittest.TestCase):
    def test_native_portal_options_response_race_and_folder(self):
        for folder in (False, True):
            bus = Connection(); results = []
            picker = FilePicker(folder, lambda p,e: results.append((p,e)), connection=bus)
            try:
                call = bus.calls[0]
                self.assertEqual(call[:4], ('org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop', 'org.freedesktop.portal.FileChooser', 'OpenFile'))
                options = call[4].unpack()[2]
                self.assertEqual(options['directory'], folder); self.assertEqual(options['multiple'], not folder)
                self.assertEqual('filters' in options, not folder)
                if not folder:
                    patterns = [pattern for kind,pattern in options['filters'][0][1]]
                    self.assertIn('*.flac', patterns); self.assertIn('*.FLAC', patterns)
                    self.assertNotIn('*', patterns); self.assertNotIn('*.avs', patterns)
                self.assertEqual(bus.subscriptions[1][3], picker.path)
                # Response can arrive before the method reply; it is already subscribed.
                picker.response(None, None, picker.path, None, None, GLib.Variant('(ua{sv})', (1, {})))
                self.assertEqual(results, [(None, '')])
                picker.opened(bus, GLib.Variant('(o)', (picker.path,)))
                self.assertEqual(len(results), 1)
            finally: picker.cancel()

    def test_success_validates_local_uris_and_cancel_closes_only_request(self):
        with tempfile.TemporaryDirectory() as d:
            audio = Path(d)/'music\nname.wav'; audio.write_bytes(b'fixture')
            self.assertEqual(selected_paths([audio.as_uri()]), [str(audio)])
            for uris in ([], ['https://example.com/a.mp3'], ['file://remote/music.mp3'], [audio.as_uri()+'\nfile:///other'], ['x']*1001):
                with self.assertRaises(ValueError): selected_paths(uris)
            bus = Connection(); results = []
            picker = FilePicker(False, lambda p,e: results.append((p,e)), connection=bus)
            picker.response(None,None,picker.path,None,None,GLib.Variant('(ua{sv})',(0,{'uris':GLib.Variant('as',[audio.as_uri()])})))
            self.assertEqual(results, [([str(audio)], '')])
            picker.cancel(); self.assertEqual(len(results), 1)
            bus = Connection(); picker = FilePicker(True, lambda p,e: None, connection=bus)
            picker.cancel(); self.assertEqual(bus.calls[-1][1:4], (picker.path, 'org.freedesktop.portal.Request', 'Close'))

    def test_failure_and_timeout_are_not_silent_gtk_fallbacks(self):
        for status in (2, 3):
            results = []; picker = FilePicker(False, lambda p,e: results.append((p,e)), connection=Connection())
            picker.response(None,None,picker.path,None,None,GLib.Variant('(ua{sv})',(status,{})))
            self.assertTrue(results[0][1]); self.assertIsNone(results[0][0])
        results = []; picker = FilePicker(False, lambda p,e: results.append((p,e)), connection=Connection())
        GLib.source_remove(picker.timer); picker.expired()
        self.assertIn('timed out', results[0][1]); self.assertTrue(picker.done)


class ManagerTests(unittest.TestCase):
    def test_cold_manager_startup_does_not_write_plugin_cache_files(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            for name in ('process_guard.py','file_picker.py','drop_receiver.py','media_policy.py'):
                shutil.copy(Path(__file__).resolve().parents[1]/name,root/name)
            helper=root/'local_music_window.py'
            helper.write_text("import file_picker,json,sys\njson.loads(sys.stdin.readline())\nprint(json.dumps({'cmd':'local_add','paths':['/tmp/music']}),flush=True)\nassert json.loads(sys.stdin.readline())['paths']==['/tmp/music']\n")
            seen=[];done=threading.Event()
            window=LocalMusicWindow(lambda c:(seen.append(c),window.update(['/tmp/music'])),done.set)
            try:
                with patch('local_music_window.__file__',str(helper)):window.start([], {})
                self.assertTrue(done.wait(4));self.assertEqual(len(seen),1)
                self.assertEqual(list(root.rglob('*.pyc')),[])
                self.assertFalse((root/'__pycache__').exists())
            finally:window.close()

    def test_start_failure_restores_the_settings_view_and_keeps_playback(self):
        with tempfile.TemporaryDirectory() as d:
            events=[]; p=Player(events.append,FakeMpv,local=LocalLibrary(Path(d)/'local.json'))
            p.mpv=FakeMpv(None); engine=p.mpv
            try:
                with patch('backend.LocalMusicWindow') as factory:
                    factory.return_value.start.side_effect=OSError('Unavailable')
                    with self.assertRaises(RuntimeError): p.handle({'cmd':'manage_local'})
                    factory.return_value.close.assert_called_once()
                self.assertIs(p.mpv,engine); self.assertIsNone(p.local_window)
                self.assertEqual(events[-1], {'type':'local_manager_closed'})
            finally: p.close()

    def test_only_source_actions_and_bounded_plain_theme(self):
        good = {'cmd':'local_add','paths':['/tmp/music']}
        self.assertEqual(action_from_json(json.dumps(good).encode()), good)
        for body in ({'cmd':'play','paths':['/tmp/music']}, {'cmd':'local_add','paths':['https://example.com']}, {'cmd':'local_remove','paths':[]}, {'cmd':'local_add','paths':['/tmp/a\0']}, {'cmd':'local_add','paths':['/tmp/a']*1001}):
            with self.assertRaises(ValueError): action_from_json(json.dumps(body).encode())
        with self.assertRaises(ValueError): action_from_json(b' '* (MAX_ACTION+1))
        css = theme_css({'font':'evil"; @import url(http://bad);','background':'red; anything','size':float('inf')})
        self.assertNotIn('@import', css); self.assertNotIn('http://', css); self.assertIn('monospace', css)

    def test_manager_applies_source_edits_through_backend_without_touching_queue(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); path = root/'music'; path.mkdir()
            local = LocalLibrary(root/'local.json'); p = Player(lambda _:None, FakeMpv, local=local)
            p.queue=[dict(song(1), key='one')]; p.index,p.position,p.idle,p.paused=0,42,False,False
            p.mpv = FakeMpv(None); engine=p.mpv
            try:
                with patch('backend.LocalMusicWindow') as constructor:
                    p.handle({'cmd':'manage_local','theme':{}})
                    action,closed=constructor.call_args.args; manager=constructor.return_value
                    action({'cmd':'local_add','paths':[str(path)]}); p.work.submit(lambda:None).result(timeout=3)
                    self.assertEqual(local.roots,[str(path)]); manager.update.assert_called_with(local.roots,'')
                    action({'cmd':'local_remove','paths':[str(path)]}); p.work.submit(lambda:None).result(timeout=3)
                    self.assertEqual(local.roots,[]); self.assertTrue(path.exists())
                    self.assertEqual((p.index,p.position,p.paused,p.idle),(0,42,False,False)); self.assertIs(p.mpv,engine)
                    p.handle({'cmd':'manage_local'}); self.assertEqual(constructor.call_count,1); manager.present.assert_called_once()
                    manager.proc.returncode=0; closed(); self.assertIsNone(p.local_window)
                    action({'cmd':'local_add','paths':[str(path)]}); self.assertEqual(local.roots,[])
            finally: p.close()

    def test_manager_pipe_acknowledges_edits_and_closes_oversized_peer(self):
        original = subprocess.Popen
        for oversized in (False,True):
            seen=[]; done=threading.Event()
            window=LocalMusicWindow(lambda c:(seen.append(c),window.update(['/tmp/music'])), done.set)
            script = "import sys,json;json.loads(sys.stdin.readline());" + ("sys.stdout.write('x'*65538);sys.stdout.flush()" if oversized else "print(json.dumps({'cmd':'local_add','paths':['/tmp/music']}),flush=True);assert json.loads(sys.stdin.readline())['paths']==['/tmp/music']")
            with patch('local_music_window.subprocess.Popen', side_effect=lambda args,**kw:original(['/usr/bin/python3','-c',script],**kw)):
                window.start([], {})
            self.assertTrue(done.wait(4)); window.close()
            self.assertEqual(bool(seen),not oversized); self.assertIsNotNone(window.proc.returncode)


if __name__ == '__main__': unittest.main()
