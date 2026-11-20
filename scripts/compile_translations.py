# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile upstream Komikku .po files into gettext .mo catalogs.

    compile_translations.py <po_dir> <locale_dir>
"""

import os
import sys

import polib


def main(po_dir, locale_dir):
    count = 0
    for name in sorted(os.listdir(po_dir)):
        if not name.endswith('.po'):
            continue
        lang = name[:-3]
        target = os.path.join(locale_dir, lang, 'LC_MESSAGES')
        os.makedirs(target, exist_ok=True)
        polib.pofile(os.path.join(po_dir, name)).save_as_mofile(os.path.join(target, 'komikku.mo'))
        count += 1
    print(f'{count} catalogs compiled into {locale_dir}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
