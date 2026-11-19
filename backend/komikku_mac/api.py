# SPDX-License-Identifier: GPL-3.0-or-later
"""
Backend API exposed to the Swift frontend.

Everything goes through upstream Komikku's own models (`Manga`, `Chapter`) and
server classes, so the database, file layout and behaviour stay identical to
the Linux app.
"""

import datetime
import hashlib
import importlib
import inspect
import logging
import os
import subprocess
import threading

from komikku_mac.rpc import RPCError
from komikku_mac.rpc import method

logger = logging.getLogger('komikku_mac.api')

_servers_cache = {}
_servers_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _upstream_commit():
    from komikku_mac.bootstrap import find_upstream_root
    root = find_upstream_root()
    stamp = os.path.join(root, 'UPSTREAM_COMMIT')
    if os.path.exists(stamp):
        with open(stamp) as fp:
            return fp.read().strip()
    try:
        return subprocess.check_output(['git', '-C', root, 'rev-parse', '--short', 'HEAD'], text=True).strip()
    except Exception:
        return None


def _get_server(server_id):
    """Instantiate (once) the upstream server class for `server_id`."""
    from komikku.servers.utils import get_server_class_name_by_id
    from komikku.servers.utils import get_server_module_name_by_id

    with _servers_lock:
        server = _servers_cache.get(server_id)
        if server is None:
            try:
                module = importlib.import_module('.' + get_server_module_name_by_id(server_id), package='komikku.servers')
                server = getattr(module, get_server_class_name_by_id(server_id))()
            except Exception as exc:
                raise RPCError(f'Unknown server: {server_id}', 'unknown_server') from exc
            _servers_cache[server_id] = server
    return server


