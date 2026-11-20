# SPDX-License-Identifier: GPL-3.0-or-later
"""
Upstream's Downloader and Updater, run headless.

Both classes only need a `window` exposing a few attributes and they report
progress through GObject signals. Here a stand-in window forwards in-app and
desktop notifications to the Swift frontend, and `emit` is overridden to send
RPC notifications.
"""

import logging
import threading
import time

from komikku_mac import rpc

logger = logging.getLogger('komikku_mac.services')


def _download_dict(download):
    return {
        'id': download.id,
        'chapter_id': download.chapter_id,
        'status': download.status,
        'percent': download.percent,
        'errors': download.errors,
    }


class _Application:
    def send_notification(self, notification_id, notification):
        rpc.notify('app.notification', {
            'id': notification_id,
            'title': getattr(notification, 'title', ''),
            'body': getattr(notification, 'body', None),
        })

    def withdraw_notification(self, *_args):
        pass


class _Window:
    network_available = True

    def __init__(self):
        self.application = _Application()
        self.downloader = None
        self.updater = None

    def add_notification(self, message, timeout=None, priority=None, **_kwargs):  # noqa: ARG002
        rpc.notify('app.toast', {'message': message})

    def open_server_bug_report_dialog(self, *_args, **_kwargs):
        pass


window = _Window()


def _make_classes():
    from komikku.downloader import Downloader
    from komikku.updater import Updater

    class MacDownloader(Downloader):
        def emit(self, signal, *args):
            if signal == 'download-changed':
                download, chapter = args
                if download is not None:
                    rpc.notify('downloads.changed', _download_dict(download))
                elif chapter is not None:
                    rpc.notify('downloads.removed', {
                        'chapter_id': chapter.id,
                        'manga_id': chapter.manga_id,
                        'downloaded': bool(chapter.downloaded),
                    })
            elif signal == 'started':
                rpc.notify('downloads.state', {'running': True})
            elif signal == 'ended':
                rpc.notify('downloads.state', {'running': False})
            return False

    class MacUpdater(Updater):
        def emit(self, signal, *args):
            if signal == 'manga-update-begin':
                manga = args[0]
                rpc.notify('updater.begin', {'manga_id': manga.id, 'name': manga.name})
            elif signal == 'manga-update-end':
                manga, changes, _synced = args
                rpc.notify('updater.end', {'manga_id': manga.id, **changes})
            return False

        def start(self):
            started = super().start()
            if started:
                # Upstream has no "finished" signal: watch the worker flag
                def watch():
                    while self.running:
                        time.sleep(0.5)
                    rpc.notify('updater.finished', {})
                threading.Thread(target=watch, daemon=True).start()
            return started

    return MacDownloader, MacUpdater


def init():
    MacDownloader, MacUpdater = _make_classes()
    window.downloader = MacDownloader(window)
    window.updater = MacUpdater(window)
    return window
