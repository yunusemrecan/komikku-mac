# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

import importlib
import inspect
import logging
from pkgutil import iter_modules
import sys

logger = logging.getLogger(__name__)


def get_translators_classes(include_disabled=False):
    translators = {}
    for module in get_translators_modules():
        for name, obj in dict(inspect.getmembers(module)).items():
            if not hasattr(obj, 'id') or not hasattr(obj, 'name'):
                continue
            if NotImplemented in (obj.id, obj.name):
                continue

            if not include_disabled and obj.status == 'disabled':
                continue

            if inspect.isclass(obj):
                translators[obj.id] = obj

    return translators


def get_translators_modules():
    def import_modules(namespace, modules, modules_names):
        count = 0
        for _finder, module_name, ispkg in iter_namespace(namespace):
            if module_name in modules_names or ispkg:
                continue

            module = importlib.import_module(module_name)
            modules.append(module)
            modules_names.append(module_name)
            count += 1

        if count > 0:
            logger.info('Import {0} translators modules'.format(count))

        return count

    def iter_namespace(ns_pkg):
        # Specifying the second argument (prefix) to iter_modules makes the
        # returned name an absolute name instead of a relative one. This allows
        # import_module to work without having to do additional modification to
        # the name.
        return iter_modules(ns_pkg.__path__, ns_pkg.__name__ + '.')

    modules = []
    modules_names = []
    for finder in sys.meta_path:
        import komikku.translators.providers

        import_modules(komikku.translators.providers, modules, modules_names)

    return modules
