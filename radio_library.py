"""Cliamp's curated public stations. Persist IDs, never arbitrary stream URLs.

Catalog: https://github.com/bjarneo/cliamp/blob/main/site/index.html
"""
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
    row = station(track_id)
    if row is None:
        raise ValueError('Unknown radio station.')
    return 'https://radio.cliamp.stream/' + row['id'].split(':', 1)[1] + '/stream'


def remote(track):
    """Only Jellyfin tracks require a saved account identity."""
    return track.get('source') not in ('local', 'radio')
