# SPDX-License-Identifier: GPL-3.0-or-later
"""Permissive stand-ins for GTK/GObject types that are never used at runtime."""

import types

_cache = {}


class _StubMeta(type):
    def __getattr__(cls, name):
        if name.startswith('__') and name.endswith('__'):
            raise AttributeError(name)
        return make_stub(f'{cls.__qualname__}.{name}')

    def __or__(cls, other):
        return cls

    __ror__ = __or__


class Stub(metaclass=_StubMeta):
    """Can be subclassed, instantiated, called and used as a decorator."""

    def __init__(self, *args, **kwargs):
        pass

    def __init_subclass__(cls, **kwargs):
        # GObject subclasses may pass keyword args (e.g. `Gtk.Widget, Gtk.Buildable`)
        pass

    def __getattr__(self, name):
        if name.startswith('__') and name.endswith('__'):
            raise AttributeError(name)
        return make_stub(f'{type(self).__qualname__}.{name}')

    def __call__(self, *args, **kwargs):
        # Used as decorator: `@Gtk.Template(...)`, `@GObject.Property(...)`
        if len(args) == 1 and not kwargs and callable(args[0]):
            return args[0]
        return type(self)()

    def __bool__(self):
        return False

    def __or__(self, other):
        return self

    __ror__ = __or__

    def __iter__(self):
        return iter(())


def make_stub(qualname):
    stub = _cache.get(qualname)
    if stub is None:
        stub = _StubMeta(qualname.rsplit('.', 1)[-1], (Stub,), {'__qualname__': qualname})
        _cache[qualname] = stub
    return stub


class StubModule(types.ModuleType):
    def __getattr__(self, name):
        if name.startswith('__') and name.endswith('__'):
            raise AttributeError(name)
        value = make_stub(f'{self.__name__.rsplit(".", 1)[-1]}.{name}')
        setattr(self, name, value)
        return value
