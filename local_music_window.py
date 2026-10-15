"""Isolated native source manager with bounded, single-flight backend IPC.

Files and folders are chosen through the configured desktop FileChooser portal.
Only the backend commits source changes and acknowledges the displayed list.
"""
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import threading
import time

MAX_ACTION = 65536
MAX_STATE = 2 * 1024 * 1024
MAX_ACTIONS = 1000


def action_from_json(raw):
    if len(raw) > MAX_ACTION: raise ValueError('Local Music request is too large.')
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get('cmd') not in ('local_add', 'local_remove'):
        raise ValueError('Invalid Local Music request.')
    paths = data.get('paths')
    if not isinstance(paths, list) or not 1 <= len(paths) <= 1000:
        raise ValueError('Choose 1–1,000 local paths.')
    if any(not isinstance(p, str) or not 0 < len(p) <= 4096 or '\0' in p or not Path(p).is_absolute() for p in paths):
        raise ValueError('Invalid local path.')
    return {'cmd': data['cmd'], 'paths': paths}


class LocalMusicWindow:
    def __init__(self, action, closed):
        self.action, self.closed = action, closed
        self.stop = threading.Event(); self.wake = threading.Event()
        self.lock = threading.Lock(); self.close_lock = threading.Lock(); self.closed_process = False
        self.pending = None; self.inflight = False; self.proc = None

    def start(self, paths, theme):
        args = ['/usr/bin/python3', '-B', str(Path(__file__).with_name('process_guard.py')), str(os.getpid()),
                '--memory-bytes', str(1024 * 1024 * 1024), '/usr/bin/python3', '-B', str(Path(__file__))]
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
        os.set_blocking(self.proc.stdin.fileno(), False)
        self.update(paths, theme=theme)
        self.writer = threading.Thread(target=self.write, daemon=True)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.writer.start(); self.reader.start()

    def update(self, paths, message='', theme=None):
        data = {'paths': paths, 'message': message}
        if theme is not None: data['theme'] = theme
        raw = (json.dumps(data, ensure_ascii=False) + '\n').encode()
        if len(raw) > MAX_STATE: raise ValueError('Local Music source list is too large.')
        with self.lock:
            self.pending = raw; self.inflight = False
        self.wake.set()

    def present(self):
        with self.lock:
            data = json.loads(self.pending) if self.pending else {}
            data['present'] = True
            self.pending = (json.dumps(data, ensure_ascii=False) + '\n').encode()
        self.wake.set()

    def write(self):
        try:
            while not self.stop.is_set():
                self.wake.wait(.2); self.wake.clear()
                with self.lock: raw, self.pending = self.pending, None
                if raw is None: continue
                offset = 0; deadline = time.monotonic() + 2
                while offset < len(raw) and not self.stop.is_set():
                    if time.monotonic() >= deadline: raise ValueError('Local Music stopped responding.')
                    if select.select([], [self.proc.stdin], [], .1)[1]:
                        try: offset += os.write(self.proc.stdin.fileno(), raw[offset:offset + 16384])
                        except BlockingIOError: pass
        except (OSError, ValueError): self.close()

    def read(self):
        pending = bytearray(); count = 0; deadline = time.monotonic() + 3600
        try:
            while not self.stop.is_set() and time.monotonic() < deadline:
                if not select.select([self.proc.stdout], [], [], .2)[0]: continue
                block = os.read(self.proc.stdout.fileno(), 16384)
                if not block: break
                pending.extend(block)
                while b'\n' in pending:
                    line, _, rest = pending.partition(b'\n'); pending = bytearray(rest)
                    count += 1
                    if count > MAX_ACTIONS: raise ValueError('Too many Local Music requests.')
                    action = action_from_json(line)
                    with self.lock:
                        if self.inflight: raise ValueError('A source change is already running.')
                        self.inflight = True
                    self.action(action)
                if len(pending) > MAX_ACTION: raise ValueError('Local Music request is too large.')
        except (OSError, ValueError, RecursionError): pass
        finally:
            self.close(); self.closed()

    def close(self):
        with self.close_lock:
            if self.closed_process: return
            self.closed_process = True
            self.stop.set(); self.wake.set()
            if self.proc:
                try: os.killpg(self.proc.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: self.proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    try: os.killpg(self.proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    self.proc.wait()
                self.proc.stdin.close(); self.proc.stdout.close()


def theme_css(theme):
    def color(name, fallback):
        value = theme.get(name)
        return value if isinstance(value, str) and re.fullmatch(r'#[0-9a-fA-F]{6}', value) else fallback
    family = theme.get('font', 'monospace')
    if not isinstance(family, str) or not re.fullmatch(r'[A-Za-z0-9 ._-]{1,80}', family): family = 'monospace'
    size = theme.get('size', 12)
    if type(size) not in (int, float) or not 8 <= size <= 24: size = 12
    bg, fg, accent = color('background', '#282828'), color('foreground', '#d4be98'), color('accent', '#83a598')
    return f'''
    .omagawd-window, .omagawd-window list, .omagawd-window row {{ background: {bg}; color: {fg}; }}
    .omagawd-window * {{ font-family: "{family}"; font-size: {size}px; }}
    .omagawd-window button {{ background: {bg}; color: {fg}; border: 1px solid alpha({fg}, .4); border-radius: 0; box-shadow: none; padding: 6px 10px; }}
    .omagawd-window button:hover {{ background: alpha({fg}, .12); border-color: {accent}; }}
    .omagawd-window button:focus {{ outline: 1px solid {accent}; }}
    .omagawd-window .heading {{ color: {accent}; font-weight: bold; letter-spacing: 1px; }}
    .omagawd-window .detail {{ opacity: .65; }}
    .omagawd-window row {{ border-bottom: 1px solid alpha({fg}, .2); padding: 10px 0; }}
    '''


def main(smoke=False):
    raw = bytearray()
    while b'\n' not in raw:
        block = os.read(sys.stdin.fileno(), 16384)
        if not block: return 2
        raw.extend(block)
        if len(raw) > MAX_STATE: return 2
    line, _, remaining = raw.partition(b'\n')
    initial = json.loads(line)
    if not isinstance(initial, dict): return 2
    import gi
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gtk, GLib, Pango
    from file_picker import FilePicker
    app = Gtk.Application(application_id=None)
    state = {'busy': False, 'picker': None, 'pending': bytearray(remaining)}

    def activate(application):
        window = Gtk.ApplicationWindow(application=application, title='OmaGAWD · Local Music')
        window.add_css_class('omagawd-window'); window.set_default_size(520, 380)
        window.set_resizable(False)
        provider = Gtk.CssProvider(); provider.load_from_string(theme_css(initial.get('theme', {})))
        Gtk.StyleContext.add_provider_for_display(window.get_display(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        for prop in ('margin_top', 'margin_bottom', 'margin_start', 'margin_end'): getattr(box, 'set_' + prop)(18)
        header = Gtk.Box(spacing=10)
        heading = Gtk.Label(label='OMAGAWD / LOCAL MUSIC', xalign=0); heading.add_css_class('heading'); heading.set_hexpand(True)
        header.append(heading); box.append(header)
        controls = Gtk.Box(spacing=8); box.append(controls)
        message = Gtk.Label(xalign=0); message.set_wrap(True); message.add_css_class('detail')
        listing = Gtk.ListBox(); listing.set_selection_mode(Gtk.SelectionMode.NONE)
        empty = Gtk.Label(label='No local music yet.'); empty.add_css_class('detail')
        scroller = Gtk.ScrolledWindow(); scroller.set_vexpand(True); scroller.set_child(listing); box.append(scroller)
        box.append(message)
        footer = Gtk.Box(spacing=8)
        note = Gtk.Label(label='Removing a source keeps your files.', xalign=0); note.set_hexpand(True); note.add_css_class('detail'); footer.append(note)
        close = Gtk.Button(label='Close'); close.connect('clicked', lambda _: window.close()); footer.append(close); box.append(footer)
        window.set_child(box)

        def busy(value):
            state['busy'] = value; controls.set_sensitive(not value); listing.set_sensitive(not value)

        def action(command, paths):
            if state['busy']: return
            raw = (json.dumps({'cmd': command, 'paths': paths}, ensure_ascii=False) + '\n').encode()
            try:
                action_from_json(raw)
                busy(True); message.set_text('Updating Local Music…')
                sys.stdout.buffer.write(raw); sys.stdout.buffer.flush()
            except (OSError, ValueError):
                busy(False); message.set_text('Could not add this selection. Choose fewer supported music files.')

        def update(data):
            if not isinstance(data, dict): application.quit(); return
            if data.get('present'):
                window.present()
                if 'paths' not in data: return
            paths = data.get('paths', [])
            if not isinstance(paths, list) or len(paths) > 1000 or any(not isinstance(p, str) or len(p) > 4096 for p in paths):
                application.quit(); return
            child = listing.get_first_child()
            while child:
                following = child.get_next_sibling(); listing.remove(child); child = following
            if not paths: listing.append(empty)
            for path in paths:
                row = Gtk.Box(spacing=12); info = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4); info.set_hexpand(True)
                title = Gtk.Label(label=Path(path).name or path, xalign=0); title.set_ellipsize(Pango.EllipsizeMode.END)
                detail = Gtk.Label(label=path, xalign=0); detail.set_ellipsize(Pango.EllipsizeMode.MIDDLE); detail.add_css_class('detail')
                info.append(title); info.append(detail); row.append(info)
                remove = Gtk.Button(label='Remove'); remove.connect('clicked', lambda _, p=path: action('local_remove', [p])); row.append(remove); listing.append(row)
            text = data.get('message')
            message.set_text(text[:512] if isinstance(text, str) and text else 'Choose + Files or + Folder to add music.')
            busy(False)

        def choose(folder):
            if state['busy']: return
            busy(True)
            def completed(paths, error):
                state['picker'] = None; busy(False)
                if error: message.set_text(error)
                elif paths: action('local_add', paths)
            try: state['picker'] = FilePicker(folder, completed)
            except Exception:
                busy(False); message.set_text('Could not open your desktop file picker.')
        for label, folder in (('+ Files', False), ('+ Folder', True)):
            button = Gtk.Button(label=label); button.connect('clicked', lambda _, f=folder: choose(f)); controls.append(button)
        os.set_blocking(sys.stdin.fileno(), False)
        def consume():
            while b'\n' in state['pending']:
                line, _, rest = state['pending'].partition(b'\n'); state['pending'] = bytearray(rest)
                if len(line) > MAX_STATE: raise ValueError('Oversized source list')
                update(json.loads(line))
            if len(state['pending']) > MAX_STATE: raise ValueError('Oversized source list')
        def read_state(fd, condition):
            try:
                block = os.read(fd, 16384)
                if not block: application.quit(); return GLib.SOURCE_REMOVE
                state['pending'].extend(block)
                consume()
            except BlockingIOError: return GLib.SOURCE_CONTINUE
            except (OSError, ValueError, RecursionError): application.quit(); return GLib.SOURCE_REMOVE
            return GLib.SOURCE_CONTINUE
        GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, read_state)
        def closing(_):
            if state['picker']: state['picker'].cancel()
            return False
        window.connect('close-request', closing)
        update(initial); consume(); window.present()
        if smoke: GLib.timeout_add(500, lambda: (application.quit(), GLib.SOURCE_REMOVE)[1])
    app.connect('activate', activate)
    app.run([])
    if state['picker']: state['picker'].cancel()
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except Exception: sys.exit(2)