def _jsonable(value):
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    if isinstance(value, (list, tuple, set)):
        return [_jsonable(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    return None


_MANGA_FIELDS = (
    'id', 'slug', 'url', 'server_id', 'name', 'authors', 'scanlators', 'genres', 'synopsis', 'status',
    'in_library', 'last_read', 'last_update', 'reading_mode', 'scaling', 'sort_order',
)
_CHAPTER_FIELDS = (
    'id', 'manga_id', 'slug', 'url', 'title', 'scanlators', 'date', 'num', 'num_volume', 'rank',
    'downloaded', 'recent', 'read', 'read_progress', 'last_page_read_index', 'last_read',
)


def _manga_dict(manga, with_chapters=False):
    data = {key: _jsonable(getattr(manga, key, None)) for key in _MANGA_FIELDS}
    data['in_library'] = bool(data['in_library'])
    data['cover_path'] = manga.cover_fs_path if manga.cover_fs_path and os.path.exists(manga.cover_fs_path) else None
    try:
        data['server_name'] = manga.server.name
    except Exception:
        data['server_name'] = manga.server_id
    data['nb_unread_chapters'] = manga.nb_unread_chapters
    data['nb_recent_chapters'] = manga.nb_recent_chapters
    if with_chapters:
        data['chapters'] = [_chapter_dict(chapter) for chapter in manga.chapters]
    return data


def _chapter_dict(chapter):
    data = {key: _jsonable(getattr(chapter, key, None)) for key in _CHAPTER_FIELDS}
    for key in ('downloaded', 'recent', 'read'):
        data[key] = bool(data[key])
    data['nb_pages'] = len(chapter.pages) if chapter.pages else None
    return data


def _get_manga(manga_id):
    from komikku.models import Manga
    manga = Manga.get(manga_id)
    if manga is None:
        raise RPCError(f'Manga {manga_id} not found', 'not_found')
    return manga


def _get_chapter(chapter_id):
    from komikku.models import Chapter
    chapter = Chapter.get(chapter_id)
    if chapter is None:
        raise RPCError(f'Chapter {chapter_id} not found', 'not_found')
    return chapter


def _db():
    from komikku.models import create_db_connection
    return create_db_connection()


# ---------------------------------------------------------------------------
# App / settings
# ---------------------------------------------------------------------------

@method('app.hello')
def app_hello():
    from komikku.utils import get_data_dir
    return {
        'upstream_commit': _upstream_commit(),
        'data_dir': get_data_dir(),
    }


@method('settings.get')
def settings_get():
    from gi.repository import Gio
    return Gio.Settings.dump()


@method('settings.set')
def settings_set(key, value):
    from komikku.models import Settings
    settings = Settings.get_default()
    info = settings._key(key)
    settings._set_raw(key, value if info['type'] != 'enum' else str(value))
    return True


# ---------------------------------------------------------------------------
# Servers / explorer
# ---------------------------------------------------------------------------

@method('servers.languages')
def servers_languages():
    from komikku.servers import LANGUAGES
    return LANGUAGES


@method('servers.list')
def servers_list(all_languages=False):
    from komikku.models import Settings
    from komikku.servers.utils import get_allowed_servers_list
    from komikku.servers.utils import get_servers_list

    settings = Settings.get_default()
    servers = get_servers_list() if all_languages else get_allowed_servers_list(settings)
    pinned = settings.pinned_servers

    result = []
    for server in servers:
        cls = getattr(server['module'], server['class_name'], None)
        result.append({
            'id': server['id'],
            'name': server['name'],
            'lang': server['lang'],
            'description': server['description'],
            'base_url': server['base_url'],
            'is_nsfw': bool(server['is_nsfw']),
            'is_nsfw_only': bool(server['is_nsfw_only']),
            'has_login': bool(server['has_login']),
            'logo_url': server['logo_url'],
            'logo_path': server['logo_path'],
            'true_search': bool(getattr(cls, 'true_search', True)),
            'has_latest': _overrides(cls, 'get_latest_updates'),
            'has_popular': _overrides(cls, 'get_most_populars'),
            'pinned': server['id'] in pinned,
        })
    return result


def _overrides(cls, name):
    if cls is None:
        return False
    from komikku.servers import Server
    func = getattr(cls, name, None)
    base = getattr(Server, name, None)
    return func is not None and func is not base


@method('servers.set_pinned')
def servers_set_pinned(server_id, pinned):
    from komikku.models import Settings
    settings = Settings.get_default()
    ids = [i for i in settings.pinned_servers if i != server_id]
    if pinned:
        ids.append(server_id)
    settings.pinned_servers = ids
    return ids


def _search_results(results):
    if results is None:
        raise RPCError('The server returned no results (network error or site changed)', 'server_error')
    return [_jsonable(item) for item in results]


def _call_with_supported_kwargs(func, **kwargs):
    params = inspect.signature(func).parameters
    return func(**{k: v for k, v in kwargs.items() if k in params})


@method('explorer.search')
def explorer_search(server_id, term, filters=None):
    server = _get_server(server_id)
    return _search_results(_call_with_supported_kwargs(server.search, term=term, **(filters or {})))


@method('explorer.latest')
def explorer_latest(server_id, filters=None):
    server = _get_server(server_id)
    return _search_results(_call_with_supported_kwargs(server.get_latest_updates, **(filters or {})))


@method('explorer.popular')
def explorer_popular(server_id, filters=None):
    server = _get_server(server_id)
    return _search_results(_call_with_supported_kwargs(server.get_most_populars, **(filters or {})))


@method('server.image')
def server_image(server_id, url):
    """Fetch a remote image (cover, logo) with the server's headers/session; returns a cached file path."""
    from komikku.utils import get_cache_dir

    if not url:
        return None
    cache_dir = os.path.join(get_cache_dir(), 'mac-images', server_id)
    os.makedirs(cache_dir, exist_ok=True)
    path = os.path.join(cache_dir, hashlib.sha1(url.encode()).hexdigest())
    if os.path.exists(path):
        return path

    server = _get_server(server_id)
    buffer, _etag, _rtime = server.get_image(url)
    if buffer is None:
        return None
    tmp = path + '.part'
    with open(tmp, 'wb') as fp:
        fp.write(buffer)
    os.replace(tmp, path)
    return path


# ---------------------------------------------------------------------------
# Manga
# ---------------------------------------------------------------------------

@method('manga.open')
def manga_open(server_id, slug, name=None, url=None, cover=None):
    """
    Same flow as upstream's Explorer: reuse the DB record if the manga is known,
    otherwise fetch it from the server and store it (not yet in library).
    """
    from komikku.models import Manga
    from komikku.models import Settings

    record = _db().execute('SELECT id FROM mangas WHERE slug = ? AND server_id = ?', (slug, server_id)).fetchone()
    if record:
        return _manga_dict(Manga.get(record['id']), with_chapters=True)

    server = _get_server(server_id)
    initial_data = {'slug': slug}
    if name is not None:
        initial_data['name'] = name
    if url is not None:
        initial_data['url'] = url
    if cover is not None:
        initial_data['cover'] = cover

    data = server.get_manga_data(initial_data)
    if data is None:
        raise RPCError('Failed to retrieve manga data from server', 'server_error')

    manga = Manga.new(data, server, Settings.get_default().long_strip_detection)
    return _manga_dict(manga, with_chapters=True)


@method('manga.get')
def manga_get(manga_id):
    return _manga_dict(_get_manga(manga_id), with_chapters=True)


@method('manga.refresh')
def manga_refresh(manga_id):
    manga = _get_manga(manga_id)
    success, changes, _synced = manga.update_full()
    if not success:
        raise RPCError('Failed to update manga', 'server_error')
    manga = _get_manga(manga_id)
    return {'manga': _manga_dict(manga, with_chapters=True), 'changes': _jsonable(changes)}


@method('manga.add_to_library')
def manga_add_to_library(manga_id):
    manga = _get_manga(manga_id)
    if not manga.in_library:
        manga.add_in_library()
    return _manga_dict(_get_manga(manga_id))


@method('manga.delete')
def manga_delete(manga_id):
    _get_manga(manga_id).delete()
    return True


@method('manga.update')
def manga_update(manga_id, fields):
    allowed = {'reading_mode', 'scaling', 'sort_order'}
    manga = _get_manga(manga_id)
    manga.update({k: v for k, v in fields.items() if k in allowed})
    return _manga_dict(manga)


@method('library.list')
def library_list():
    from komikku.models import Manga
    rows = _db().execute('SELECT id FROM mangas WHERE in_library = 1 ORDER BY last_read DESC').fetchall()
    result = []
    for row in rows:
        manga = Manga.get(row['id'])
        if manga is not None:
            result.append(_manga_dict(manga))
    return result


@method('library.update')
def library_update():
    """Check every library manga for new chapters (sequential, like upstream's updater)."""
    from komikku.models import Manga
    from komikku_mac.rpc import notify

    rows = _db().execute('SELECT id FROM mangas WHERE in_library = 1').fetchall()
    total_new = 0
    for index, row in enumerate(rows):
        manga = Manga.get(row['id'])
        if manga is None or manga.is_local:
            continue
        notify('library.update_progress', {'index': index, 'count': len(rows), 'name': manga.name})
        try:
            success, changes, _synced = manga.update_full()
        except Exception as exc:
            logger.warning('Update failed for %s: %s', manga.name, exc)
            continue
        if success and changes['recent_ids']:
            total_new += len(changes['recent_ids'])
            notify('library.manga_updated', {'manga_id': manga.id, 'nb_new': len(changes['recent_ids'])})
    return {'nb_new_chapters': total_new}


# ---------------------------------------------------------------------------
# Chapters / reading
# ---------------------------------------------------------------------------

@method('chapter.load')
def chapter_load(chapter_id):
    """Make sure the chapter's pages list is known; returns chapter info + page count."""
    chapter = _get_chapter(chapter_id)
    if not chapter.update_full():
        raise RPCError('Failed to load chapter pages', 'server_error')
    chapter = _get_chapter(chapter_id)
    data = _chapter_dict(chapter)
    data['page_paths'] = [chapter.get_page_path(i) for i in range(len(chapter.pages))]
    return data


@method('chapter.page')
def chapter_page(chapter_id, index):
    """Download (if needed) and return the local path of page `index`."""
    chapter = _get_chapter(chapter_id)
    if not chapter.pages:
        chapter_load(chapter_id)
        chapter = _get_chapter(chapter_id)
    if index < 0 or index >= len(chapter.pages):
        raise RPCError('Page index out of range', 'out_of_range')
    path, _rtime = chapter.get_page(index)
    if path is None:
        raise RPCError('Failed to download page', 'server_error')
    return path


@method('chapter.mark_pages_read')
def chapter_mark_pages_read(chapter_id, indexes):
    """Mirror of upstream reader bookkeeping (reader/pagers/__init__.py)."""
    chapter = _get_chapter(chapter_id)
    db_conn = _db()
    now = datetime.datetime.now(datetime.UTC)

    chapter.manga.update({'last_read': now}, db_conn=db_conn)

    if chapter.read or not chapter.pages:
        return _chapter_dict(chapter)

    read_progress = chapter.read_progress or '0' * len(chapter.pages)
    for index in indexes:
        if 0 <= index < len(read_progress):
            read_progress = read_progress[:index] + '1' + read_progress[index + 1:]
    chapter_is_read = '0' not in read_progress

    chapter.update({
        'last_page_read_index': max(indexes) if not chapter_is_read else None,
        'last_read': now,
        'read_progress': None if chapter_is_read else read_progress,
        'read': chapter_is_read,
        'recent': 0,
    }, db_conn=db_conn)

    return _chapter_dict(chapter)


@method('chapter.set_read')
def chapter_set_read(chapter_ids, read):
    from komikku.models import Chapter
    db_conn = _db()
    for chapter_id in chapter_ids:
        chapter = Chapter.get(chapter_id, db_conn=db_conn)
        if chapter is None:
            continue
        chapter.update({
            'read': bool(read),
            'recent': 0,
            'read_progress': None,
            'last_page_read_index': None,
        }, db_conn=db_conn)
    return True


@method('chapter.clear')
def chapter_clear(chapter_ids):
    from komikku.models import Chapter
    chapters = [c for c in (Chapter.get(i) for i in chapter_ids) if c is not None]
    Chapter.clear_many(chapters)
    return True


@method('chapter.download')
def chapter_download(chapter_id):
    """Download every page of a chapter, reporting progress via notifications."""
    from komikku_mac.rpc import notify

    chapter = _get_chapter(chapter_id)
    if not chapter.pages:
        chapter_load(chapter_id)
        chapter = _get_chapter(chapter_id)
    count = len(chapter.pages)
    for index in range(count):
        path, _rtime = chapter.get_page(index)
        if path is None:
            raise RPCError(f'Failed to download page {index + 1}', 'server_error')
        notify('chapter.download_progress', {'chapter_id': chapter_id, 'index': index + 1, 'count': count})
    return _chapter_dict(_get_chapter(chapter_id))


@method('debug.ping')
def debug_ping(**kwargs):
    return {'pong': True, 'echo': kwargs}

