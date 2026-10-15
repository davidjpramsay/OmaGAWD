"""Native GTK drop window; URI data never enters Quickshell's shared process.

Only explicit drops are read, asynchronously, with a 64 KiB / 2-second budget.
The backend additionally guards this process's memory, lifetime and stdout.
"""
import json
import sys
import urllib.parse
from pathlib import Path
from media_policy import local_file

MAX_BYTES = 65536
MAX_PATHS = 1000


def paths_from_uris(raw):
    if len(raw) > MAX_BYTES: raise ValueError('Drop at most 64 KiB of file links.')
    lines = [line for line in raw.decode('utf-8').splitlines() if line and not line.startswith('#')]
    if not 1 <= len(lines) <= MAX_PATHS: raise ValueError('Drop 1–1,000 local files or folders.')
    paths = []
    for line in lines:
        url = urllib.parse.urlsplit(line)
        if url.scheme != 'file' or url.netloc not in ('', 'localhost') or url.query or url.fragment:
            raise ValueError('Drop local music files or folders, not web links.')
        path = urllib.parse.unquote(url.path, encoding='utf-8', errors='strict')
        if not path or len(path) > 4096 or '\0' in path or not Path(path).is_absolute(): raise ValueError('Invalid local path.')
        chosen = Path(path)
        resolved = chosen.resolve(strict=True)
        if not resolved.is_dir(): resolved = local_file(path)
        if str(resolved) not in paths: paths.append(str(resolved))
    output = json.dumps(paths).encode()
    if len(output) > MAX_BYTES: raise ValueError('Too many file links. Drop a smaller selection.')
    return paths


READ_TIMEOUT_MS = 2000


def read_drop(drop, success, error):
    import gi
    gi.require_version('Gdk', '4.0')
    from gi.repository import Gdk, Gio, GLib
    cancellable = Gio.Cancellable(); pending = bytearray()
    transfer = {'closed': False, 'stream': None}
    def failed(text):
        if transfer['closed']: return
        transfer['closed'] = True; cancellable.cancel()
        if GLib.MainContext.default().find_source_by_id(timer): GLib.source_remove(timer)
        if transfer['stream'] is not None: transfer['stream'].close_async(GLib.PRIORITY_DEFAULT, None, None)
        drop.finish(Gdk.DragAction(0)); error(text)
    def expired():
        failed('The drop took too long. Try again.'); return GLib.SOURCE_REMOVE
    timer = GLib.timeout_add(READ_TIMEOUT_MS, expired)
    def finish_read(stream, result, _=None):
        if transfer['closed']: return
        try:
            block = stream.read_bytes_finish(result).get_data(); pending.extend(block)
            if len(pending) > MAX_BYTES: raise ValueError('Oversized drop')
            if block:
                stream.read_bytes_async(min(16384, MAX_BYTES + 1 - len(pending)), GLib.PRIORITY_DEFAULT, cancellable, finish_read)
                return
            paths = paths_from_uris(bytes(pending))
            stream.close_async(GLib.PRIORITY_DEFAULT, None, None)
            GLib.source_remove(timer); transfer['closed'] = True
            drop.finish(Gdk.DragAction.COPY); success(paths)
        except (OSError, RuntimeError, ValueError, GLib.Error):
            failed('Drop supported local music files or folders (64 KiB of links maximum).')
    def opened(source, result, _=None):
        if transfer['closed']: return
        try:
            stream, mime = drop.read_finish(result)
            if mime != 'text/uri-list' or stream is None: raise ValueError('Unsupported drop')
            transfer['stream'] = stream
            stream.read_bytes_async(16384, GLib.PRIORITY_DEFAULT, cancellable, finish_read)
        except (ValueError, GLib.Error): failed('Could not read the drop. Try again.')
    try: drop.read_async(['text/uri-list'], GLib.PRIORITY_DEFAULT, cancellable, opened)
    except GLib.Error: failed('Could not read the drop. Try again.')


def main(smoke=False):
    import gi
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gtk, Gdk, Gio, GLib
    app = Gtk.Application(application_id=None, flags=Gio.ApplicationFlags.NON_UNIQUE)
    state = {'code': 1, 'busy': False}
    def activate(application):
        window = Gtk.ApplicationWindow(application=application, title='OmaGAWD · Drop music')
        window.set_modal(True)
        window.set_default_size(400, 180)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        for prop in ('margin_top', 'margin_bottom', 'margin_start', 'margin_end'): getattr(box, 'set_' + prop)(24)
        title = Gtk.Label(label='Drop music files or folders here')
        title.add_css_class('title-3'); box.append(title)
        message = Gtk.Label(label='Adds music to Local Music; your current queue keeps playing.')
        message.set_wrap(True); box.append(message)
        cancel = Gtk.Button(label='Cancel'); cancel.connect('clicked', lambda _: application.quit()); box.append(cancel)
        window.set_child(box)
        target = Gtk.DropTargetAsync.new(Gdk.ContentFormats.new(['text/uri-list']), Gdk.DragAction.COPY)
        def dropped(controller, drop, x, y):
            if state['busy']: return False
            state['busy'] = True; message.set_text('Reading dropped files…')
            def success(paths):
                print(json.dumps(paths), flush=True); state['code'] = 0; application.quit()
            def error(text):
                state['busy'] = False; message.set_text(text)
            read_drop(drop, success, error)
            return True
        target.connect('drop', dropped)
        window.add_controller(target); window.present()
        if smoke: GLib.timeout_add(500, lambda: (application.quit(), GLib.SOURCE_REMOVE)[1])
    app.connect('activate', activate); app.run([])
    return state['code']


if __name__ == '__main__': sys.exit(main())
