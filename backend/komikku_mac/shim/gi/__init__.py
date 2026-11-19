# SPDX-License-Identifier: GPL-3.0-or-later
"""
Minimal stand-in for PyGObject on macOS.

Upstream Komikku imports GTK/GLib everywhere, but the parts we run in the
backend (servers, database models, settings) only need a handful of GLib/Gio
behaviours. Those are implemented for real in `_glib.py` / `_gio.py`; every
other `gi.repository.*` name resolves to a permissive stub so that UI modules
can still be imported (their classes are defined but never instantiated).
"""

version_info = (3, 50, 0)


def require_version(namespace, version):  # noqa: ARG001
    pass


def require_versions(versions):  # noqa: ARG001
    pass
