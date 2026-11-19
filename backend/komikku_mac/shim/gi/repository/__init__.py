# SPDX-License-Identifier: GPL-3.0-or-later
"""
`gi.repository` namespace: GLib and Gio get real (partial) implementations,
every other namespace is a stub module created on demand.
"""

import importlib
import importlib.abc
import importlib.util
import sys

from gi._stub import StubModule

_REAL = {
    'GLib': 'gi._glib',
    'Gio': 'gi._gio',
}


class _Loader(importlib.abc.Loader):
    def create_module(self, spec):
        name = spec.name.rsplit('.', 1)[-1]
        if name in _REAL:
            real = importlib.import_module(_REAL[name])
            # Real implementations still fall back to stubs for unknown attributes
            return real
        return StubModule(spec.name)

    def exec_module(self, module):
        pass


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if not fullname.startswith('gi.repository.'):
            return None
        rest = fullname[len('gi.repository.'):]
        if '.' in rest:
            # e.g. `gi.repository.GdkPixbuf.Pixbuf` is never imported as module
            return None
        return importlib.util.spec_from_loader(fullname, _Loader())


if not any(isinstance(f, _Finder) for f in sys.meta_path):
    sys.meta_path.insert(0, _Finder())


def __getattr__(name):
    if name.startswith('__'):
        raise AttributeError(name)
    module = importlib.import_module(f'{__name__}.{name}')
    globals()[name] = module
    return module
