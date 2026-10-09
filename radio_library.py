"""Cliamp's catalog and validated custom stations with stable URL-based IDs.

Catalog: https://github.com/bjarneo/cliamp/blob/main/site/index.html
"""
import hashlib
import ipaddress
import urllib.parse

STATIONS = (
    ('omarchy', 'Omarchy', 'Community'),
    ('lofi', 'Lofi', 'Lofi / chillhop'),
    ('synthwave', 'Synthwave', 'Retrowave'),
    ('edm', 'EDM', 'Electronic'),
    ('chiptune', 'Chiptunes', '8-bit'),
    ('amiga', 'Amiga', 'Mod / tracker'),
    ('ncs', 'NCS', 'NoCopyrightSounds'),
    ('ncs-house', 'NCS House', 'House'),
    ('ncs-dubstep', 'NCS Dubstep', 'Dubstep'),
    ('ncs-dnb', 'NCS Drum & Bass', 'Drum & bass'),
    ('ncs-trap', 'NCS Trap', 'Trap'),
    ('ncs-phonk', 'NCS Phonk', 'Phonk'),
    ('ncs-pop', 'NCS Pop', 'Pop'),
    ('ncs-chill', 'NCS Chill', 'Chill'),
)


_CATALOG = { 'radio:' + slug: dict(id='radio:' + slug, source='radio', title=name,
             artist=genre, album='Cliamp Radio', albumId='radio', duration=0)
             for slug, name, genre in STATIONS }


def songs():
    return [dict(row) for row in _CATALOG.values()]


def station(track_id):
    row = _CATALOG.get(track_id)
    return dict(row) if row is not None else None


def stream(track_id):
    if isinstance(track_id, dict):
        row = clean_station(track_id)
        if "radioUrl" in row: return row["radioUrl"]
        track_id = row["id"]
    row = station(track_id)
    if row is None:
        raise ValueError('Unknown radio station.')
    return 'https://radio.cliamp.stream/' + row['id'].split(':', 1)[1] + '/stream'


def remote(track):
    """Only Jellyfin tracks require a saved account identity."""
    return track.get('source') not in ('local', 'radio')


def text(value, limit=160):
    if not isinstance(value, str): raise ValueError('Enter a station name and a stream link.')
    return ''.join(c for c in value[:limit] if c.isprintable()).strip()


def stream_url(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 4096 or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError('Enter a direct http(s) audio stream link.')
    try:
        url = urllib.parse.urlsplit(value)
        _ = url.port  # Validate malformed or out-of-range ports.
    except ValueError:
        raise ValueError('Enter a valid http(s) audio stream link.') from None
    if url.scheme not in ('http', 'https') or not url.hostname or url.username is not None or url.password is not None or url.fragment:
        raise ValueError('Use an http(s) stream link without a username, password or fragment.')
    if '%' in url.hostname or '\\' in value: raise ValueError('Enter a valid http(s) audio stream link.')
    secret_keys = {'token', 'access_token', 'api_key', 'apikey', 'password', 'auth', 'authorization'}
    if any(k.lower() in secret_keys for k, _ in urllib.parse.parse_qsl(url.query)):
        raise ValueError('Use a public radio stream link without login credentials.')
    if url.path.lower().endswith(('.pls', '.m3u', '.xspf')):
        raise ValueError('Paste the direct audio stream link instead of a playlist file.')
    return urllib.parse.urlunsplit((url.scheme, url.netloc, url.path, url.query, ''))


def make_station(name, url, genre='Radio', country='', language='', public=False):
    url = stream_url(url)
    if public:
        host = urllib.parse.urlsplit(url).hostname.rstrip('.').lower()
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            if host == 'localhost' or '.' not in host or host.endswith(('.local', '.localhost', '.internal')):
                raise ValueError('Non-public station address') from None
        else:
            if not address.is_global: raise ValueError('Non-public station address')
    title = text(name)
    if not title: raise ValueError('Enter a station name.')
    return dict(id='radio:custom:' + hashlib.sha256(url.encode()).hexdigest(), source='radio',
                title=title, artist=text(genre, 240) or 'Radio', album='Radio', albumId='radio',
                duration=0, radioUrl=url, country=text(country, 120), language=text(language, 120))


def clean_station(row):
    if not isinstance(row, dict) or not isinstance(row.get('id'), str): raise ValueError('Invalid radio station.')
    builtin = station(row['id'])
    if builtin: return builtin
    custom = make_station(row.get('title'), row.get('radioUrl'), row.get('artist', 'Radio'), row.get('country', ''), row.get('language', ''))
    if custom['id'] != row['id']: raise ValueError('Invalid radio station identity.')
    return custom
