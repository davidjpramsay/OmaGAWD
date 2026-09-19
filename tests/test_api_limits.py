"""Untrusted Jellyfin response framing, JSON and pagination regression tests."""
import io
import json
import threading
import unittest
from email.message import Message
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
from test_backend import Jellyfin
from backend import read_api_body


class Body(io.BytesIO):
    def __init__(self, data, length=None):
        super().__init__(data)
        self.headers = Message()
        if length is not None: self.headers['Content-Length'] = length
        self.reads = []
    def read1(self, size):
        self.reads.append(size)
        return super().read1(size)


class ApiLimitTests(unittest.TestCase):
    def test_declared_oversize_rejected_without_reading(self):
        with patch('backend.MAX_API_BYTES', 32):
            body = Body(b'x', '33')
            with self.assertRaisesRegex(ValueError, 'safety limit'): read_api_body(body)
            self.assertEqual(body.reads, [])

    def test_streaming_cap_and_exact_boundary(self):
        with patch('backend.MAX_API_BYTES', 32):
            self.assertEqual(read_api_body(Body(b'x' * 32)), b'x' * 32)
            for length in (None, '1'):
                body = Body(b'x' * 1000, length)
                with self.assertRaisesRegex(ValueError, 'safety limit'): read_api_body(body)
                self.assertEqual(body.tell(), 33)
                self.assertLessEqual(max(body.reads), 33)

    def test_invalid_length_and_encoding(self):
        for length in ('-1', 'abc', '1,2'):
            with self.assertRaises(ValueError): read_api_body(Body(b'', length))
        body = Body(b'compressed'); body.headers['Content-Encoding'] = 'gzip'
        with self.assertRaisesRegex(ValueError, 'encoded'): read_api_body(body)
        self.assertEqual(body.reads, [])

    def test_slow_response_deadline(self):
        with patch('backend.time.monotonic', side_effect=[0,31]):
            with self.assertRaisesRegex(ValueError, 'too long'): read_api_body(Body(b'x'))

    def test_real_chunked_and_unframed_oversize_and_invalid_json(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                self.send_response(200)
                if self.path == '/chunked': self.send_header('Transfer-Encoding','chunked')
                if self.path == '/declared': self.send_header('Content-Length','1000')
                self.end_headers()
                try:
                    if self.path == '/chunked': self.wfile.write(b'40\r\n'+b'x'*64+b'\r\n0\r\n\r\n')
                    elif self.path == '/array': self.wfile.write(b'[]')
                    elif self.path == '/nan': self.wfile.write(b'{"n":NaN}')
                    elif self.path == '/overflow': self.wfile.write(b'{"n":1e400}')
                    elif self.path == '/valid': self.wfile.write(b'{"Items":[]}')
                    else: self.wfile.write(b'x'*64)
                except (BrokenPipeError,ConnectionResetError): pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            client=Jellyfin(f'http://127.0.0.1:{server.server_port}')
            with patch('backend.MAX_API_BYTES',32):
                for path in ('/chunked','/unframed','/declared'):
                    with self.subTest(path=path), self.assertRaisesRegex(ValueError,'safety limit'): client.request(path)
                for path in ('/array','/nan','/overflow'):
                    with self.subTest(path=path), self.assertRaises(ValueError): client.request(path)
                self.assertEqual(client.request('/valid'), {'Items':[]})
        finally: server.shutdown(); server.server_close()

    def test_pagination_cannot_repeat_forever(self):
        client=Jellyfin('https://example.invalid')
        with patch.object(client,'request',return_value={'Items':[{'Id':'1'}],'TotalRecordCount':1000000}) as request:
            with self.assertRaisesRegex(ValueError,'repeated'): client.songs('music')
            self.assertEqual(request.call_count,2)

    def test_pagination_track_and_byte_budgets(self):
        client=Jellyfin('https://example.invalid')
        for limit in ('MAX_LIBRARY_TRACKS','MAX_LIBRARY_BYTES'):
            client.response_bytes=2
            with patch('backend.'+limit,1), patch.object(client,'request',return_value={'Items':[{'Id':'1'},{'Id':'2'}]}):
                with self.assertRaisesRegex(ValueError,'safety limit'): client.songs('music')


class ProbeLimitTests(unittest.TestCase):
    def test_probe_output_is_bounded_and_process_reaped(self):
        import subprocess
        import sys
        from local_library import probe_output
        real = subprocess.Popen
        processes = []
        def launch(*args, **kwargs):
            process = real(*args, **kwargs)
            processes.append(process)
            return process
        with patch('local_library.MAX_PROBE_BYTES', 32), patch('local_library.subprocess.Popen', side_effect=launch):
            with self.assertRaisesRegex(ValueError, 'safety limit'):
                probe_output([sys.executable, '-c', "import sys,time; sys.stdout.write('x'*1000); sys.stdout.flush(); time.sleep(30)"])
        self.assertIsNotNone(processes[0].poll())
        self.assertEqual(probe_output([sys.executable, '-c', "print('{}',end='')"]), b'{}')

    def test_probe_timeout(self):
        import sys
        from local_library import probe_output
        with self.assertRaisesRegex(ValueError, 'timed out'):
            probe_output([sys.executable, '-c', 'import time; time.sleep(30)'], timeout=.1)
