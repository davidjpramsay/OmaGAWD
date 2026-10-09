"""Bounded searches of Radio Browser; directory data is untrusted."""
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import radio_library as radio

MAX_BYTES = 2 * 1024 * 1024
PAGE_SIZE = 100
MAX_RESULTS = 1000
MIRRORS = ('https://de1.api.radio-browser.info', 'https://de2.api.radio-browser.info')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args): return None


class RadioBrowser:
    def __init__(self, opener=None, mirrors=MIRRORS):
        self.opener = opener or urllib.request.build_opener(NoRedirect)
        self.mirrors = mirrors

    def search(self, fields, offset=0):
        if not isinstance(fields, dict): raise ValueError('Invalid radio search fields.')
        if type(offset) is not int or offset < 0 or offset >= MAX_RESULTS or offset % PAGE_SIZE: raise ValueError('Radio search page is out of range.')
        params = {'limit': PAGE_SIZE, 'offset': offset, 'hidebroken': 'true', 'order': 'clickcount', 'reverse': 'true'}
        for field, key in (('name', 'name'), ('genre', 'tag'), ('country', 'country'), ('language', 'language')):
            value = fields.get(field, '')
            if not isinstance(value, str) or len(value) > 160: raise ValueError('Radio search fields must be at most 160 characters.')
            if value.strip(): params[key] = value.strip()
        for mirror in self.mirrors:
            try:
                request = urllib.request.Request(mirror + '/json/stations/search?' + urllib.parse.urlencode(params), headers={'User-Agent': 'OmaGAWD/0.7.2', 'Accept': 'application/json', 'Accept-Encoding': 'identity'})
                with self.opener.open(request, timeout=5) as response:
                    if response.headers.get('Content-Encoding', 'identity').lower() != 'identity': raise ValueError('Encoded radio response')
                    raw = bytearray(); deadline = time.monotonic() + 10
                    while True:
                        if time.monotonic() > deadline: raise ValueError('Radio response timed out')
                        chunk = response.read1(min(65536, MAX_BYTES + 1 - len(raw)))
                        if not chunk: break
                        raw.extend(chunk)
                        if len(raw) > MAX_BYTES: raise ValueError('Radio response exceeds limit')
                data = json.loads(raw)
                if not isinstance(data, list) or len(data) > PAGE_SIZE: raise ValueError('Invalid radio directory response')
                rows, seen = [], set()
                for item in data:
                    try:
                        row = radio.make_station(item['name'], item.get('url_resolved') or item['url'], item.get('tags') or 'Radio', item.get('country') or '', item.get('language') or '', public=True)
                        if row['id'] not in seen: rows.append(row); seen.add(row['id'])
                    except (ValueError, KeyError, TypeError): continue
                return rows, len(data) == PAGE_SIZE and offset + PAGE_SIZE < MAX_RESULTS
            except urllib.error.HTTPError as exc: exc.close()
            except (OSError, ValueError, TypeError, RecursionError): pass
        raise RuntimeError('Radio search is unavailable. Try again later; saved stations still work.')
