# SPDX-License-Identifier: GPL-3.0-or-later
"""
Partial Gio implementation.

- `Gio.Settings`: backed by a JSON file, defaults/enums read from upstream's
  GSettings schema (data/info.febvre.Komikku.gschema.xml.in).
- `Gio.Application.get_default()`: a plain object exposing `application_id`
  and `profile`, which is all the backend-side upstream code reads.
"""

import ast
import json
import mimetypes
import os
import threading
import xml.etree.ElementTree as ET

from gi import _glib as GLib
from gi._stub import make_stub

APPLICATION_ID = 'info.febvre.Komikku'

# Set by komikku_mac.bootstrap before upstream modules are imported
SCHEMA_PATH = None
SETTINGS_PATH = None


class Application:
    _default = None

    def __init__(self, application_id=APPLICATION_ID, profile='stable'):
        self.application_id = application_id
        self.profile = profile
        self.window = None

    @classmethod
    def get_default(cls):
        if cls._default is None:
            cls._default = cls()
        return cls._default


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

def _parse_gvariant_text(text, type_string):
    text = text.strip()
    # Typed literals like `@as []`
    if text.startswith('@'):
        text = text.split(' ', 1)[1]
    if type_string == 'b':
        return text == 'true'
    text = text.replace('true', 'True').replace('false', 'False')
    value = ast.literal_eval(text)
    if type_string.startswith('a'):
        return list(value)
    if type_string == 'd':
        return float(value)
    if type_string in ('i', 'u', 'x', 't'):
        return int(value)
    return value


class _Schema:
    def __init__(self, path):
        self.keys = {}    # name -> dict(type, default, enum)
        self.enums = {}   # enum id -> {nick: value}

        tree = ET.parse(path)
        root = tree.getroot()
        for enum in root.iter('enum'):
            self.enums[enum.get('id')] = {v.get('nick'): int(v.get('value')) for v in enum.iter('value')}

        for schema in root.iter('schema'):
            for key in schema.iter('key'):
                default_el = key.find('default')
                default_text = default_el.text if default_el is not None else None
                enum_id = key.get('enum')
                if enum_id:
                    default = ast.literal_eval(default_text.strip()) if default_text else None
                    self.keys[key.get('name')] = dict(type='enum', default=default, enum=enum_id)
                else:
                    type_string = key.get('type')
                    default = _parse_gvariant_text(default_text, type_string) if default_text else None
                    self.keys[key.get('name')] = dict(type=type_string, default=default, enum=None)


class Settings:
    _schema = None
    _store = None
    _lock = threading.RLock()

    def __init__(self, *args, **kwargs):  # noqa: ARG002
        pass

    @classmethod
    def new(cls, schema_id=APPLICATION_ID):  # noqa: ARG003
        return cls()

    # -- storage --------------------------------------------------------------

    # State lives on the base class: upstream subclasses it (`komikku.models.Settings`)
    # and both must share one store.
    @staticmethod
    def _load():
        if Settings._schema is None:
            if SCHEMA_PATH is None:
                raise RuntimeError('Gio shim: SCHEMA_PATH not configured')
            Settings._schema = _Schema(SCHEMA_PATH)
        if Settings._store is None:
            store = {}
            if SETTINGS_PATH and os.path.exists(SETTINGS_PATH):
                try:
                    with open(SETTINGS_PATH) as fp:
                        store = json.load(fp)
                except (OSError, ValueError):
                    store = {}
            Settings._store = store
        return Settings._schema, Settings._store

    @staticmethod
    def _save():
        if not SETTINGS_PATH:
            return
        tmp = SETTINGS_PATH + '.tmp'
        with open(tmp, 'w') as fp:
            json.dump(Settings._store, fp, indent=2, sort_keys=True)
        os.replace(tmp, SETTINGS_PATH)

    def _key(self, key):
        schema, _store = self._load()
        if key not in schema.keys:
            raise KeyError(f'Unknown settings key: {key}')
        return schema.keys[key]

    def _get_raw(self, key):
        info = self._key(key)
        with Settings._lock:
            return Settings._store.get(key, info['default'])

    def _set_raw(self, key, value):
        self._key(key)
        with Settings._lock:
            Settings._store[key] = value
            self._save()
        return True

    # -- typed accessors --------------------------------------------------------

    def get_boolean(self, key):
        return bool(self._get_raw(key))

    def set_boolean(self, key, value):
        return self._set_raw(key, bool(value))

    def get_int(self, key):
        return int(self._get_raw(key))

    def set_int(self, key, value):
        return self._set_raw(key, int(value))

    get_uint = get_int
    set_uint = set_int

    def get_double(self, key):
        return float(self._get_raw(key))

    def set_double(self, key, value):
        return self._set_raw(key, float(value))

    def get_string(self, key):
        info = self._key(key)
        value = self._get_raw(key)
        return value if info['type'] != 'enum' else value

    def set_string(self, key, value):
        return self._set_raw(key, str(value))

    def get_strv(self, key):
        return list(self._get_raw(key) or [])

    def set_strv(self, key, value):
        return self._set_raw(key, list(value))

    def get_enum(self, key):
        info = self._key(key)
        nick = self._get_raw(key)
        return Settings._schema.enums[info['enum']].get(nick, 0)

    def set_enum(self, key, value):
        info = self._key(key)
        for nick, enum_value in Settings._schema.enums[info['enum']].items():
            if enum_value == int(value):
                return self._set_raw(key, nick)
        return False

    def get_value(self, key):
        info = self._key(key)
        return GLib.Variant(info['type'] if info['type'] != 'enum' else 's', self._get_raw(key))

    def set_value(self, key, variant):
        value = variant.unpack() if isinstance(variant, GLib.Variant) else variant
        return self._set_raw(key, value)

    def get_default_value(self, key):
        info = self._key(key)
        return GLib.Variant(info['type'] if info['type'] != 'enum' else 's', info['default'])

    def reset(self, key):
        self._key(key)
        with Settings._lock:
            Settings._store.pop(key, None)
            self._save()

    # -- introspection for the frontend ----------------------------------------

    @staticmethod
    def dump():
        schema, store = Settings._load()
        return {name: store.get(name, info['default']) for name, info in schema.keys.items()}

    # GObject API used by upstream but meaningless here
    def bind(self, *args, **kwargs):
        pass

    def connect(self, *args, **kwargs):
        return 0

    def delay(self):
        pass

    def apply(self):
        pass


# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

def content_type_guess(filename=None, data=None):  # noqa: ARG001
    mime_type, _encoding = mimetypes.guess_type(filename or '')
    return mime_type or 'application/octet-stream', mime_type is None


def __getattr__(name):
    if name.startswith('__'):
        raise AttributeError(name)
    return make_stub(f'Gio.{name}')
