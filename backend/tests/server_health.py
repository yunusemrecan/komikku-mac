# SPDX-License-Identifier: GPL-3.0-or-later
"""
Weekly server health check (CI): for every (non-NSFW) server, fetch the latest /
popular list and open the first manga, through the same JSON-RPC API as the app.

    python backend/tests/server_health.py --json OUT.json --markdown OUT.md [--previous PREV.json]

Servers that need a browser check (Cloudflare & co.) cannot be tested here (no
web view on Linux) and are reported separately, not as broken.
"""

import argparse
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TIMEOUT = 90          # seconds per request
PARALLEL = 24


class AsyncClient:
    def __init__(self, python, backend_dir, env):
        self.proc = subprocess.Popen([python, '-m', 'komikku_mac'], cwd=backend_dir, env=env, text=True,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.lock = threading.Lock()
        self.next_id = 1
        self.waiting = {}
        assert json.loads(self.proc.stdout.readline()).get('method') == 'backend.ready'
        threading.Thread(target=self._reader, daemon=True).start()

    def _send(self, message):
        with self.lock:
            self.proc.stdin.write(json.dumps(message) + '\n')
            self.proc.stdin.flush()

    def _reader(self):
        for line in self.proc.stdout:
            message = json.loads(line)
            if 'id' in message and 'method' in message:
                # backend -> frontend request (web view for a browser check): not available here
                self._send({'id': message['id'], 'error': {'code': 'no_webview', 'message': 'browser check needed'}})
            elif 'id' in message:
                box = self.waiting.pop(message['id'], None)
                if box:
                    box.put(message)

    def call(self, method, **params):
        with self.lock:
            request_id = self.next_id
            self.next_id += 1
        box = queue.Queue()
        self.waiting[request_id] = box
        self._send({'id': request_id, 'method': method, 'params': params})
        try:
            message = box.get(timeout=TIMEOUT)
        except queue.Empty:
            self.waiting.pop(request_id, None)
            raise TimeoutError(f'{method}: no answer in {TIMEOUT}s')
        if 'error' in message:
            error = message['error']
            raise RuntimeError(error.get('message') if isinstance(error, dict) else str(error))
        return message['result']

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=20)
        except Exception:
            self.proc.kill()


def classify(error):
    text = str(error).lower()
    if any(k in text for k in ('browser check', 'challenge', 'webview', 'cloudflare', 'captcha')):
        return 'challenge'
    if isinstance(error, TimeoutError) or 'timed out' in text or 'timeout' in text:
        return 'timeout'
    return 'error'


def check_server(client, server):
    started = time.time()
    result = {'id': server['id'], 'name': server['name'], 'lang': server['lang']}
    try:
        if server.get('has_latest'):
            items, source = client.call('explorer.latest', server_id=server['id']), 'latest'
        elif server.get('has_popular'):
            items, source = client.call('explorer.popular', server_id=server['id']), 'popular'
        else:
            items, source = client.call('explorer.search', server_id=server['id'], term='one', interactive=False), 'search'
        result['list'] = source
        result['results'] = len(items or [])
        if not items:
            result['status'] = 'empty'
        else:
            first = items[0]
            manga = client.call('manga.open', server_id=server['id'], slug=first['slug'], name=first.get('name'),
                                url=first.get('url'), cover=first.get('cover'))
            result['chapters'] = len(manga.get('chapters') or [])
            result['status'] = 'ok' if result['chapters'] else 'no_chapters'
    except Exception as error:  # noqa: BLE001 - every failure is a finding
        result['status'] = classify(error)
        result['error'] = str(error).splitlines()[0][:160] if str(error) else type(error).__name__
    result['seconds'] = round(time.time() - started, 1)
    return result


LABELS = {
    'ok': '✅ çalışıyor', 'no_chapters': '⚠️ bölüm yok', 'empty': '⚠️ liste boş',
    'challenge': '🛡️ tarayıcı doğrulaması (CI\'da denenemez)', 'timeout': '⏱️ zaman aşımı', 'error': '❌ hata',
}


