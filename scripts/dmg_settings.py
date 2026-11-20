# SPDX-License-Identifier: GPL-3.0-or-later
# dmgbuild settings: drag-to-Applications window.
#   dmgbuild -s scripts/dmg_settings.py -D app=dist/Komikku.app -D root=. "Komikku" dist/Komikku.dmg

import os.path

application = defines['app']  # noqa: F821  (injected by dmgbuild)
root = defines['root']  # noqa: F821
appname = os.path.basename(application)

format = 'UDZO'
filesystem = 'APFS'   # HFS+ rewrites some file names and breaks the app's code signature
compression_level = 9

files = [application]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(application, 'Contents', 'Resources', 'AppIcon.icns')

background = os.path.join(root, 'app', 'Resources', 'dmg', 'background.png')
window_rect = ((200, 120), (660, 422))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
icon_locations = {
    appname: (170, 190),
    'Applications': (490, 190),
}
