# SPDX-License-Identifier: GPL-3.0-or-later
"""Partial GLib implementation: user dirs (macOS layout), Variant, timeouts."""

import os
import sys
import tempfile
import threading

from gi._stub import make_stub

SOURCE_REMOVE = False
SOURCE_CONTINUE = True
PRIORITY_DEFAULT = 0
PRIORITY_DEFAULT_IDLE = 200
PRIORITY_HIGH = -100
PRIORITY_LOW = 300


def _home():
    # KOMIKKU_MAC_HOME lets tests (and Linux dev runs) use a scratch directory
    return os.environ.get('KOMIKKU_MAC_HOME') or os.path.expanduser('~')


def _ensure(path):
    os.makedirs(path, exist_ok=True)
    return path


def _is_macos():
    return sys.platform == 'darwin' and not os.environ.get('KOMIKKU_MAC_HOME')


def get_user_data_dir():
    if _is_macos():
        return _ensure(os.path.join(_home(), 'Library', 'Application Support'))
    return _ensure(os.path.join(_home(), '.local', 'share'))


def get_user_config_dir():
    if _is_macos():
        return _ensure(os.path.join(_home(), 'Library', 'Preferences'))
    return _ensure(os.path.join(_home(), '.config'))


def get_user_cache_dir():
    if _is_macos():
        return _ensure(os.path.join(_home(), 'Library', 'Caches'))
    return _ensure(os.path.join(_home(), '.cache'))


def get_user_runtime_dir():
    return _ensure(os.path.join(tempfile.gettempdir(), 'komikku-runtime'))


def get_home_dir():
    return _home()


def get_tmp_dir():
    return tempfile.gettempdir()


def get_user_special_dir(_directory):
    return os.path.join(_home(), 'Downloads')


def get_application_name():
    return 'Komikku'


def get_prgname():
    return 'komikku'


def markup_escape_text(text, length=-1):  # noqa: ARG001
    return (
        text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        .replace('"', '&quot;').replace("'", '&#x27;')
    )


class GError(Exception):
    pass


Error = GError


class Bytes(bytes):
    @classmethod
    def new(cls, data):
        return cls(data)

    def get_data(self):
        return bytes(self)

    def get_size(self):
        return len(self)


class Variant:
    """Just enough of GLib.Variant for Gio.Settings set_value/get_value."""

    def __init__(self, type_string, value):
        self._type = type_string
        if type_string.startswith('a') and value is not None:
            value = list(value)
        self._value = value

    def unpack(self):
        return self._value

    def get_type_string(self):
        return self._type

    def __iter__(self):
        return iter(self._value)

    def __len__(self):
        return len(self._value)

    def __getitem__(self, index):
        return self._value[index]

    def __eq__(self, other):
        if isinstance(other, Variant):
            return self._value == other._value
        return self._value == other

    def __repr__(self):
        return f'GLib.Variant({self._type!r}, {self._value!r})'

    # Typed getters used occasionally by upstream code
    def get_boolean(self):
        return bool(self._value)

    def get_int32(self):
        return int(self._value)

    get_int64 = get_int32

    def get_double(self):
        return float(self._value)

    def get_string(self):
        return str(self._value)

    def get_strv(self):
        return list(self._value)


_sources = {}
_sources_lock = threading.Lock()
_next_source_id = 1


def _schedule(delay_ms, function, args):
    global _next_source_id

    with _sources_lock:
        source_id = _next_source_id
        _next_source_id += 1

    def run():
        with _sources_lock:
            if source_id not in _sources:
                return
        try:
            again = function(*args)
        except Exception:  # pragma: no cover - mirrors GLib which logs and drops
            import logging
            logging.getLogger('komikku_mac').exception('GLib source %s failed', source_id)
            again = False
        if again:
            start()
        else:
            with _sources_lock:
                _sources.pop(source_id, None)

    def start():
        timer = threading.Timer(delay_ms / 1000, run)
        timer.daemon = True
        with _sources_lock:
            _sources[source_id] = timer
        timer.start()

    start()
    return source_id


def timeout_add(interval, function, *args, **_kwargs):
    return _schedule(interval, function, args)


def timeout_add_seconds(interval, function, *args, **_kwargs):
    return _schedule(interval * 1000, function, args)


def idle_add(function, *args, **_kwargs):
    return _schedule(0, function, args)


def source_remove(source_id):
    with _sources_lock:
        timer = _sources.pop(source_id, None)
    if timer is not None:
        timer.cancel()
        return True
    return False


def __getattr__(name):
    if name.startswith('__'):
        raise AttributeError(name)
    return make_stub(f'GLib.{name}')
