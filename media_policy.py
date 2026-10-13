"""Music-data boundary shared by local imports, probes and every mpv stream.

Extensions guide local selection; FFmpeg's format whitelist is the enforcement
boundary for disguised files and remote content, before demuxer read_header.
Keep script, playlist, device and external-reference demuxers out of this list.
"""
from pathlib import Path

EXTENSIONS = frozenset({'.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wav',
                        '.aiff', '.aif', '.alac', '.wma', '.ape', '.wv', '.m4b'})
FORMAT_WHITELIST = 'aac,aiff,ape,asf,flac,matroska,mov,mp3,ogg,wav,wv'
AUDIO_FILTER = 'Audio | ' + ' '.join('*' + variant for ext in sorted(EXTENSIONS) for variant in (ext, ext.upper()))


def local_name(value):
    return (isinstance(value, str) and 0 < len(value) <= 4096 and '\0' not in value
            and Path(value).is_absolute() and Path(value).suffix.lower() in EXTENSIONS)


def local_file(value):
    """Validate both the chosen name and canonical target before opening media."""
    if not local_name(value): raise ValueError('Choose a supported audio file, not a script or playlist.')
    path = Path(value).resolve(strict=True)
    if not local_name(str(path)) or not path.is_file():
        raise ValueError('Choose a supported regular audio file.')
    return path


def demux_options(local=False):
    return {'format_whitelist': FORMAT_WHITELIST,
            'protocol_whitelist': 'file' if local else 'http,https,tcp,tls,crypto'}
