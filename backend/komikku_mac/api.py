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
    'in_library', 'last_read', 'last_update', 'reading_mode', 'scaling', 'sort_order', 'double_page',
    'background_color', 'borders_crop', 'borders_crop_threshold', 'landscape_zoom', 'page_numbering',
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
    data['path'] = manga.path
    data['nb_unread_chapters'] = manga.nb_unread_chapters
    data['nb_recent_chapters'] = manga.nb_recent_chapters
    data['nb_downloaded_chapters'] = manga.nb_downloaded_chapters
    data['categories'] = manga.categories
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
            'main_id': _main_id(server['id']),
            'has_filters': bool(server.get('filters')),
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


# ---------------------------------------------------------------------------
# Server settings (enable/disable, languages, account, params) — mirrors
# upstream's Preferences > Servers pages
# ---------------------------------------------------------------------------

def _main_id(server_id):
    from komikku.servers.utils import get_server_main_id_by_id
    return get_server_main_id_by_id(server_id)


def _servers_settings():
    from komikku.models import Settings
    return Settings.get_default().servers_settings


def _server_params_defaults(server):
    """Same as upstream preferences.servers.get_server_default_params."""
    params = {}
    for param in (server.get('params') or []):
        if param['type'] == 'select' and param.get('value_type') == 'multiple':
            params[param['key']] = [o['key'] for o in param['options'] if o.get('default')]
        else:
            params[param['key']] = param.get('default')
    for param in (server.get('filters') or []):
        if not param.get('include_in_settings'):
            continue
        if param['type'] == 'select' and param.get('value_type') == 'multiple':
            params[param['key']] = [o['key'] for o in param['options'] if o.get('default')]
        else:
            params[param['key']] = param.get('default')
    return params


def _forget_server_instances(main_id):
    with _servers_lock:
        for server_id in [i for i in _servers_cache if _main_id(i) == main_id]:
            del _servers_cache[server_id]


@method('servers.catalog')
def servers_catalog():
    """All servers grouped by main id, with enable/language state and settings metadata."""
    from komikku.models import Settings
    from komikku.models.keyring import KeyringHelper
    from komikku.servers.utils import get_servers_list

    settings = Settings.get_default()
    servers_settings = settings.servers_settings
    allowed_langs = settings.servers_languages
    keyring = KeyringHelper()

    catalog = {}
    for server in get_servers_list():
        main_id = _main_id(server['id'])
        entry = catalog.get(main_id)
        if entry is None:
            server_settings = servers_settings.get(main_id, {})
            credential = keyring.get(main_id) if server['has_login'] else None
            entry = catalog[main_id] = {
                'main_id': main_id,
                'name': server['name'],
                'enabled': server_settings.get('enabled', True),
                'is_nsfw': bool(server['is_nsfw']),
                'has_login': bool(server['has_login']),
                'needs_address': server['base_url'] is None,
                'username': credential.username if credential else None,
                'address': credential.address if credential else None,
                'params': _jsonable(server.get('params') or []),
                'settings_filters': _jsonable([f for f in (server.get('filters') or []) if f.get('include_in_settings')]),
                'param_values': {**_server_params_defaults(server), **server_settings.get('params', {})},
                'languages': [],
            }
        if not allowed_langs or server['lang'] in allowed_langs or server['lang'] == '':
            entry['languages'].append({
                'lang': server['lang'],
                'enabled': servers_settings.get(main_id, {}).get('langs', {}).get(server['lang'], True),
            })

    result = [e for e in catalog.values() if e['languages']]
    result.sort(key=lambda e: e['name'].lower())
    return result


def _ensure_server_settings_entry(main_id):
    # Upstream's toggle helpers assume 'langs'/'enabled' exist once the entry exists
    from komikku.models import Settings
    settings = Settings.get_default()
    servers_settings = settings.servers_settings
    entry = servers_settings.setdefault(main_id, {})
    entry.setdefault('langs', {})
    entry.setdefault('enabled', True)
    settings.servers_settings = servers_settings
    return settings


@method('server.toggle')
def server_toggle(main_id, enabled):
    _ensure_server_settings_entry(main_id).toggle_server(main_id, bool(enabled))
    return True


