"""Pre-demux music boundaries, including real FFmpeg/mpv adversarial inputs."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch

from local_library import LocalLibrary
from media_policy import FORMAT_WHITELIST, demux_options
from playback_store import validate
from test_playback_store import snapshot
from test_backend import FakeMpv, Jellyfin, Player
from radio_library import stream_url


class ImportBoundaryTests(unittest.TestCase):
    def test_selected_scripts_and_script_symlinks_are_rejected_atomically(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); music = root / 'music'; music.mkdir()
            local = LocalLibrary(root / 'local.json'); local.add([str(music)])
            original = local.path.read_bytes()
            script = root / 'foreign.avs'; script.write_text('BlankClip()')
            disguised = root / 'disguised.mp3'; disguised.symlink_to(script)
            audio = root / 'good.MP3'; audio.write_bytes(b'fixture')
            for value in (script, disguised):
                with self.subTest(path=value.name), patch('local_library.probe_output') as probe:
                    with self.assertRaises(ValueError): local.add([str(audio), str(value)])
                    probe.assert_not_called()
                    self.assertEqual(local.roots, [str(music)])
                    self.assertEqual(local.path.read_bytes(), original)

    def test_old_sources_and_folder_symlinks_do_not_probe_scripts(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); script = root / 'foreign.AVS'; script.write_text('BlankClip()')
            (root / 'disguised.flac').symlink_to(script)
            local = LocalLibrary(root / 'local.json'); local.roots = [str(root), str(script)]
            with patch('local_library.probe_output') as probe:
                self.assertEqual(local.scan(), ([], 0))
                probe.assert_not_called()

    def test_restored_queue_rejects_script_names(self):
        for name in ('/tmp/music.avs', '/tmp/music.vpy', '/tmp/music.m3u8'):
            with self.subTest(name=name), self.assertRaises(ValueError): validate(snapshot(name))
        self.assertEqual(validate(snapshot('/tmp/missing.MP3'))['queue'][0]['path'], '/tmp/missing.MP3')

    def test_play_checks_a_retargeted_audio_symlink_before_creating_engine(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); script = root / 'script.avs'; script.write_text('BlankClip()')
            path = root / 'audio.flac'; path.symlink_to(script)
            events = []; p = Player(events.append, FakeMpv)
            p.queue = [dict(id='local:one', key='one', source='local', path=str(path), duration=1)]
            try:
                p.play(0)
                self.assertIsNone(p.mpv)
                self.assertTrue(p.idle)
                self.assertTrue(any(e.get('type') == 'error' for e in events))
            finally: p.close()

    def test_picker_only_offers_supported_audio_and_validates_returned_selection(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); script = root / 'script.avs'; script.write_text('BlankClip()')
            local = LocalLibrary(root / 'local.json'); events = []
            p = Player(events.append, FakeMpv, local=local)
            try:
                with patch('backend.run_bounded', return_value=Mock(returncode=0, stdout=json.dumps([str(script)]).encode())) as picker:
                    p.local_command({'cmd': 'choose_files'}, 0)
                args = picker.call_args.args[0]
                self.assertEqual(args[1], '-B')
                self.assertTrue(args[2].endswith('file_picker.py'))
                self.assertNotIn('zenity', args)
                self.assertEqual(local.roots, [])
                self.assertTrue(any(e.get('type') == 'error' for e in events))
            finally: p.close()

    def test_remote_and_local_loads_keep_format_policy_and_reset_protocols(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'music.wav'; path.write_bytes(b'fixture')
            p = Player(lambda _: None, FakeMpv); p.client = Jellyfin('https://example.com')
            p.queue = [dict(id='remote', key='r', duration=1),
                       dict(id='local:one', key='l', source='local', path=str(path), duration=1)]
            try:
                for index, local in ((0, False), (1, True), (0, False)):
                    p.play(index)
                    opts = [c[2] for c in p.mpv.commands if c[:2] == ('set_property', 'options/demuxer-lavf-o')][-1]
                    self.assertEqual(opts, demux_options(local))
            finally: p.client = None; p.close()

    def test_radio_script_and_playlist_links_rejected(self):
        for suffix in ('.avs', '.vpy', '.ffconcat', '.m3u8', '.m3u', '.pls'):
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                stream_url('https://radio.example/music' + suffix)

    def test_directory_breadth_is_bounded_before_probing(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); local = LocalLibrary(root / 'local.json'); local.roots = [str(root)]
            for i in range(4): (root / ('ignored-' + str(i))).write_text('fixture')
            with patch('local_library.MAX_SCAN_ENTRIES', 2), patch('local_library.probe_output') as probe:
                with self.assertRaisesRegex(ValueError, 'entry safety limit'): local.scan()
                probe.assert_not_called()
            for i in range(4): (root / ('folder-' + str(i))).mkdir()
            with patch('local_library.MAX_SCAN_DIRECTORIES', 2), patch('local_library.probe_output') as probe:
                with self.assertRaisesRegex(ValueError, 'folder safety limit'): local.scan()
                probe.assert_not_called()

    def test_failed_scans_do_not_accumulate_partial_metadata_cache(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); local = LocalLibrary(root / 'local.json'); local.roots = [str(root)]
            (root / 'a.mp3').write_bytes(b'fixture')
            data = json.dumps({'streams': [{'codec_type': 'audio'}], 'format': {'duration': '1'}}).encode()
            with patch('local_library.probe_output', return_value=data): local.scan()
            previous = dict(local.cache)
            for i in range(4):
                (root / ('b' + str(i) + '.mp3')).write_bytes(b'fixture')
                with patch('local_library.probe_output', return_value=data), patch('local_library.MAX_LOCAL_BYTES', 400):
                    with self.assertRaises(ValueError): local.scan()
                self.assertEqual(local.cache, previous)


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe') and shutil.which('mpv'), 'requires native media tools')
class NativeMediaBoundaryTests(unittest.TestCase):
    def test_real_radio_decodes_audio_and_rejects_a_disguised_playlist(self):
        from backend import Mpv
        from radio_library import make_station
        with tempfile.TemporaryDirectory() as d:
            audio = Path(d) / 'tone.wav'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=1.5', str(audio)], check=True, capture_output=True, timeout=10)
            received = []; payload = audio.read_bytes()
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args): pass
                def do_GET(self):
                    received.append(self.path)
                    data = payload if self.path == '/audio' else b'ffconcat version 1.0\nfile secondary.wav\n'
                    self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers()
                    self.wfile.write(data)
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            events = []; p = Player(events.append, Mpv); p.visible = True; popen = subprocess.Popen
            try:
                for path, valid in (('/audio', True), ('/playlist', False)):
                    events.clear()
                    p.queue = [dict(make_station('Test Radio', f'http://127.0.0.1:{server.server_port}{path}'), key='test')]
                    with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: popen(args + ['--ao=null'], **kw)):
                        p.play(0)
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        p.handle({'cmd': 'meter'})
                        decoded = any(e.get('type') == 'meter' and max(e['levels']) > .1 for e in events)
                        done = decoded if valid else any(e.get('type') == 'error' for e in events)
                        if done: break
                        time.sleep(.02)
                    self.assertIn(path, received)
                    if valid: self.assertTrue(decoded, 'Real radio audio did not decode: ' + str(events[-3:]))
                    else: self.assertTrue(any(e.get('type') == 'error' for e in events), 'Radio playlist was not rejected')
                self.assertNotIn('/secondary.wav', received)
            finally: p.close(); server.shutdown(); server.server_close()

    def test_supported_audio_containers_still_probe(self):
        cases = [('wav', 'pcm_s16le', None), ('flac', 'flac', None), ('mp3', 'libmp3lame', None),
                 ('aac', 'aac', None), ('m4a', 'aac', None), ('m4b', 'aac', 'ipod'),
                 ('alac', 'alac', 'ipod'), ('aiff', 'pcm_s16be', None),
                 ('ogg', 'libvorbis', None), ('opus', 'libopus', None),
                 ('wma', 'wmav2', None), ('wv', 'wavpack', None)]
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for extension, codec, container in cases:
                with self.subTest(extension=extension):
                    path = root / ('tone.' + extension)
                    args = ['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=0.1', '-c:a', codec]
                    if container: args += ['-f', container]
                    subprocess.run(args + [str(path)], check=True, capture_output=True, timeout=10)
                    local = LocalLibrary(root / ('local-' + extension + '.json')); local.add([str(path)])
                    rows, skipped = local.scan()
                    self.assertEqual(skipped, 0); self.assertEqual(len(rows), 1)
                    self.assertGreater(rows[0]['duration'], 0)

    def test_disguised_concat_rejected_by_real_probe_and_real_player(self):
        from backend import Mpv
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); path = root / 'disguised.mp3'
            path.write_text("ffconcat version 1.0\nfile 'missing-audio.wav'\n")
            local = LocalLibrary(root / 'local.json'); local.add([str(path)])
            self.assertEqual(local.scan(), ([], 1))
            events = []; p = Player(events.append, Mpv)
            p.queue = [dict(id='local:one', key='one', source='local', path=str(path), duration=1)]
            popen = subprocess.Popen
            try:
                with patch('backend.subprocess.Popen', side_effect=lambda args, **kw: popen(args + ['--ao=null'], **kw)):
                    p.play(0)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and not any(e.get('type') == 'error' for e in events): time.sleep(.02)
                self.assertTrue(any(e.get('type') == 'error' for e in events))
                self.assertFalse(any(e.get('position', 0) > 0 for e in events))
            finally: p.close()

    @unittest.skipUnless(shutil.which('cc'), 'requires C compiler for dlopen instrumentation')
    def test_format_whitelist_stops_avisynth_before_dlopen(self):
        # Intercept the optional library import, never actually evaluate a script.
        # The unrestricted control must hit this tripwire for the check to count.
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); source = root / 'tripwire.c'; lib = root / 'tripwire.so'; mark = root / 'imported'
            source.write_text('''#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
void *dlopen(const char *name, int flags) {
    if (name && strstr(name, "avisynth")) {
        const char *path = getenv("OMA_TEST_IMPORT_MARKER");
        int fd = path ? open(path, O_CREAT|O_WRONLY, 0600) : -1;
        if (fd >= 0) { write(fd, "blocked", 7); close(fd); }
        return NULL;
    }
    return ((void *(*)(const char *, int))dlsym(RTLD_NEXT, "dlopen"))(name, flags);
}
''')
            subprocess.run(['cc', '-shared', '-fPIC', str(source), '-o', str(lib), '-ldl'], check=True, capture_output=True, timeout=10)
            script = root / 'foreign.avs'; script.write_text('BlankClip()')
            env = dict(os.environ, LD_PRELOAD=str(lib), OMA_TEST_IMPORT_MARKER=str(mark))
            command = ['ffprobe', '-v', 'error', '-f', 'avisynth', '-show_format', str(script)]
            control = subprocess.run(command, env=env, capture_output=True, timeout=10)
            if not mark.exists(): self.skipTest('Installed FFmpeg does not attempt dynamic AviSynth import')
            self.assertNotEqual(control.returncode, 0); mark.unlink()
            result = subprocess.run(command[:1] + ['-format_whitelist', FORMAT_WHITELIST] + command[1:], env=env, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'not on whitelist', result.stderr)
            self.assertFalse(mark.exists(), 'AviSynth was imported before whitelist rejection')
            automatic = ['ffprobe', '-v', 'error', '-format_whitelist', FORMAT_WHITELIST,
                         '-show_format', str(script)]
            result = subprocess.run(automatic, env=env, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'not on whitelist', result.stderr)
            self.assertFalse(mark.exists(), 'Automatic probing imported AviSynth')
            from backend import Mpv
            # Verify the installed mpv really passes the AVOption through too,
            # even when its FFmpeg format is explicitly forced to AviSynth.
            disguised = root / 'foreign.mp3'; disguised.write_text('BlankClip()')
            events = []; p = Player(events.append, Mpv)
            p.queue = [dict(id='local:one', key='one', source='local', path=str(disguised), duration=1)]
            popen = subprocess.Popen
            try:
                with patch.dict(os.environ, LD_PRELOAD=str(lib), OMA_TEST_IMPORT_MARKER=str(mark)), \
                     patch('backend.subprocess.Popen', side_effect=lambda args, **kw: popen(args + ['--ao=null'], **kw)):
                    p.engine().send('set_property', 'options/demuxer-lavf-format', 'avisynth')
                    p.play(0)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and not any(e.get('type') == 'error' for e in events): time.sleep(.02)
                self.assertTrue(any(e.get('type') == 'error' for e in events))
                self.assertFalse(mark.exists(), 'mpv imported AviSynth despite format whitelist')
            finally: p.close()
