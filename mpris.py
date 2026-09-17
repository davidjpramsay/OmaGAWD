"""Expose OmaGAWD to Omarchy's standard desktop media controls."""
import threading
from gi.repository import Gio, GLib

ROOT = 'org.mpris.MediaPlayer2'
PLAYER = ROOT + '.Player'
PATH = '/org/mpris/MediaPlayer2'
XML = '''<node>
<interface name="org.mpris.MediaPlayer2">
<method name="Raise"/><method name="Quit"/>
<property name="CanQuit" type="b" access="read"/>
<property name="CanRaise" type="b" access="read"/>
<property name="HasTrackList" type="b" access="read"/>
<property name="Identity" type="s" access="read"/>
<property name="DesktopEntry" type="s" access="read"/>
<property name="SupportedUriSchemes" type="as" access="read"/>
<property name="SupportedMimeTypes" type="as" access="read"/>
</interface>
<interface name="org.mpris.MediaPlayer2.Player">
<method name="Next"/><method name="Previous"/><method name="Pause"/>
<method name="PlayPause"/><method name="Stop"/><method name="Play"/>
<property name="PlaybackStatus" type="s" access="read"/>
<property name="Rate" type="d" access="readwrite"/>
<property name="Metadata" type="a{sv}" access="read"/>
<property name="Volume" type="d" access="readwrite"/>
<property name="Position" type="x" access="read"/>
<property name="MinimumRate" type="d" access="read"/>
<property name="MaximumRate" type="d" access="read"/>
<property name="CanGoNext" type="b" access="read"/>
<property name="CanGoPrevious" type="b" access="read"/>
<property name="CanPlay" type="b" access="read"/>
<property name="CanPause" type="b" access="read"/>
<property name="CanSeek" type="b" access="read"/>
<property name="CanControl" type="b" access="read"/>
</interface></node>'''


class Mpris:
    def __init__(self, player):
        self.player = player
        self.connection = None
        self.registrations = []
        self.last = {}
        self.loop = GLib.MainLoop()
        self.owner = Gio.bus_own_name(Gio.BusType.SESSION, ROOT + '.OmaGAWD',
                                     Gio.BusNameOwnerFlags.NONE, self.acquired, None, None)
        self.thread = threading.Thread(target=self.loop.run, daemon=True)
        self.thread.start()

    def acquired(self, connection, name):
        self.connection = connection
        for interface in Gio.DBusNodeInfo.new_for_xml(XML).interfaces:
            self.registrations.append(connection.register_object(
                PATH, interface, self.method, self.get_property, self.set_property))

    def properties(self, interface):
        V = GLib.Variant
        if interface == ROOT:
            return {'CanQuit': V('b', False), 'CanRaise': V('b', False),
                    'HasTrackList': V('b', False), 'Identity': V('s', 'OmaGAWD'),
                    'DesktopEntry': V('s', 'omaamp'), 'SupportedUriSchemes': V('as', []),
                    'SupportedMimeTypes': V('as', [])}
        p = self.player
        with p.lock:
            track = p.queue[p.index] if 0 <= p.index < len(p.queue) else None
            metadata = {}
            if track:
                metadata = {'mpris:trackid': V('o', PATH + '/track/' + track['key'].replace('-', '_')),
                            'xesam:title': V('s', track['title']),
                            'xesam:artist': V('as', [track['artist']]),
                            'xesam:album': V('s', track['album']),
                            'mpris:length': V('x', int(track['duration'] * 1000000))}
            return {'PlaybackStatus': V('s', 'Stopped' if p.idle else 'Paused' if p.paused else 'Playing'),
                    'Metadata': V('a{sv}', metadata), 'Volume': V('d', p.volume / 100),
                    'Position': V('x', int(p.position * 1000000)),
                    'Rate': V('d', 1.0), 'MinimumRate': V('d', 1.0), 'MaximumRate': V('d', 1.0),
                    'CanGoNext': V('b', bool(p.queue)), 'CanGoPrevious': V('b', bool(p.queue)),
                    'CanPlay': V('b', bool(p.queue)), 'CanPause': V('b', bool(p.queue)),
                    'CanSeek': V('b', False), 'CanControl': V('b', True)}

    def get_property(self, connection, sender, path, interface, name):
        return self.properties(interface).get(name)

    def set_property(self, connection, sender, path, interface, name, value):
        if name == 'Volume':
            self.player.handle({'cmd': 'volume', 'value': value.unpack() * 100})
            return True
        return name == 'Rate' and value.unpack() == 1.0

    def method(self, connection, sender, path, interface, name, parameters, invocation):
        try:
            p = self.player
            with p.lock:
                if interface == PLAYER:
                    command = {'Next': 'next', 'Previous': 'previous', 'PlayPause': 'pause', 'Stop': 'stop'}.get(name)
                    if name == 'Play' and (p.idle or p.paused): command = 'pause'
                    if name == 'Pause' and not p.idle and not p.paused: command = 'pause'
                    if command:
                        was_inactive = p.idle or p.paused
                        p.handle({'cmd': command})
                        if name in ('Next', 'Previous') and was_inactive and not p.idle and not p.paused:
                            p.handle({'cmd': 'pause'})
            invocation.return_value(None)
        except Exception:
            invocation.return_dbus_error(ROOT + '.Error.Failed', 'Playback command failed.')

    def update(self):
        GLib.idle_add(self.publish)

    def publish(self):
        props = self.properties(PLAYER)
        changed = {k: v for k, v in props.items() if k != 'Position' and self.last.get(k) != v}
        self.last = props
        if self.connection and changed:
            self.connection.emit_signal(None, PATH, 'org.freedesktop.DBus.Properties',
                                        'PropertiesChanged', GLib.Variant('(sa{sv}as)', (PLAYER, changed, [])))
        return False

    def close(self):
        Gio.bus_unown_name(self.owner)
        if self.connection:
            for registration in self.registrations:
                self.connection.unregister_object(registration)
        self.loop.quit()
        self.thread.join(timeout=2)
