"""Run with dbus-run-session -- /usr/bin/python3 -m unittest discover -s tests -p test_mpris.py."""
import time
import unittest
from test_backend import Player, FakeMpv, Jellyfin, song
try:
    from mpris import Mpris, Gio, GLib, ROOT, PLAYER, PATH
except ImportError:
    Mpris = None


@unittest.skipIf(Mpris is None, 'requires system Python with python-gobject')
class MediaTests(unittest.TestCase):
    def test_desktop_playback_commands_and_metadata(self):
        p = Player(lambda event: None, FakeMpv)
        p.client = Jellyfin('https://example.com')
        p.songs = [song(0), song(1)]
        p.handle({'cmd': 'add', 'ids': ['0', '1']})
        media = Mpris(p)
        try:
            bus = Gio.bus_get_sync(Gio.BusType.SESSION)
            deadline = time.monotonic() + 3
            while not media.registrations and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(media.registrations)
            def call(method):
                return bus.call_sync(ROOT + '.OmaGAWD', PATH, PLAYER, method, None, None,
                                     Gio.DBusCallFlags.NONE, 2000, None)
            call('PlayPause')
            self.assertFalse(p.paused)
            call('Pause'); call('Pause')
            self.assertTrue(p.paused)
            call('Play'); call('Play')
            self.assertFalse(p.paused)
            call('Next')
            self.assertEqual(p.index, 1)
            result = bus.call_sync(ROOT + '.OmaGAWD', PATH, 'org.freedesktop.DBus.Properties', 'Get',
                                  GLib.Variant('(ss)', (PLAYER, 'Metadata')), None,
                                  Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]
            self.assertEqual(result['xesam:title'], 'Song 1')
            call('Previous')
            self.assertEqual(p.index, 0)
            call('Stop')
            self.assertTrue(p.idle)
        finally:
            media.close()
            p.client = None
            p.close()
