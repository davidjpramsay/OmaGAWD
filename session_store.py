"""Store OmaGAWD's reconnect session and selected library in Secret Service."""
import json
import subprocess
from bounded_process import run_bounded


class SessionStore:
    attributes = ['application', 'omaamp', 'profile', 'default']

    def run(self, action, payload=None):
        args = ['secret-tool', action]
        if action == 'store':
            args += ['--label=OmaGAWD Jellyfin sign-in']
        try:
            result = run_bounded(args + self.attributes, payload=payload.encode() if payload is not None else None,
                                 limit=65536, timeout=20)
            output = result.stdout.decode('utf-8')
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            raise RuntimeError('System keyring unavailable. Unlock your keyring to remember sign-in.') from exc
        if result.returncode and not (action in ('lookup', 'clear') and not result.stderr.strip()):
            raise RuntimeError('System keyring unavailable. Unlock your keyring to remember sign-in.')
        return output

    def load(self):
        raw = self.run('lookup')
        if not raw.strip():
            return None
        try:
            session = json.loads(raw)
            limits = {'url': 4096, 'username': 256, 'token': 4096, 'user': 512, 'device': 512}
            if not all(isinstance(session.get(k), str) and 0 < len(session[k]) <= n for k,n in limits.items()):
                raise ValueError()
            return session
        except (ValueError, TypeError, AttributeError, RecursionError) as exc:
            raise RuntimeError('Saved sign-in is unreadable. Sign in again to replace it.') from exc

    def save(self, client, username, folder=""):
        self.run('store', json.dumps({'url': client.url, 'username': username,
                                     'token': client.token, 'user': client.user, 'device': client.device, 'folder': folder}))

    def clear(self):
        self.run('clear')
