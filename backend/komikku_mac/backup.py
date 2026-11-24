# SPDX-License-Identifier: GPL-3.0-or-later
"""
Library backup / restore.

A backup is a zip file:
    manifest.json        format version, date, counts
    komikku.db           consistent copy of upstream's database (sqlite backup API)
    settings.json        upstream settings (servers, languages, reader defaults…)
    app-preferences.json macOS-side preferences, passed in by the frontend

Downloaded chapters and covers are not included (covers are fetched again).

Restoring never touches the live database: the files are validated and staged
in <data dir>/restore-pending/, and applied by `apply_pending_restore()` when the
backend starts next (the frontend restarts it right away).
"""

import datetime
import json
import logging
import os
import shutil
import sqlite3
import tempfile
import zipfile

logger = logging.getLogger('komikku_mac.backup')

FORMAT = 1
PENDING = 'restore-pending'


def _t(turkish, english):
    """Our own few messages follow the app language (upstream's use gettext)."""
    return turkish if os.environ.get('KOMIKKU_LANG', '').lower().startswith('tr') else english


def _paths():
    from gi import _gio as Gio
    from komikku.models.database import get_db_path
    from komikku.utils import get_data_dir
    return get_data_dir(), get_db_path(), Gio.SETTINGS_PATH


def _counts(db_file):
    con = sqlite3.connect(db_file)
    try:
        library = con.execute('SELECT count(*) FROM mangas WHERE in_library = 1').fetchone()[0]
        categories = con.execute('SELECT count(*) FROM categories').fetchone()[0]
        read = con.execute('SELECT count(*) FROM chapters WHERE read = 1').fetchone()[0]
        return {'library': library, 'categories': categories, 'chapters_read': read}
    finally:
        con.close()


def _check(db_file):
    con = sqlite3.connect(db_file)
    try:
        ok = con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        return ok and {'mangas', 'chapters'} <= tables
    except sqlite3.DatabaseError:
        return False
    finally:
        con.close()


def create(path, app_preferences=None):
    _data_dir, db_path, settings_path = _paths()
    with tempfile.TemporaryDirectory() as tmp:
        db_copy = os.path.join(tmp, 'komikku.db')
        src = sqlite3.connect(db_path)
        dst = sqlite3.connect(db_copy)
        try:
            src.backup(dst)
        finally:
            dst.close()
            src.close()
        counts = _counts(db_copy)
        manifest = {
            'format': FORMAT,
            'app': 'komikku-mac',
            'created': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            **counts,
        }
        part = path + '.part'
        with zipfile.ZipFile(part, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('manifest.json', json.dumps(manifest, indent=2))
            z.write(db_copy, 'komikku.db')
            if os.path.exists(settings_path):
                z.write(settings_path, 'settings.json')
            z.writestr('app-preferences.json', json.dumps(app_preferences or {}, indent=2))
        os.replace(part, path)
    logger.info('Backup written to %s (%s)', path, counts)
    return manifest


def stage_restore(path):
    """Validate a backup and stage it; returns its manifest and app preferences."""
    data_dir, _db_path, _settings_path = _paths()
    pending = os.path.join(data_dir, PENDING)
    shutil.rmtree(pending, ignore_errors=True)
    os.makedirs(pending)
    try:
        with zipfile.ZipFile(path) as z:
            names = set(z.namelist())
            if 'manifest.json' not in names or 'komikku.db' not in names:
                raise ValueError(_t('Bu dosya bir Komikku yedeği değil', 'This file is not a Komikku backup'))
            manifest = json.loads(z.read('manifest.json'))
            if manifest.get('format', 0) > FORMAT:
                raise ValueError(_t('Yedek, bu sürümden daha yeni bir Komikku ile alınmış', 'The backup was made by a newer Komikku'))
            for name in ('komikku.db', 'settings.json'):
                if name in names:
                    with z.open(name) as src, open(os.path.join(pending, name), 'wb') as dst:
                        shutil.copyfileobj(src, dst)
            prefs = json.loads(z.read('app-preferences.json')) if 'app-preferences.json' in names else {}
        if not _check(os.path.join(pending, 'komikku.db')):
            raise ValueError(_t('Yedekteki veritabanı bozuk', 'The database in the backup is damaged'))
    except Exception:
        shutil.rmtree(pending, ignore_errors=True)
        raise
    return {'manifest': manifest, 'app_preferences': prefs}


def apply_pending_restore():
    """Called at startup, before the database is opened."""
    try:
        data_dir, db_path, settings_path = _paths()
    except Exception:
        logger.exception('Restore: cannot resolve paths')
        return
    pending = os.path.join(data_dir, PENDING)
    staged_db = os.path.join(pending, 'komikku.db')
    if not os.path.exists(staged_db):
        return
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    if os.path.exists(db_path):
        shutil.copyfile(db_path, f'{db_path}.before-restore-{stamp}')
    for suffix in ('-wal', '-shm'):
        if os.path.exists(db_path + suffix):
            os.remove(db_path + suffix)
    os.replace(staged_db, db_path)
    staged_settings = os.path.join(pending, 'settings.json')
    if os.path.exists(staged_settings):
        if os.path.exists(settings_path):
            shutil.copyfile(settings_path, f'{settings_path}.before-restore-{stamp}')
        os.replace(staged_settings, settings_path)
    shutil.rmtree(pending, ignore_errors=True)
    logger.info('Backup restored (previous database kept as *.before-restore-%s)', stamp)
