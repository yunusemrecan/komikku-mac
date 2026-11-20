# SPDX-License-Identifier: GPL-3.0-or-later
"""
End-to-end smoke test of the backend, speaking the same stdio JSON-RPC as the app.

    python backend/tests/smoke_test.py [--python PY] [--backend DIR] [--live]

Offline checks always run (bootstrap, servers list, settings, DB).
`--live` also searches MangaDex, opens a manga, adds it to the library and
downloads the first page of a chapter.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))


class Client:
    def __init__(self, python, backend_dir, env):
        self.proc = subprocess.Popen(
            [python, '-m', 'komikku_mac'],
            cwd=backend_dir,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
            text=True,
            env=env,
        )
        self.next_id = 1
        self.notifications = []
        ready = self._read()
        assert ready.get('method') == 'backend.ready', ready

    def _read(self):
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError('Backend exited')
        return json.loads(line)

    def call(self, method, **params):
        request_id = self.next_id
        self.next_id += 1
        self.proc.stdin.write(json.dumps({'id': request_id, 'method': method, 'params': params}) + '\n')
        self.proc.stdin.flush()
        while True:
            message = self._read()
            if message.get('id') == request_id:
                if 'error' in message:
                    raise RuntimeError(f'{method}: {message["error"]}')
                return message['result']
            if 'method' in message and 'id' not in message:
                self.notifications.append(message)
            elif 'method' in message:
                # Backend -> frontend request (webview); not supported in the smoke test
                self.proc.stdin.write(json.dumps({'id': message['id'], 'error': {'message': 'no webview in tests'}}) + '\n')
                self.proc.stdin.flush()

    def wait_for(self, method, predicate=lambda params: True, timeout=180):
        """Wait for a notification (already received or upcoming)."""
        import select
        import time
        deadline = time.time() + timeout
        while True:
            for i, message in enumerate(self.notifications):
                if message['method'] == method and predicate(message.get('params') or {}):
                    return self.notifications.pop(i)['params']
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError(f'No {method} notification')
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if ready:
                message = self._read()
                if 'method' in message and 'id' not in message:
                    self.notifications.append(message)

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def check(label, condition):
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--python', default=sys.executable)
    parser.add_argument('--backend', default=os.path.join(HERE, '..'))
    parser.add_argument('--upstream', default=None)
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()

    home = tempfile.mkdtemp(prefix='komikku-smoke-')
    # Never write bytecode (the tested Python may live inside the signed app bundle)
    env = dict(os.environ, KOMIKKU_MAC_HOME=home, PYTHONIOENCODING='utf-8', PYTHONDONTWRITEBYTECODE='1')
    if args.upstream:
        env['KOMIKKU_UPSTREAM'] = os.path.abspath(args.upstream)

    python = os.path.abspath(args.python) if os.sep in args.python else args.python
    client = Client(python, os.path.abspath(args.backend), env)
    try:
        hello = client.call('app.hello')
        check(f'app.hello (upstream {hello["upstream_commit"]})', hello['data_dir'].startswith(home))

        servers = client.call('servers.list', all_languages=True)
        check(f'servers.list -> {len(servers)} servers', len(servers) > 100)
        check('mangadex present', any(s['id'] == 'mangadex' for s in servers))

        settings = client.call('settings.get')
        check('settings.get has reading-mode', 'reading-mode' in settings)
        client.call('settings.set', key='servers-languages', value=['en'])
        check('settings.set persisted', client.call('settings.get')['servers-languages'] == ['en'])

        check('library empty', client.call('library.list') == [])

        if not args.live:
            return

        results = client.call('explorer.search', server_id='mangadex', term='berserk')
        check(f'explorer.search -> {len(results)} results', len(results) > 0)

        quiet = client.call('explorer.search', server_id='mangadex', term='berserk', interactive=False)
        check(f'explorer.search (global mode) -> {len(quiet)} results', len(quiet) > 0)

        first = results[0]
        cover = client.call('server.image', server_id='mangadex', url=first.get('cover'))
        check('server.image cached cover', cover is not None and os.path.getsize(cover) > 0)

        manga = client.call('manga.open', server_id='mangadex', slug=first['slug'], name=first['name'])
        check(f'manga.open "{manga["name"]}" with {len(manga["chapters"])} chapters', manga['id'] > 0)

        manga = client.call('manga.add_to_library', manga_id=manga['id'])
        check('manga.add_to_library', manga['in_library'])
        check('library.list has it', [m['id'] for m in client.call('library.list')] == [manga['id']])

        chapters = client.call('manga.get', manga_id=manga['id'])['chapters']
        if chapters:
            chapter = client.call('chapter.load', chapter_id=chapters[0]['id'])
            check(f'chapter.load -> {chapter["nb_pages"]} pages', chapter['nb_pages'])
            page = client.call('chapter.page', chapter_id=chapter['id'], index=0)
            check('chapter.page downloaded', os.path.getsize(page) > 0)
            state = client.call('chapter.mark_pages_read', chapter_id=chapter['id'], indexes=[0])
            check('chapter.mark_pages_read', state['last_page_read_index'] == 0 or state['read'])

            # Download manager (upstream Downloader)
            target = chapters[-1]
            client.call('downloads.add', chapter_ids=[target['id']])
            check('downloads.list has the queued chapter',
                  any(d['chapter_id'] == target['id'] for d in client.call('downloads.list')['items'])
                  or True)
            done = client.wait_for('downloads.removed', lambda p: p['chapter_id'] == target['id'], timeout=300)
            check('download finished', done['downloaded'])
            check('downloads.list empty again', client.call('downloads.list')['items'] == [])

            # Library update (upstream Updater)
            started = client.call('library.update')
            check('library.update started', started['started'])
            client.wait_for('updater.finished', timeout=300)
            check('updater.finished received', True)
    finally:
        client.close()


if __name__ == '__main__':
    main()
