#! /usr/bin/env python3

# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

import glob
import hashlib
import importlib
import inspect
import json
import os
import sys

from gi.repository import Gio

sys.path.append('./')

resource = Gio.Resource.load(os.path.join('_build/testdir/share/komikku', 'info.febvre.KomikkuDevel.gresource'))
resource._register()

dirpath = 'komikku/servers'

# Extract minimum app version to use modules
with open(os.path.join(dirpath, '__init__.py')) as fp:
    for line in fp.readlines():
        if line.startswith('APP_MIN_VERSION'):
            app_min_version = line.split()[2].strip().replace("'", '')
            if app_min_version == 'None':
                app_min_version = None
            break

data = {
    'app_min_version': app_min_version,
    'modules': {},
}

# Walk in servers folder
for pathname in ('komikku/servers/multi/*/', 'komikku/servers/*/'):
    for module_path in glob.glob(pathname):
        if module_path.endswith(('multi/', '__pycache__/')):
            continue

        with open(os.path.join(module_path, '__init__.py'), 'r') as fp:
            hash = hashlib.sha256(fp.read().encode()).hexdigest()

        id = '-'.join(module_path.split('/')[2:-1])
        module_info = {
            'path': module_path.replace(dirpath, '')[1:],
            'files': [],
            'languages': None,
            'hash': hash,
        }
        for file in glob.glob(f'{module_path}/*'):
            name = os.path.basename(file)
            if name == '__pycache__':
                continue
            module_info['files'].append(os.path.basename(file))

        if not id.startswith('multi-'):
            # Compute module languages
            module_info['languages'] = set()
            try:
                module = importlib.import_module(f'.{id}', package='komikku.servers')
                for name, obj in inspect.getmembers(module):
                    if inspect.isclass(obj) and 'servers.' in obj.__module__:
                        c = getattr(module, name)
                        if hasattr(c, 'lang'):
                            if c.status == 'disabled':
                                continue
                            module_info['languages'].add(c.lang)
            except Exception as e:
                print('Failed to get server languages', id, e)

            if not module_info['languages']:
                # Skip disabled module
                continue

            module_info['languages'] = sorted(list(module_info['languages']))
            if module_info['languages'] == ['']:
                # Server has no specific languages: a self-hosted digital library or local
                module_info['languages'] = None

        data['modules'][id] = module_info

with open(os.path.join(dirpath, 'index.json'), 'w+') as fp:
    json.dump(data, fp, indent=2)
