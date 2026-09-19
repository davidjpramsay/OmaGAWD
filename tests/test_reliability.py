import socket
import subprocess
import tempfile
import time
import unittest
import wave
from pathlib import Path
from unittest.mock import patch
from test_backend import Player, FakeMpv, song
from local_library import LocalLibrary
from mpris import Mpris, PLAYER
from stream_proxy import StreamProxy, LimitedHTTPServer


def wait_for(predicate):
    deadline = time.monotonic() + 3
    while not predicate() and time.monotonic() < deadline:
        time.sleep(.01)
    return predicate()


class ReliabilityTests(unittest.TestCase):
    def test_failed_import_is_atomic(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d); good=folder/'music'; good.mkdir()
            local=LocalLibrary(folder/'local.json')
            local.save(); before=local.path.read_bytes()
            with self.assertRaises(ValueError): local.add([str(good),str(folder/'missing')])
            self.assertEqual(local.roots,[])
            self.assertFalse(local.prefer_local)
            self.assertEqual(local.path.read_bytes(),before)
            with patch.object(local,'save',side_effect=OSError('Disk full')):
                with self.assertRaises(OSError): local.add([str(good)])
            self.assertEqual(local.roots,[])
            self.assertFalse(local.prefer_local)
            local.add([str(good),str(good)])
            self.assertEqual(LocalLibrary(local.path).roots,[str(good)])

    def test_extreme_mpris_duration_and_position(self):
        player=Player(lambda e:None,FakeMpv)
        media=object.__new__(Mpris); media.player=player
        player.queue=[dict(song(1),key='test')]; player.index=0
        try:
            for value in (1e300,10**400,float('nan'),float('inf'),-5,None,'bad',1.25):
                player.queue[0]['duration']=value; player.position=value
                props=media.properties(PLAYER)
                duration=props['Metadata'].unpack()['mpris:length']
                self.assertGreaterEqual(duration,0)
                self.assertLessEqual(duration,2**63-1)
                self.assertEqual(props['Position'].unpack(),duration)
                if value==1.25:self.assertEqual(duration,1250000)
        finally:player.close()

    def test_idle_relay_connections_are_limited_and_expire(self):
        clients=[]
        with patch.object(LimitedHTTPServer,'max_connections',2), patch.object(LimitedHTTPServer,'client_timeout',.3):
            proxy=StreamProxy()
            try:
                for _ in range(2): clients.append(socket.create_connection(proxy.server.server_address))
                self.assertTrue(wait_for(lambda:len(proxy.server.clients)==2))
                extra=socket.create_connection(proxy.server.server_address); clients.append(extra); extra.settimeout(1)
                self.assertEqual(extra.recv(1),b'')
                self.assertLessEqual(len(proxy.server.clients),2)
                self.assertTrue(wait_for(lambda:not proxy.server.clients))
                fresh=socket.create_connection(proxy.server.server_address); clients.append(fresh)
                fresh.sendall(b'GET /unknown HTTP/1.0\r\n\r\n'); fresh.settimeout(1)
                self.assertIn(b'404',fresh.recv(1024))
            finally:
                for client in clients:client.close()
                proxy.close()

    def test_stale_engine_event_cannot_stop_replacement(self):
        engines=[]
        class Engine(FakeMpv):
            def __init__(self,callback):
                super().__init__(callback); self.callback=callback;engines.append(self)
        player=Player(lambda e:None,Engine)
        try:
            player.engine(); old=engines[0]
            old.callback({'event':'engine-exited'})
            self.assertIsNone(player.mpv)
            current=player.engine(); player.idle=False
            old.callback({'event':'engine-exited'})
            self.assertIs(player.mpv,current)
            self.assertFalse(player.idle)
        finally:player.close()

    def test_real_mpv_death_and_replay(self):
        with tempfile.TemporaryDirectory() as d:
            audio=Path(d)/'music.wav'
            with wave.open(str(audio),'wb') as wav:
                wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(8000);wav.writeframes(b'\0\0'*8000*10)
            player=Player(lambda e:None)
            player.queue=[dict(song(1),source='local',path=str(audio),key='test')]
            real=subprocess.Popen
            try:
                with patch('backend.subprocess.Popen',side_effect=lambda args,**kw:real(args+['--ao=null'],**kw)):
                    player.handle({'cmd':'play','index':0})
                    self.assertTrue(wait_for(lambda:player.position>.05))
                    old=player.mpv
                    old.proc.kill();old.proc.wait()
                    self.assertTrue(wait_for(lambda:player.mpv is None and player.idle and player.paused))
                    player.handle({'cmd':'pause'})
                    self.assertTrue(wait_for(lambda:player.position>.05 and not player.idle))
                    self.assertIsNot(player.mpv,old)
                    self.assertEqual(len(player.queue),1)
            finally:player.close()
