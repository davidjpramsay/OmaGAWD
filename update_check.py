"""Public release checks and an explicit handoff to Omarchy's native updater."""
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

RELEASES = 'https://api.github.com/repos/davidjpramsay/OmaGAWD/releases?per_page=100'
MAX_BYTES = 1024 * 1024
MAX_NOTES = 16000
VERSION = re.compile(r'(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})')
ORIGINS = {'https://github.com/davidjpramsay/OmaGAWD.git', 'https://github.com/davidjpramsay/OmaGAWD',
           'git@github.com:davidjpramsay/OmaGAWD.git', 'ssh://git@github.com/davidjpramsay/OmaGAWD.git'}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def version(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError('Invalid version')
    return tuple(map(int, value.split('.')))


def managed_install(directory, home=None):
    """A development preview, copied install, or fork must never update another copy."""
    directory = Path(directory).resolve()
    expected = Path(home or Path.home()) / '.config/omarchy/plugins/david.omaamp'
    if expected.is_symlink() or directory != expected.resolve() or not (directory / '.git').is_dir():
        return False
    try:
        result = subprocess.run(['/usr/bin/git', '-C', str(directory), 'config', '--get', 'remote.origin.url'],
                                capture_output=True, timeout=3, check=True)
        return len(result.stdout) < 1024 and result.stdout.decode().strip() in ORIGINS
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def release_info(rows, current):
    current_version = version(current)
    if not isinstance(rows, list) or len(rows) > 100:
        raise ValueError('Invalid release list')
    releases = []
    for row in rows:
        if not isinstance(row, dict) or row.get('draft') or row.get('prerelease'):
            continue
        tag = row.get('tag_name')
        if not isinstance(tag, str) or not tag.startswith('omarchy-v'):
            continue
        try:
            candidate = version(tag.removeprefix('omarchy-v'))
        except ValueError:
            continue
        releases.append((candidate, tag, row))
    if not releases:
        raise ValueError('No Omarchy releases')
    candidate, tag, row = max(releases, key=lambda entry: entry[0])
    notes = row.get('body')
    # Remote text is displayed as plain text, never a command or QML/rich text.
    notes = ''.join(c for c in notes[:MAX_NOTES] if c in '\n\t' or 32 <= ord(c) != 127) if isinstance(notes, str) else ''
    notes = re.sub(r'```[\s\S]*?```', '', notes)
    notes = re.sub(r'<[^>]*>', '', notes)
    notes = re.sub(r'!\[[^\]]*\]\([^)]*\)', '', notes)
    notes = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', notes)
    notes = re.sub(r'(?m)^#{1,6}\s+', '', notes).replace('**', '').replace('`', '')
    notes = re.sub(r'\n{3,}', '\n\n', notes).strip()[:4000]
    return {'current': current, 'latest': tag.removeprefix('omarchy-v'), 'available': candidate > current_version,
            'notes': notes, 'url': 'https://github.com/davidjpramsay/OmaGAWD/releases/tag/' + tag}


def check(directory, opener=None, clock=time.monotonic):
    with (Path(directory) / 'manifest.json').open() as stream:
        current = json.load(stream)['version']
    version(current)
    opener = opener or urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(RELEASES, headers={'Accept': 'application/vnd.github+json',
                                    'Accept-Encoding': 'identity', 'User-Agent': 'OmaGAWD/' + current})
    with opener.open(request, timeout=5) as response:
        if response.headers.get('Content-Encoding', 'identity').lower() != 'identity':
            raise ValueError('Encoded release response')
        deadline, raw = clock() + 10, bytearray()
        while True:
            if clock() >= deadline:
                raise ValueError('Release check timed out')
            block = response.read(min(16384, MAX_BYTES + 1 - len(raw)))
            if clock() >= deadline:
                raise ValueError('Release check timed out')
            if not block:
                break
            raw.extend(block)
            if len(raw) > MAX_BYTES:
                raise ValueError('Release response too large')
    result = release_info(json.loads(raw), current)
    result['managed'] = managed_install(directory)
    return result


def launch(directory):
    if not managed_install(directory):
        raise RuntimeError('Use a Git-managed OmaGAWD installation to update here.')
    if not shutil.which('omarchy-launch-terminal'):
        raise RuntimeError('Could not open Omarchy’s terminal. Run omarchy plugin update david.omaamp.')
    process = subprocess.Popen(['omarchy-launch-terminal', '/usr/bin/python3', str(Path(__file__).resolve()), '--apply'],
                               start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if process.wait(timeout=1) != 0:
            raise RuntimeError('Could not open the updater. Run omarchy plugin update david.omaamp.')
    except subprocess.TimeoutExpired:
        pass  # Some terminal launchers stay alive until their window closes.


def apply(directory):
    if not managed_install(directory):
        raise RuntimeError('This installation cannot be updated here.')
    def head():
        return subprocess.check_output(['/usr/bin/git', '-C', str(directory), 'rev-parse', 'HEAD'], timeout=3)
    previous = head()
    print('OmaGAWD is paused. Review the changes below and confirm the update.', flush=True)
    subprocess.run(['omarchy', 'plugin', 'update', 'david.omaamp'], check=True)
    if head() != previous:
        subprocess.run(['omarchy', 'restart', 'shell'], check=True)
        subprocess.run(['omarchy-shell', 'shell', 'summon', 'david.omaamp', '{}'], check=True)
        print('OmaGAWD updated. Playback remains paused.', flush=True)
    else:
        print('No update applied. You can resume playback in OmaGAWD.', flush=True)


def main():
    directory = Path(__file__).resolve().parent
    mode = sys.argv[1] if len(sys.argv) == 2 else '--check'
    if mode == '--apply':
        try:
            apply(directory)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            print('The update did not finish. Review the terminal output above; your music files are unchanged.')
        finally:
            if sys.stdin.isatty():
                try:
                    input('Press Return to close…')
                except EOFError:
                    pass
        return
    try:
        if mode == '--launch':
            launch(directory)
            result = {'launched': True}
        elif mode == '--check':
            result = check(directory)
        else:
            raise ValueError('Invalid action')
        print(json.dumps(result, separators=(',', ':')), flush=True)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, RecursionError, subprocess.SubprocessError) as exc:
        message = str(exc) if isinstance(exc, RuntimeError) else 'Could not check for updates. Try again later.'
        print(json.dumps({'error': message}), flush=True)


if __name__ == '__main__':
    main()
