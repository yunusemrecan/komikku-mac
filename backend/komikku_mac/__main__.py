# SPDX-License-Identifier: GPL-3.0-or-later
"""Entry point: `python -m komikku_mac` — JSON-RPC server on stdio."""

import logging
import os
import sys


def main():
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.DEBUG if os.environ.get('KOMIKKU_DEBUG') else logging.INFO,
        format='%(asctime)s %(levelname)s %(name)s: %(message)s',
    )

    from komikku_mac.bootstrap import bootstrap
    bootstrap()

    from komikku.models import init_db
    init_db()

    from komikku_mac import api  # registers RPC methods
    from komikku_mac import rpc
    rpc.serve()

    # stdin closed: the app is quitting
    api.clear_cache_on_exit_if_enabled()


if __name__ == '__main__':
    main()
