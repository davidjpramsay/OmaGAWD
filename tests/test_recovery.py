"""Regression coverage for the security and recovery review."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend import Jellyfin, Player
from local_library import LocalLibrary
from stream_proxy import StreamProxy


class RecoveryTests(unittest.TestCase):
    def test_damaged_settings_are_preserved_and_recoverable(self):
        for content in ('{broken', '[]', '{"paths":1}'):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as d:
                path = Path(d) / 'local.json'
                path.write_text(content)
                local = LocalLibrary(path)
                self.assertEqual(local.roots, [])
                self.assertTrue(local.warning)
                self.assertEqual(next(Path(d).glob('*.damaged-*')).read_text(), content)
                local.save()
                self.assertEqual(json.loads(path.read_text())['paths'], [])

    def test_local_restore_survives_keyring_and_remote_failures(self):
        for failure in ('keyring', 'network', 'expired', 'none'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as d:
                local = LocalLibrary(Path(d) / 'local.json')
                local.prefer_local = True
                store = Mock()
                store.load.return_value = dict(url='https://example.invalid', username='u', token='fake', user='u', device='d')
                if failure == 'keyring': store.load.side_effect = RuntimeError('Keyring locked')
                elif failure == 'none': store.load.return_value = None
                error = urllib.error.HTTPError('https://example.invalid', 401, 'Expired', {}, None) if failure == 'expired' else OSError('Offline')
                events = []
                p = Player(events.append, store=store, local=local)
                try:
                    with patch.object(local, 'scan', return_value=([{'id': 'local:test'}], 0)), patch.object(Jellyfin, 'request', side_effect=error):
                        p.network({'cmd': 'restore'}, 0)
                    self.assertEqual(p.songs, [{'id': 'local:test'}])
                    self.assertTrue(any(e.get('type') == 'library' and e['folder'] == 'local' for e in events))
                finally: p.close()

    def test_successful_remote_restore_preserves_local_selection(self):
        with tempfile.TemporaryDirectory() as d:
            local = LocalLibrary(Path(d) / 'local.json'); local.prefer_local = True
            store = Mock(); store.load.return_value = dict(url='https://example.invalid', username='u', token='fake', user='u', device='d')
            events = []; p = Player(events.append, store=store, local=local)
            try:
                with patch.object(local, 'scan', return_value=([{'id':'local:test'}],0)), patch.object(Jellyfin,'request',return_value={}), patch.object(Jellyfin,'libraries',return_value=[{'id':'remote','name':'Music'}]):
                    p.network({'cmd':'restore'},0)
                self.assertTrue(next(e for e in events if e['type']=='connected')['preserveLocal'])
                self.assertEqual(p.songs,[{'id':'local:test'}])
            finally: p.close()

    def test_guard_kills_child_when_parent_is_killed(self):
        guard = str(Path(__file__).resolve().parents[1] / 'process_guard.py')
        # A dedicated test parent launches a guarded child; no live player involved.
        code = "import subprocess,os,sys,time; p=subprocess.Popen([sys.executable,sys.argv[1],str(os.getpid()),sys.executable,'-c',\"import time; print('ready',flush=True); time.sleep(30)\"]); print(p.pid,flush=True); time.sleep(30)"
        parent = subprocess.Popen([sys.executable, '-c', code, guard], stdout=subprocess.PIPE, text=True)
        child = None
        try:
            lines = [parent.stdout.readline().strip(), parent.stdout.readline().strip()]
            child = int(next(line for line in lines if line.isdigit()))
            self.assertIn('ready', lines)
            parent.kill(); parent.wait(timeout=3)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                stat = Path(f'/proc/{child}/stat')
                try:
                    if stat.read_text().split()[2] == 'Z': break
                except FileNotFoundError: break
                time.sleep(.02)
            else: self.fail('Guarded child survived parent death')
        finally:
            if parent.poll() is None: parent.kill(); parent.wait()
            if child:
                try: os.kill(child, signal.SIGKILL)
                except ProcessLookupError: pass
            parent.stdout.close()


class ProxyTests(unittest.TestCase):
    def test_redirects_never_forward_credentials_and_ranges_work(self):
        received = []
        class Sink(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                received.append(self.headers.get('Authorization'))
                self.send_response(200); self.end_headers()
        sink = ThreadingHTTPServer(('127.0.0.1',0), Sink)
        class Origin(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                if self.path == '/redirect':
                    self.send_response(302); self.send_header('Location',f'http://localhost:{sink.server_port}/audio'); self.end_headers(); return
                if self.headers.get('Authorization') != 'fake-token': self.send_error(401); return
                payload = b'2345' if self.headers.get('Range') == 'bytes=2-5' else b'0123456789'
                self.send_response(206 if len(payload)==4 else 200)
                self.send_header('Content-Length',str(len(payload)))
                if len(payload)==4: self.send_header('Content-Range','bytes 2-5/10')
                self.end_headers(); self.wfile.write(payload)
        origin = ThreadingHTTPServer(('127.0.0.1',0), Origin)
        for s in (origin,sink): threading.Thread(target=s.serve_forever,daemon=True).start()
        proxy = StreamProxy()
        try:
            url = proxy.stream(f'http://127.0.0.1:{origin.server_port}/redirect',{'Authorization':'fake-token'})
            with self.assertRaises(urllib.error.HTTPError) as caught: urllib.request.urlopen(url)
            self.assertEqual(caught.exception.code,502); caught.exception.close()
            self.assertEqual(received,[])
            url = proxy.stream(f'http://127.0.0.1:{origin.server_port}/audio',{'Authorization':'fake-token'})
            self.assertNotIn('fake-token',url)
            with urllib.request.urlopen(urllib.request.Request(url,headers={'Range':'bytes=2-5'})) as response:
                self.assertEqual(response.status,206)
                self.assertEqual(response.headers['Content-Range'],'bytes 2-5/10')
                self.assertEqual(response.read(),b'2345')
        finally:
            proxy.close()
            for s in (origin,sink): s.shutdown(); s.server_close()