@method('server.toggle_lang')
def server_toggle_lang(main_id, lang, enabled):
    _ensure_server_settings_entry(main_id).toggle_server_lang(main_id, lang, bool(enabled))
    return True


@method('server.set_params')
def server_set_params(main_id, values):
    from komikku.models import Settings
    settings = Settings.get_default()
    servers_settings = settings.servers_settings
    servers_settings.setdefault(main_id, {}).setdefault('params', {}).update(values)
    settings.servers_settings = servers_settings
    _forget_server_instances(main_id)
    return servers_settings[main_id]['params']


def _server_class(main_id):
    from komikku.servers.utils import get_servers_list
    for server in get_servers_list(include_disabled=True):
        if _main_id(server['id']) == main_id:
            return getattr(server['module'], server['class_name'])
    raise RPCError(f'Unknown server: {main_id}', 'unknown_server')


@method('server.login')
def server_login(main_id, username, password, address=None):
    from komikku.models.keyring import KeyringHelper

    cls = _server_class(main_id)
    if address is not None:
        address = address.strip().rstrip('/')
        if not address.startswith(('http://', 'https://')):
            raise RPCError('Adres http:// ya da https:// ile başlamalı', 'bad_address')

    # Drop any saved session so the new credentials are really checked
    try:
        cls().clear_session(all=True)
    except Exception:
        pass
    _forget_server_instances(main_id)

    try:
        server = cls(username=username, password=password, address=address) if address is not None \
            else cls(username=username, password=password)
    except Exception as exc:
        raise RPCError(f'Giriş başarısız: {exc}', 'login_failed') from exc

    if not server.logged_in:
        raise RPCError('Giriş başarısız: kullanıcı adı, parola ya da adres hatalı', 'login_failed')

    KeyringHelper().store(main_id, username, password, address)
    _forget_server_instances(main_id)
    return True


@method('server.logout')
def server_logout(main_id):
    from komikku.models.keyring import KeyringHelper

    try:
        _server_class(main_id)().clear_session(all=True)
    except Exception:
        pass
    KeyringHelper().delete(main_id)
    _forget_server_instances(main_id)
    return True


@method('server.filters')
def server_filters(server_id):
    """Search filters of a server with their current default values."""
    server = _get_server(server_id)
    return {
        'filters': _jsonable(server.filters or []),
        'values': _jsonable(_filters(server, None)),
    }


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


def _filters(server, filters):
    """Server's default filters (as upstream's Explorer uses them), overridden by `filters`."""
    try:
        from komikku.explorer.common import get_server_default_search_filters
        defaults = get_server_default_search_filters(server)
    except Exception as exc:
        logger.warning('%s: cannot compute default filters: %s', server.id, exc)
        defaults = {}
    defaults.update(filters or {})
    return defaults


def _call_with_supported_kwargs(func, **kwargs):
    params = inspect.signature(func).parameters
    if any(p.kind == p.VAR_KEYWORD for p in params.values()):
        return func(**kwargs)
    return func(**{k: v for k, v in kwargs.items() if k in params})


@method('explorer.search')
def explorer_search(server_id, term, filters=None, interactive=True):
    from komikku_mac.webview_bridge import ChallengeRequired
    from komikku_mac.webview_bridge import no_interaction

    server = _get_server(server_id)
    kwargs = _filters(server, filters)
    if interactive:
        return _search_results(_call_with_supported_kwargs(server.search, term=term, **kwargs))

    # Global search: never pop up a browser window
    try:
        with no_interaction():
            return _search_results(_call_with_supported_kwargs(server.search, term=term, **kwargs))
    except ChallengeRequired as exc:
        raise RPCError('Tarayıcı doğrulaması gerekiyor — sunucuyu tek başına açın', 'challenge_required') from exc


@method('explorer.latest')
def explorer_latest(server_id, filters=None):
    server = _get_server(server_id)
    return _search_results(_call_with_supported_kwargs(server.get_latest_updates, **_filters(server, filters)))


