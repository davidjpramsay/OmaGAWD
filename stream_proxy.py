"""Loopback audio relay: credentials never enter mpv or follow redirects."""
import secrets
import socket
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class LimitedHTTPServer(ThreadingHTTPServer):
    max_connections = 8
    client_timeout = 10

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(self.max_connections)
        self.clients = set()
        self.clients_lock = threading.Lock()
        super().__init__(*args, **kwargs)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        request.settimeout(self.client_timeout)
        with self.clients_lock:
            self.clients.add(request)
        try:
            super().process_request(request, address)
        except Exception:
            with self.clients_lock:
                self.clients.discard(request)
            self.slots.release()
            self.shutdown_request(request)
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            with self.clients_lock:
                self.clients.discard(request)
            self.slots.release()

    def server_close(self):
        with self.clients_lock:
            clients = list(self.clients)
        for client in clients:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        super().server_close()


class StreamProxy:
    def __init__(self):
        self.route = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_HEAD(self):
                self.relay(head=True)

            def do_GET(self):
                self.relay()

            def relay(self, head=False):
                route = owner.route
                if not route or self.path != route[0]:
                    self.send_error(404)
                    return
                headers = dict(route[2])
                for name in ('Range', 'If-Range'):
                    if self.headers.get(name):
                        headers[name] = self.headers[name]
                request = urllib.request.Request(route[1], headers=headers, method='HEAD' if head else 'GET')
                try:
                    response = urllib.request.build_opener(NoRedirect).open(request, timeout=20)
                except urllib.error.HTTPError as exc:
                    status = exc.code if exc.code in (401, 403, 404, 416) else 502
                    exc.close()
                    self.send_error(status)
                    return
                except (OSError, ValueError):
                    self.send_error(502)
                    return
                try:
                    with response:
                        self.send_response(response.status)
                        for name in ('Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges', 'ETag', 'Last-Modified'):
                            if response.headers.get(name):
                                self.send_header(name, response.headers[name])
                        self.end_headers()
                        if not head:
                            while chunk := response.read(64 * 1024):
                                self.wfile.write(chunk)
                except OSError:
                    pass  # Seeking/stopping closes the previous request.

        self.server = LimitedHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stream(self, url, headers):
        path = '/' + secrets.token_hex(24)
        self.route = (path, url, dict(headers))
        return f'http://127.0.0.1:{self.server.server_port}{path}'

    def close(self):
        self.route = None
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
