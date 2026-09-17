"""Store OmaGAWD's reconnect session and selected library in Secret Service."""
import json
import subprocess


class SessionStore:
    attributes = ['application', 'omaamp', 'profile', 'default']

    def run(self, action, payload=None):
        args = ['secret-tool', action]
        if action == 'store':
            args += ['--label=OmaGAWD Jellyfin sign-in']
        try:
            result = subprocess.run(args + self.attributes, input=payload, text=True,
                                    capture_output=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError('System keyring unavailable. Unlock your keyring to remember sign-in.') from exc
        if result.returncode and not (action in ('lookup', 'clear') and not result.stderr.strip()):
            raise RuntimeError('System keyring unavailable. Unlock your keyring to remember sign-in.')
        return result.stdout

    def load(self):
        raw = self.run('lookup')
        if not raw.strip():
            return None
        try:
            session = json.loads(raw)
            if not all(isinstance(session.get(k), str) and session[k] for k in ('url', 'username', 'token', 'user', 'device')):
                raise ValueError()
            return session
        except (ValueError, TypeError, AttributeError) as exc:
            raise RuntimeError('Saved sign-in is unreadable. Sign in again to replace it.') from exc

    def save(self, client, username, folder=""):
        self.run('store', json.dumps({'url': client.url, 'username': username,
                                     'token': client.token, 'user': client.user, 'device': client.device, 'folder': folder}))

    def clear(self):
        self.run('clear')