@method('explorer.popular')
def explorer_popular(server_id, filters=None):
    server = _get_server(server_id)
    return _search_results(_call_with_supported_kwargs(server.get_most_populars, **_filters(server, filters)))


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
    allowed = {
        'reading_mode', 'scaling', 'sort_order', 'double_page',
        'background_color', 'borders_crop', 'borders_crop_threshold', 'landscape_zoom', 'page_numbering',
    }
    manga = _get_manga(manga_id)
    manga.update({k: v for k, v in fields.items() if k in allowed})
    return _manga_dict(manga)


@method('manga.set_all_read')
def manga_set_all_read(manga_ids, read):
    for manga_id in manga_ids:
        ids = [r['id'] for r in _db().execute('SELECT id FROM chapters WHERE manga_id = ?', (manga_id,)).fetchall()]
        chapter_set_read(ids, read)
    return True


@method('manga.delete_many')
def manga_delete_many(manga_ids):
    from komikku.models import Manga
    for manga_id in manga_ids:
        manga = Manga.get(manga_id)
        if manga is not None:
            manga.delete()
    return True


# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------

@method('categories.list')
def categories_list():
    rows = _db().execute('''
        SELECT c.id, c.label, count(m.id) AS count
        FROM categories c
        LEFT JOIN categories_mangas_association cma ON cma.category_id = c.id
        LEFT JOIN mangas m ON m.id = cma.manga_id AND m.in_library = 1
        GROUP BY c.id ORDER BY lower(c.label)
    ''').fetchall()
    return [dict(row) for row in rows]


@method('categories.create')
def categories_create(label):
    from komikku.models import Category
    label = label.strip()
    if not label:
        raise RPCError('Kategori adı boş olamaz', 'bad_label')
    category = Category.new(label)
    if category is None:
        raise RPCError('Bu adda bir kategori zaten var', 'duplicate')
    return {'id': category.id, 'label': category.label}


@method('categories.rename')
def categories_rename(category_id, label):
    from komikku.models import Category
    category = Category.get(category_id)
    if category is None:
        raise RPCError('Kategori bulunamadı', 'not_found')
    if not category.update({'label': label.strip()}):
        raise RPCError('Kategori yeniden adlandırılamadı', 'duplicate')
    return True


@method('categories.delete')
def categories_delete(category_id):
    from komikku.models import Category
    from komikku.models import Settings
    category = Category.get(category_id)
    if category is not None:
        category.delete()
    settings = Settings.get_default()
    if settings.selected_category == category_id:
        settings.selected_category = 0
    return True


@method('categories.assign')
def categories_assign(manga_ids, category_id, active):
    from komikku.models import Manga
    for manga_id in manga_ids:
        manga = Manga.get(manga_id)
        if manga is None:
            continue
        has = category_id in manga.categories
        if active and not has:
            manga.toggle_category(category_id, True)
        elif not active and has:
            manga.toggle_category(category_id, False)
    return True


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

@method('history.list')
def history_list(days=90):
    """Same query as upstream's History page: last read chapter per manga and day."""
    from komikku.models import Chapter
    db_conn = _db()
    start = (datetime.date.today() - datetime.timedelta(days=days)).strftime('%Y-%m-%d')
    records = db_conn.execute('''
        SELECT DISTINCT manga_id, date(last_read, 'localtime') AS last_read_date, id, max(last_read) AS last_read
        FROM chapters WHERE date(last_read, 'localtime') >= ?
        GROUP BY manga_id, last_read_date
        ORDER BY last_read DESC
    ''', (start,)).fetchall()

    result = []
    for record in records:
        chapter = Chapter.get(record['id'], db_conn=db_conn)
        if chapter is None:
            continue
        manga = chapter.manga
        cover = manga.cover_fs_path
        result.append({
            'date': record['last_read_date'],
            'last_read': _jsonable(record['last_read']),
            'chapter_id': chapter.id,
            'chapter_title': chapter.title,
            'chapter_read': bool(chapter.read),
            'last_page_read_index': chapter.last_page_read_index,
            'manga_id': manga.id,
            'manga_name': manga.name,
            'server_name': manga.server.name if manga.server else manga.server_id,
            'cover_path': cover if cover and os.path.exists(cover) else None,
        })
    return result


