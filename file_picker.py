"""Explicit desktop FileChooser portal; no toolkit chooser or backend override."""
import json
import sys
import uuid

from drop_receiver import paths_from_uris, MAX_BYTES, MAX_PATHS
from media_policy import EXTENSIONS

PORTAL = 'org.freedesktop.portal.Desktop'
DESKTOP = '/org/freedesktop/portal/desktop'
REQUEST = 'org.freedesktop.portal.Request'


def selected_paths(uris):
    if not isinstance(uris, list) or not 1 <= len(uris) <= MAX_PATHS:
        raise ValueError('Choose 1–1,000 local music files or folders.')
    if any(not isinstance(uri, str) or '\n' in uri or '\r' in uri for uri in uris):
        raise ValueError('The file picker returned invalid file links.')
    raw = '\n'.join(uris).encode('utf-8')
    if len(raw) > MAX_BYTES: raise ValueError('Choose a smaller selection of music files.')
    return paths_from_uris(raw)


class FilePicker:
    """One asynchronous portal request, cancellable when its owner closes."""
    def __init__(self, folder, completed, connection=None, timeout_ms=3600000):
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.completed, self.done = completed, False
        self.connection = connection or Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.token = 'omagawd_' + uuid.uuid4().hex
        sender = self.connection.get_unique_name()[1:].replace('.', '_')
        self.path = DESKTOP + '/request/' + sender + '/' + self.token
        self.subscription = self.subscribe(self.path)
        self.timer = GLib.timeout_add(timeout_ms, self.expired)
        options = {'handle_token': GLib.Variant('s', self.token), 'modal': GLib.Variant('b', True),
                   'multiple': GLib.Variant('b', not folder), 'directory': GLib.Variant('b', folder),
                   'accept_label': GLib.Variant('s', 'Add')}
        if not folder:
            patterns = [(0, '*' + variant) for ext in sorted(EXTENSIONS) for variant in (ext, ext.upper())]
            options['filters'] = GLib.Variant('a(sa(us))', [('Music', patterns)])
        self.connection.call(PORTAL, DESKTOP, 'org.freedesktop.portal.FileChooser', 'OpenFile',
                             GLib.Variant('(ssa{sv})', ('', 'OmaGAWD · Add folder' if folder else 'OmaGAWD · Add files', options)),
                             GLib.VariantType.new('(o)'), Gio.DBusCallFlags.NONE, 10000, None, self.opened)

    def subscribe(self, path):
        return self.connection.signal_subscribe(PORTAL, REQUEST, 'Response', path, None,
                                                self.Gio.DBusSignalFlags.NONE, self.response)

    def opened(self, connection, result, _=None):
        try:
            actual = connection.call_finish(result).unpack()[0]
            if self.done:
                self.close_request(actual)
            elif actual != self.path:
                self.connection.signal_unsubscribe(self.subscription)
                self.path = actual
                self.subscription = self.subscribe(actual)
        except self.GLib.Error:
            if not self.done: self.finish(None, 'Could not open the desktop file picker. Check your file-picker portal.')

    def response(self, connection, sender, path, interface, signal, parameters, _=None):
        if self.done: return
        try:
            status, results = parameters.unpack()
            if status == 1: self.finish(None, '')
            elif status != 0: self.finish(None, 'The desktop file picker could not complete the selection.')
            else: self.finish(selected_paths(results.get('uris')), '')
        except (ValueError, OSError, UnicodeError):
            self.finish(None, 'Choose supported local music files or folders.')

    def close_request(self, path):
        self.connection.call(PORTAL, path, REQUEST, 'Close', None, None,
                             self.Gio.DBusCallFlags.NONE, 1000, None, None)

    def finish(self, paths, error):
        if self.done: return
        self.done = True
        self.connection.signal_unsubscribe(self.subscription)
        if self.timer:
            self.GLib.source_remove(self.timer); self.timer = 0
        self.completed(paths, error)

    def cancel(self):
        if not self.done:
            self.close_request(self.path)
            self.finish(None, '')

    def expired(self):
        self.timer = 0
        self.close_request(self.path)
        self.finish(None, 'The file picker timed out. Try again.')
        return self.GLib.SOURCE_REMOVE


def main(folder=False):
    from gi.repository import GLib
    loop = GLib.MainLoop(); result = {'code': 1}
    def completed(paths, error):
        if error:
            print(error, file=sys.stderr); result['code'] = 2
        elif paths is not None:
            print(json.dumps(paths), flush=True); result['code'] = 0
        loop.quit()
    picker = FilePicker(folder, completed)
    try: loop.run()
    finally: picker.cancel()
    return result['code']


if __name__ == '__main__':
    try: sys.exit(main('--folder' in sys.argv[1:]))
    except Exception:
        print('Could not connect to the desktop file-picker portal.', file=sys.stderr)
        sys.exit(2)
