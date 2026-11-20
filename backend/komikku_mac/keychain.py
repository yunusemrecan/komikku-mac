# SPDX-License-Identifier: GPL-3.0-or-later
"""
Server credentials in the macOS Keychain.

Upstream's KeyringHelper targets the freedesktop Secret Service (attributes per
item) and otherwise falls back to a plaintext JSON file. On macOS we store one
Keychain item per server: service "info.febvre.Komikku:<server main id>",
account "credentials", secret = JSON {username, password, address}.

Off macOS (tests, Linux dev runs) upstream's plaintext fallback is used.
"""

import json
import logging
import sys

logger = logging.getLogger('komikku_mac.keychain')

APPID = 'info.febvre.Komikku'
ACCOUNT = 'credentials'


def _mac_backend():
    if sys.platform != 'darwin':
        return None
    try:
        from keyring.backends import macOS
        backend = macOS.Keyring()
        return backend
    except Exception as exc:  # pragma: no cover - macOS only
        logger.warning('macOS Keychain unavailable: %s', exc)
        return None


def install():
    from komikku.models import keyring as upstream

    backend = _mac_backend()
    plaintext = upstream.PlaintextKeyring()

    def get(self, service):
        if backend is not None:
            try:
                secret = backend.get_password(f'{APPID}:{service}', ACCOUNT)
            except Exception as exc:
                logger.warning('Keychain read failed for %s: %s', service, exc)
                secret = None
            if not secret:
                return None
            data = json.loads(secret)
            return upstream.CustomCredential(data.get('username'), data.get('password'), data.get('address'))

        credential = plaintext.get_credential(service, None)
        if credential is None or credential.username is None:
            return None
        return credential

    def store(self, service, username, password, address=None):
        if backend is not None:
            secret = json.dumps({'username': username, 'password': password, 'address': address})
            backend.set_password(f'{APPID}:{service}', ACCOUNT, secret)
            return
        plaintext.set_password(service, username, password, address)

    def delete(self, service):
        if backend is not None:
            try:
                backend.delete_password(f'{APPID}:{service}', ACCOUNT)
            except Exception:
                pass
            return
        data = plaintext._read()
        if service in data:
            del data[service]
            plaintext._save(data)

    def init(self, fallback_keyring='plaintext'):  # noqa: ARG001
        pass

    upstream.KeyringHelper.__init__ = init
    upstream.KeyringHelper.get = get
    upstream.KeyringHelper.store = store
    upstream.KeyringHelper.delete = delete
    upstream.KeyringHelper.is_disabled = property(lambda self: False)
    upstream.KeyringHelper.has_recommended_backend = property(lambda self: backend is not None)