@method('stats.reading')
def stats_reading(days=30):
    """
    Reading statistics from upstream's chapters table. A chapter counts as "read on a day"
    when it is read and its last_read falls on that day (local time). Chapters only
    marked read in bulk have no last_read and only count in the total.
    """
    db = _db()
    today = datetime.date.today()
    start = today - datetime.timedelta(days=days - 1)

    total_read = db.execute('SELECT count(*) FROM chapters WHERE read = 1').fetchone()[0]

    rows = db.execute('''
        SELECT date(last_read, 'localtime') AS day, count(*) AS n
        FROM chapters
        WHERE read = 1 AND last_read IS NOT NULL AND date(last_read, 'localtime') >= ?
        GROUP BY day
    ''', (start.isoformat(),)).fetchall()
    per_day = {row['day']: row['n'] for row in rows}
    daily = [
        {'date': (start + datetime.timedelta(days=i)).isoformat(),
         'chapters': per_day.get((start + datetime.timedelta(days=i)).isoformat(), 0)}
        for i in range(days)
    ]

    # Current streak: consecutive days up to today (or yesterday) with at least one chapter read
    all_days = {row[0] for row in db.execute('''
        SELECT DISTINCT date(last_read, 'localtime') FROM chapters WHERE read = 1 AND last_read IS NOT NULL
    ''').fetchall()}
    streak = 0
    day = today if today.isoformat() in all_days else today - datetime.timedelta(days=1)
    while day.isoformat() in all_days:
        streak += 1
        day -= datetime.timedelta(days=1)

    top_rows = db.execute('''
        SELECT m.id, m.name, m.server_id, count(c.id) AS n, max(c.last_read) AS last
        FROM chapters c JOIN mangas m ON m.id = c.manga_id
        WHERE c.read = 1 AND c.last_read IS NOT NULL AND date(c.last_read, 'localtime') >= ?
        GROUP BY m.id ORDER BY n DESC, last DESC LIMIT 10
    ''', (start.isoformat(),)).fetchall()
    from komikku.models import Manga
    top = []
    for row in top_rows:
        manga = Manga.get(row['id'], db_conn=db)
        cover = manga.cover_fs_path if manga is not None else None
        top.append({
            'manga_id': row['id'],
            'name': row['name'],
            'server_name': manga.server.name if manga is not None and manga.server else row['server_id'],
            'chapters': row['n'],
            'cover_path': cover if cover and os.path.exists(cover) else None,
        })

    def window(n):
        since = (today - datetime.timedelta(days=n - 1)).isoformat()
        return sum(d['chapters'] for d in daily if d['date'] >= since)

    return {
        'total_read': total_read,
        'last_7_days': window(7),
        'last_30_days': window(min(30, days)),
        'streak_days': streak,
        'library_count': db.execute('SELECT count(*) FROM mangas WHERE in_library = 1').fetchone()[0],
        'daily': daily,
        'top': top,
    }


@method('history.clear')
def history_clear(manga_id=None):
    db_conn = _db()
    with db_conn:
        if manga_id is None:
            db_conn.execute('UPDATE chapters SET last_read = NULL')
        else:
            db_conn.execute('UPDATE chapters SET last_read = NULL WHERE manga_id = ?', (manga_id,))
    return True


_covers_lock = threading.Lock()


@method('library.fetch_missing_covers')
def library_fetch_missing_covers():
    """In the background, re-fetch the cover of library mangas that have none (failed download).
    Each fixed cover is announced with a `manga.cover_updated` notification."""
    from komikku.models import Manga
    from komikku_mac.rpc import notify

    rows = _db().execute('SELECT id FROM mangas WHERE in_library = 1').fetchall()
    missing = []
    for row in rows:
        manga = Manga.get(row['id'])
        if manga is not None and not manga.is_local and manga.cover_fs_path is None:
            missing.append(manga.id)
    if not missing:
        return {'missing': 0}

    def work():
        if not _covers_lock.acquire(blocking=False):
            return
        try:
            for manga_id in missing:
                manga = Manga.get(manga_id)
                if manga is None:
                    continue
                try:
                    data = manga.server.get_manga_data({'slug': manga.slug, 'url': manga.url, 'name': manga.name})
                    cover = (data or {}).get('cover')
                    if cover:
                        os.makedirs(manga.path, exist_ok=True)
                        # A stale ETag makes the server answer 304 and nothing gets written
                        etag = os.path.join(manga.path, 'cover.etag')
                        if os.path.exists(etag):
                            os.remove(etag)
                        manga._save_cover(cover)
                except Exception as exc:
                    logger.info('Cover fetch failed for %s: %s', manga.name, exc)
                    continue
                if manga.cover_fs_path:
                    notify('manga.cover_updated', {'manga_id': manga.id, 'cover_path': manga.cover_fs_path})
        finally:
            _covers_lock.release()

    threading.Thread(target=work, daemon=True, name='covers').start()
    return {'missing': len(missing)}


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


