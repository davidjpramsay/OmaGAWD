"""Regression coverage for bounded explicit paste and the wider security review."""
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from bounded_process import run_bounded
from clipboard_io import read_clipboard
from local_library import LocalLibrary
from playback_store import validate
from stream_proxy import StreamProxy
from session_store import SessionStore
from test_backend import Player, FakeMpv, Jellyfin, song


class ChildLimits(unittest.TestCase):
    def test_child_memory_ceiling_and_cancellation(self):
        result = run_bounded([sys.executable, '-c', "x=bytearray(256*1024*1024)"], memory_limit=128*1024*1024)
        self.assertNotEqual(result.returncode,0)
        cancel=threading.Event();cancel.set()
        start=time.monotonic()
        with self.assertRaisesRegex(ValueError,'cancelled'):
            run_bounded([sys.executable,'-c','import time;time.sleep(30)'],cancel=cancel)
        self.assertLess(time.monotonic()-start,1)

    def test_stdout_stderr_share_budget_and_children_are_reaped(self):
        for stream in ('stdout', 'stderr'):
            with self.assertRaisesRegex(ValueError, 'safety limit'):
                run_bounded([sys.executable, '-c', f"import sys,time; sys.{stream}.write('x'*1024); sys.{stream}.flush(); time.sleep(30)"], limit=32)
        with self.assertRaisesRegex(ValueError, 'safety limit'):
            run_bounded([sys.executable, '-c', "import os; os.write(1,b'x'*20); os.write(2,b'x'*20)"], limit=32)
        result = run_bounded([sys.executable, '-c', 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())'], payload=b'secret\n', limit=32)
        self.assertEqual(result.stdout, b'secret\n')

    def test_slow_drip_and_descendant_pipe_timeout(self):
        start = time.monotonic()
        with self.assertRaisesRegex(ValueError, 'timed out'):
            run_bounded([sys.executable, '-c', "import time,os; [(os.write(1,b'x'),time.sleep(.01)) for _ in range(1000)]"], timeout=.1)
        self.assertLess(time.monotonic()-start, 1)
        with self.assertRaisesRegex(ValueError, 'timed out'):
            run_bounded([sys.executable, '-c', "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'])"], timeout=.1)

    def test_clipboard_only_uses_explicit_bounded_text_request(self):
        for primary in (False, True):
            with patch('clipboard_io.run_bounded', return_value=Mock(returncode=0, stdout='Music 🦙'.encode())) as run:
                self.assertEqual(read_clipboard(primary), 'Music 🦙')
                args = run.call_args.args[0]
                self.assertEqual('--primary' in args, primary)
                self.assertEqual(run.call_args.kwargs, {'limit': 65536, 'timeout': 2, 'memory_limit': 128*1024*1024})
        with patch('clipboard_io.run_bounded', return_value=Mock(returncode=0, stdout=b'\xff')):
            with self.assertRaises(UnicodeError): read_clipboard()

    def test_clipboard_worker_does_not_block_playback_or_queue_requests(self):
        started, release = threading.Event(), threading.Event()
        def read(primary): started.set(); release.wait(2); return 'sample'
        events = []; p = Player(events.append, FakeMpv)
        try:
            with patch('backend.read_clipboard', side_effect=read):
                p.handle({'cmd':'clipboard_paste','request':1})
                self.assertTrue(started.wait(1))
                start = time.monotonic()
                p.handle({'cmd':'volume','value':43})
                self.assertLess(time.monotonic()-start, .1)
                p.handle({'cmd':'clipboard_paste','request':2})
                self.assertTrue(any(e.get('request')==2 and 'error' in e for e in events))
                release.set(); p.clipboard_future.result(2)
            self.assertEqual(p.volume,43)
            self.assertIn({'type':'clipboard','request':1,'text':'sample'},events)
        finally: release.set(); p.close()

    def test_keyring_output_budget_and_unreadable_session(self):
        with patch('session_store.run_bounded', side_effect=ValueError('too large')) as run:
            with self.assertRaises(RuntimeError): SessionStore().load()
            self.assertEqual(run.call_args.kwargs['limit'],65536)
        with patch.object(SessionStore,'run',return_value='['*2000):
            with self.assertRaises(RuntimeError): SessionStore().load()


class MusicData(unittest.TestCase):
    def test_cancelled_scan_and_nonregular_audio_entries(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);local=LocalLibrary(root/'local.json');local.add([str(root)])
            os.mkfifo(root/'pipe.mp3');(root/'loop.mp3').symlink_to('loop.mp3')
            self.assertEqual(local.scan(),([],0))
            cancel=threading.Event();cancel.set()
            with self.assertRaisesRegex(RuntimeError,'cancelled'):local.scan(cancel)

    def test_stale_picker_never_opens_or_reopens_player(self):
        with tempfile.TemporaryDirectory() as d:
            local=LocalLibrary(Path(d)/'local.json');events=[];p=Player(events.append,FakeMpv,local=local)
            try:
                p.generation=1
                with patch('backend.run_bounded') as picker:
                    p.local_command({'cmd':'choose_folder'},0)
                picker.assert_not_called()
                self.assertEqual(events,[])
            finally:p.close()

    def test_untrusted_remote_metadata_shapes_are_safe_for_qml(self):
        client=Jellyfin('https://example.invalid')
        row={'Id':'1','Name': {'bad':'name'}, 'AlbumArtist':['wrong'], 'Artists':['A',None,{},'B'],
             'Album':42, 'RunTimeTicks':'not a number', 'IndexNumber':-4,'ParentIndexNumber':10**400}
        with patch.object(client,'request',return_value={'Items':[row],'TotalRecordCount':1}):
            track=client.songs('music')[0]
        self.assertEqual(track['duration'],0)
        self.assertEqual(track['track'],0)
        self.assertEqual(track['disc'],0)
        for field in ('title','artist','album','albumId'): self.assertIsInstance(track[field],str)
        with patch.object(client,'request',return_value={'Items':[dict(Id='2',Name='x'*4096)],'TotalRecordCount':1}):
            self.assertEqual(len(client.songs('music')[0]['title']),512)
        with patch.object(client,'request',return_value={'Items':[],'TotalRecordCount':'1'}):
            with self.assertRaises(ValueError): client.songs('music')
        with patch.object(client,'request',return_value={'User':[], 'AccessToken':[]}):
            with self.assertRaises(ValueError): client.login('user','password')

    def test_bad_local_metadata_is_skipped_and_text_is_bounded(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'tone.mp3';path.write_bytes(b'fixture')
            local=LocalLibrary(Path(d)/'local.json'); local.add([str(path)])
            malformed=[[], {'streams':[None]}, {'streams':[],'format':[]}, {'streams':[{'codec_type':'audio','tags':[]}]}]
            for row in malformed:
                local.cache={}
                with patch('local_library.probe_output', return_value=json.dumps(row).encode()):
                    self.assertEqual(local.scan(),([],1))
            data={'streams':[{'codec_type':'audio'}], 'format':{'duration':'NaN','tags':{'title':'x'*10000,'artist':['bad'],'track':'-4'}}}
            with patch('local_library.probe_output', return_value=json.dumps(data).encode()):
                tracks,skipped=local.scan()
                self.assertEqual(skipped,0)
                self.assertEqual(tracks[0]['artist'],'Unknown artist')
                self.assertEqual(len(tracks[0]['title']),512)
                self.assertEqual(tracks[0]['duration'],0)
                self.assertEqual(tracks[0]['track'],0)
            with patch('local_library.MAX_LOCAL_BYTES',16):
                with self.assertRaisesRegex(ValueError,'64 MiB'): local.scan()

    def test_private_atomic_sources_and_recovery_limits(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);music=root/'music';music.mkdir();path=root/'local.json'
            local=LocalLibrary(path);local.add([str(music)])
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
            original=path.read_bytes();other=root/'other';other.mkdir()
            with patch('local_library.os.replace',side_effect=OSError('Disk full')):
                with self.assertRaises(OSError): local.add([str(other)])
            self.assertEqual(path.read_bytes(),original)
            self.assertEqual(local.roots,[str(music)])
            self.assertFalse(list(root.glob('.local-*')))
            with patch('local_library.MAX_SOURCES',1):
                with self.assertRaises(ValueError):local.add([str(other)])
            pipe=root/'pipe';os.mkfifo(pipe)
            with self.assertRaises(ValueError):local.add([str(pipe)])
            path.write_bytes(b'x'*65)
            with patch('local_library.MAX_SOURCE_BYTES',64): recovered=LocalLibrary(path)
            self.assertEqual(recovered.roots,[])
            self.assertEqual(next(root.glob('local.json.damaged-*')).read_bytes(),b'x'*65)
            path.write_text('broken')
            with patch.object(Path,'rename',side_effect=OSError('Denied')): blocked=LocalLibrary(path)
            with self.assertRaises(RuntimeError):blocked.save()
            self.assertEqual(path.read_text(),'broken')

    def test_queue_limits_keep_current_music_and_invalid_mpris_keys_are_rejected(self):
        events=[];p=Player(events.append,FakeMpv)
        try:
            p.client=Jellyfin('https://example.invalid');p.songs=[song(1),song(2)]
            p.handle({'cmd':'replace_play','ids':['1']});p.position=42
            old=p.queue;engine=p.mpv
            with patch('backend.MAX_QUEUE_TRACKS',1):p.handle({'cmd':'add','ids':['2']})
            self.assertIs(p.queue,old);self.assertIs(p.mpv,engine);self.assertEqual(p.position,42)
            with patch('backend.MAX_SESSION_BYTES',65540):p.handle({'cmd':'replace_play','ids':['2']})
            self.assertIs(p.queue,old);self.assertFalse(p.paused)
            saved=p.session_snapshot();saved['queue'][0]['key']='foreign/bad'
            with self.assertRaises(ValueError):validate(saved)
        finally:p.client=None;p.close()


class RelayCleanup(unittest.TestCase):
    def test_oversized_mpv_ipc_never_reaches_qml(self):
        from backend import Mpv
        left,right=socket.socketpair();events=[]
        engine=object.__new__(Mpv);engine.sock=left;engine.closing=False;engine.callback=events.append
        reader=threading.Thread(target=engine.read)
        try:
            with patch('backend.MAX_IPC_BYTES',32):
                reader.start();right.sendall(b'{"event":"metadata","data":"'+b'x'*128+b'"}\n');reader.join(1)
            self.assertFalse(reader.is_alive())
            self.assertEqual(events,[{'event':'engine-exited'}])
        finally:left.close();right.close()

    def test_closing_relay_interrupts_stalled_upstream_reads(self):
        release=threading.Event();served=threading.Event()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                self.send_response(200);self.end_headers();served.set();release.wait(3)
        origin=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=origin.serve_forever,daemon=True).start()
        proxy=StreamProxy(); client=socket.create_connection(proxy.server.server_address)
        url=proxy.stream(f'http://127.0.0.1:{origin.server_port}/audio',{})
        route=url.split(str(proxy.server.server_port),1)[1]
        try:
            client.sendall(f'GET {route} HTTP/1.0\r\n\r\n'.encode())
            self.assertTrue(served.wait(1))
            deadline=time.monotonic()+1
            while not proxy.upstreams and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(proxy.upstreams)
            start=time.monotonic();proxy.close()
            self.assertLess(time.monotonic()-start,1)
            deadline=time.monotonic()+1
            while proxy.upstreams and time.monotonic()<deadline:time.sleep(.01)
            self.assertFalse(proxy.upstreams)
        finally:
            client.close();release.set();origin.shutdown();origin.server_close()