def markdown(results, previous, upstream):
    counts = {}
    for r in results:
        counts[r['status']] = counts.get(r['status'], 0) + 1
    prev = {r['id']: r['status'] for r in previous}
    broken = ('error', 'timeout', 'empty', 'no_chapters')
    newly = [r for r in results if r['status'] in broken and prev.get(r['id']) == 'ok']
    fixed = [r for r in results if r['status'] == 'ok' and prev.get(r['id']) in broken]
    lines = [
        f'Upstream Komikku `{upstream}` · {time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())} · '
        f'{len(results)} sunucu (yetişkin içerikliler ve kendi sunucunu kurduğun Komga/Kavita gibileri hariç)',
        '',
        '| Durum | Sunucu |', '|---|---|',
    ]
    for status in ('ok', 'no_chapters', 'empty', 'challenge', 'timeout', 'error'):
        if counts.get(status):
            lines.append(f'| {LABELS[status]} | {counts[status]} |')
    if previous:
        lines += ['', f'**Geçen haftadan beri bozulan:** {", ".join(r["name"] for r in newly) or "yok"}',
                  f'**Düzelen:** {", ".join(r["name"] for r in fixed) or "yok"}']
    problems = sorted((r for r in results if r['status'] in broken), key=lambda r: (r['status'], r['name'].lower()))
    if problems:
        lines += ['', '### Sorunlu sunucular', '', '| Sunucu | Dil | Durum | Ayrıntı |', '|---|---|---|---|']
        for r in problems:
            detail = (r.get('error') or '').replace('|', '\\|')
            lines.append(f'| {r["name"]} (`{r["id"]}`) | {r["lang"] or "çok dilli"} | {LABELS[r["status"]]} | {detail} |')
    challenged = sorted(r['name'] for r in results if r['status'] == 'challenge')
    if challenged:
        lines += ['', f'<details><summary>Tarayıcı doğrulaması isteyenler ({len(challenged)})</summary>', '',
                  ', '.join(challenged), '</details>']
    lines += ['', 'Sorunlu bir sunucu çoğu zaman upstream\'de (Komikku) düzeltilir; haftalık upstream '
              'güncellemesi bunu otomatik getirir.']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--python', default=sys.executable)
    parser.add_argument('--backend', default=os.path.join(HERE, '..'))
    parser.add_argument('--json', required=True)
    parser.add_argument('--markdown', required=True)
    parser.add_argument('--previous')
    parser.add_argument('--only', help='comma-separated server ids (for testing)')
    args = parser.parse_args()

    home = tempfile.mkdtemp(prefix='komikku-health-')
    env = dict(os.environ, KOMIKKU_MAC_HOME=home, PYTHONIOENCODING='utf-8', PYTHONDONTWRITEBYTECODE='1',
               KOMIKKU_LANG='en')
    client = AsyncClient(args.python, os.path.abspath(args.backend), env)
    upstream = client.call('app.hello')['upstream_commit']
    # Self-hosted servers (Komga, Kavita, Suwayomi…) and the local library need the user's own address
    servers = [s for s in client.call('servers.list', all_languages=True)
               if not s.get('is_nsfw') and s.get('base_url') and s['id'] != 'local']
    if args.only:
        wanted = set(args.only.split(','))
        servers = [s for s in servers if s['id'] in wanted]

    results = []
    pending = list(servers)
    lock = threading.Lock()

    def worker():
        while True:
            with lock:
                if not pending:
                    return
                server = pending.pop()
            r = check_server(client, server)
            print(f'{r["status"]:12} {r["seconds"]:6}s {server["id"]} {r.get("error", "")}', flush=True)
            with lock:
                results.append(r)

    threads = [threading.Thread(target=worker) for _ in range(PARALLEL)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    client.close()

    results.sort(key=lambda r: r['name'].lower())
    previous = []
    if args.previous and os.path.exists(args.previous):
        with open(args.previous) as f:
            previous = json.load(f)
    with open(args.json, 'w') as f:
        json.dump(results, f, ensure_ascii=False, indent=1)
    with open(args.markdown, 'w') as f:
        f.write(markdown(results, previous, upstream))
    ok = sum(r['status'] == 'ok' for r in results)
    print(f'{ok}/{len(results)} servers ok')


if __name__ == '__main__':
    main()