def _services():
    from komikku_mac import services
    if services.window.downloader is None:
        services.init()
    return services.window


@method('library.update')
def library_update(manga_ids=None):
    """Start upstream's Updater (whole library, or given mangas). Progress via `updater.*` notifications."""
    from komikku.models import Manga

    window = _services()
    if manga_ids:
        mangas = [m for m in (Manga.get(i) for i in manga_ids) if m is not None]
        window.updater.add(mangas)
        started = window.updater.start()
    else:
        started = window.updater.update_library()
    return {'started': bool(started), 'running': window.updater.running}


# ---------------------------------------------------------------------------
# Downloads (upstream Downloader + `downloads` table)
# ---------------------------------------------------------------------------

@method('downloads.list')
def downloads_list():
    rows = _db().execute('''
        SELECT d.id, d.chapter_id, d.status, d.percent, d.errors, d.date,
               c.title AS chapter_title, m.id AS manga_id, m.name AS manga_name, m.server_id
        FROM downloads d
        JOIN chapters c ON d.chapter_id = c.id
        JOIN mangas m ON c.manga_id = m.id
        ORDER BY m.server_id ASC, m.id ASC, d.id ASC
    ''').fetchall()
    return {
        'running': _services().downloader.running,
        'items': [_jsonable(dict(row)) for row in rows],
    }


@method('downloads.add')
def downloads_add(chapter_ids, start=True):
    window = _services()
    window.downloader.add(chapter_ids, emit_signal=True)
    if start:
        window.downloader.start()
    return True


@method('downloads.cancel')
def downloads_cancel(chapter_ids):
    from komikku.models import Chapter
    chapters = [c for c in (Chapter.get(i) for i in chapter_ids) if c is not None]
    _services().downloader.cancel(chapters)
    return True


@method('downloads.start')
def downloads_start():
    window = _services()
    # Errored downloads get another chance when the user starts manually
    _db().execute("UPDATE downloads SET status = 'pending', errors = 0 WHERE status = 'error'")
    window.downloader.start()
    return True


@method('downloads.stop')
def downloads_stop():
    _services().downloader.stop(save_state=True)
    return True


@method('downloads.resume_if_needed')
def downloads_resume_if_needed():
    """At launch: resume pending downloads unless the user had stopped the downloader."""
    from komikku.models import Settings
    if Settings.get_default().downloader_state:
        count = _db().execute('SELECT count(*) FROM downloads').fetchone()[0]
        if count:
            _services().downloader.start()
            return True
    return False


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


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

def _dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def _mac_images_dir():
    from komikku.utils import get_cache_dir
    return os.path.join(get_cache_dir(), 'mac-images')


@method('cache.info')
def cache_info():
    from komikku.utils import get_cached_data_dir
    return {
        'chapters_bytes': _dir_size(get_cached_data_dir()),
        'images_bytes': _dir_size(_mac_images_dir()),
    }


@method('cache.clear')
def cache_clear():
    """Upstream's clear_cached_data (pages/mangas not in library) + cached covers/logos."""
    import shutil
    from komikku.models.database import clear_cached_data
    clear_cached_data()
    shutil.rmtree(_mac_images_dir(), ignore_errors=True)
    return cache_info()


def clear_cache_on_exit_if_enabled():
    from komikku.models import Settings
    try:
        if Settings.get_default().clear_cached_data_on_app_close:
            cache_clear()
    except Exception as exc:
        logger.warning('Failed to clear cache on exit: %s', exc)


@method('debug.ping')
def debug_ping(**kwargs):
    return {'pong': True, 'echo': kwargs}

