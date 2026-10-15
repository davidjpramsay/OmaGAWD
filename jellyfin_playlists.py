"""Bounded Jellyfin-hosted music playlists. No local paths or radio URLs."""
import uuid
import urllib.error
import re
import metadata
from collection_store import name

MAX_PLAYLISTS = 1000
MAX_TRACKS = 100_000
MAX_BYTES = 64 * 1024 * 1024
PAGE_SIZE = 200


class Cancelled(RuntimeError):
    pass


class CreationUncertain(RuntimeError):
    pass


def item_id(value):
    if not isinstance(value, str) or len(value) not in (32, 36):
        raise ValueError('Jellyfin returned an invalid playlist or track identity.')
    try: parsed = uuid.UUID(value)
    except ValueError: raise ValueError('Jellyfin returned an invalid playlist or track identity.') from None
    if not parsed.int: raise ValueError('Jellyfin returned an empty item identity.')
    return parsed.hex


def music_row(row):
    if not isinstance(row, dict) or not isinstance(row.get('Id'), str) or not 0 < len(row['Id']) <= 512:
        raise ValueError('Jellyfin returned an invalid track.')
    if row.get('Type') not in (None, 'Audio') or row.get('MediaType') not in (None, 'Audio'):
        raise ValueError('This playlist contains unsupported non-music items.')
    artists = row.get('Artists')
    artists = ', '.join(metadata.text(a) for a in artists[:32]) if isinstance(artists, list) else ''
    ticks = row.get('RunTimeTicks', 0)
    duration = ticks / 10_000_000 if type(ticks) in (int, float) and 0 <= ticks <= 2**31 * 10_000_000 else 0
    return {'id': row['Id'], 'title': metadata.text(row.get('Name'), 'Untitled'),
            'artist': metadata.text(row.get('AlbumArtist'), metadata.text(artists, 'Unknown artist')),
            'album': metadata.text(row.get('Album'), 'Unknown album'),
            'albumId': metadata.text(row.get('AlbumId'), metadata.text(row.get('Album'))),
            'duration': metadata.number(duration), 'track': int(metadata.number(row.get('IndexNumber', 0))),
            'disc': int(metadata.number(row.get('ParentIndexNumber', 0)))}


def pages(client, path, params, maximum, cancelled):
    offset, total_bytes = 0, 0
    while True:
        if cancelled(): raise Cancelled()
        data = client.request(path, dict(params, StartIndex=offset, Limit=PAGE_SIZE))
        if cancelled(): raise Cancelled()
        total_bytes += client.response_bytes
        rows = data.get('Items', [])
        total = data.get('TotalRecordCount', offset + len(rows)) if isinstance(rows, list) else -1
        if (not isinstance(rows, list) or len(rows) > PAGE_SIZE or type(total) is not int
                or not 0 <= total <= maximum or offset + len(rows) > maximum or total_bytes > MAX_BYTES):
            raise ValueError('Jellyfin playlists exceed their track, count or 64 MiB safety limit.')
        if not rows and offset < total:
            raise ValueError('Jellyfin returned an incomplete playlist page. Try opening it again.')
        yield rows
        offset += len(rows)
        if not rows or offset >= total: return


def catalog(client, cancelled=lambda: False):
    result, seen = [], set()
    params = {'UserId': client.user, 'IncludeItemTypes': 'Playlist', 'MediaTypes': 'Audio',
              'Recursive': 'true', 'SortBy': 'SortName', 'SortOrder': 'Ascending', 'Fields': 'ChildCount'}
    for page in pages(client, '/Items', params, MAX_PLAYLISTS, cancelled):
        for row in page:
            if not isinstance(row, dict): raise ValueError('Jellyfin returned an invalid playlist.')
            key = item_id(row.get('Id'))
            if key in seen: raise ValueError('Jellyfin repeated playlists while paging.')
            seen.add(key)
            if row.get('Type') not in (None, 'Playlist'): raise ValueError('Jellyfin returned an invalid playlist type.')
            if row.get('MediaType') not in (None, 'Audio'): continue
            count = row.get('ChildCount')
            if count is not None and (type(count) is not int or not 0 <= count <= MAX_TRACKS):
                raise ValueError('Jellyfin returned an invalid playlist size.')
            result.append({'id': key, 'name': metadata.text(row.get('Name'), 'Untitled playlist'), 'count': count})
    return result


def tracks(client, playlist, cancelled=lambda: False):
    key = item_id(playlist)
    result = []
    for page in pages(client, '/Playlists/' + key + '/Items', {'UserId': client.user}, MAX_TRACKS, cancelled):
        for row in page:
            song = music_row(row); song['id'] = item_id(song['id'])
            # Jellyfin versions may reuse PlaylistItemId for repeated songs.
            # Preserve all positions; the pagination/byte budgets bound repeats.
            song['entry'] = str(len(result))
            result.append(song)
    return result


def create(client, title, rows, cancelled=lambda: False):
    title = name(title)
    if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_TRACKS:
        raise ValueError('Queue 1–100,000 Jellyfin songs before creating a playlist.')
    ids = []
    for row in rows:
        if not isinstance(row, dict) or row.get('source') not in (None, 'jellyfin') or 'path' in row or 'radioUrl' in row:
            raise ValueError('Only Jellyfin songs can be saved to a Jellyfin playlist. Local music and radio stay on this device.')
        ids.append(item_id(row.get('id')))
    user = item_id(client.user)
    if cancelled(): raise Cancelled()
    # Older servers ignore the privacy field; do not create a public playlist
    # while the UI promises a private one. Reads still work on older servers.
    info = client.request('/System/Info/Public')
    version = info.get('Version', '')
    parsed = re.fullmatch(r'(\d{1,4})\.(\d{1,4})\.(\d{1,4})(?:\.\d{1,4})?(?:[-+][A-Za-z0-9.-]{1,64})?', version) if isinstance(version, str) else None
    if not parsed or tuple(map(int, parsed.groups())) < (10, 9, 0):
        raise ValueError('Private playlist creation requires Jellyfin 10.9 or newer.')
    if cancelled(): raise Cancelled()
    # Never retry this POST automatically: a lost response can still mean success.
    try:
        data = client.request('/Playlists', body={'Name': title, 'Ids': ids, 'UserId': user,
                                                 'MediaType': 'Audio', 'IsPublic': False, 'Users': []})
        return {'id': item_id(data.get('Id')), 'name': title, 'count': len(ids)}
    except urllib.error.HTTPError: raise
    except Exception as exc:
        raise CreationUncertain('Creation could not be confirmed. Check Jellyfin before retrying; the playlist may already exist.') from exc
