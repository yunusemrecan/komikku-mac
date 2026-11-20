# SPDX-License-Identifier: GPL-3.0-or-later
"""
Replacement for upstream `komikku.webview` (WebKitGTK).

Servers protected by Cloudflare & co. call `CompleteChallenge`, `get_page_html`,
`eval_js` or `get_page_resources`. Here these block the calling worker thread and
ask the Swift frontend, which drives a WKWebView, to do the browser work.
"""

import functools
import logging
import threading
from urllib.parse import urlsplit

import requests

logger = logging.getLogger('komikku_mac.webview')

try:
    from curl_cffi import requests as crequests
except Exception:
    crequests = None


_context = threading.local()


class ChallengeRequired(Exception):
    """Raised instead of showing a browser window when interaction is not allowed (global search)."""


class no_interaction:
    """Context manager: within it, challenges fail fast instead of opening a window."""

    def __enter__(self):
        _context.no_interaction = True

    def __exit__(self, *exc):
        _context.no_interaction = False


def _frontend(method, params, timeout=None):
    if method == 'webview.challenge' and getattr(_context, 'no_interaction', False):
        raise ChallengeRequired()
    from komikku_mac import rpc
    return rpc.call_frontend(method, params, timeout=timeout)


def _make_cookies(raw_cookies):
    return [
        requests.cookies.create_cookie(
            name=c['name'],
            value=c['value'],
            domain=c.get('domain') or '',
            path=c.get('path') or '/',
            expires=c.get('expires'),
            rest={'HttpOnly': c.get('http_only', False)},
            secure=c.get('secure', False),
        )
        for c in raw_cookies
    ]


class CompleteChallenge:
    """Same contract as upstream: re-run decorated method once the browser challenge is passed."""

    ALLOWED_METHODS = (
        'get_manga_data',
        'get_manga_chapter_data',
        'get_manga_chapter_page_image',
        'get_latest_updates',
        'get_most_populars',
        'search',
    )

    def __call__(self, func):
        assert func.__name__ in self.ALLOWED_METHODS, \
            f'@{self.__class__.__name__} decorator is not allowed on method `{func.__name__}`'

        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            from komikku.servers.exceptions import ChallengerError
            from komikku.servers.utils import get_session_cookies

            server = args[0]
            url = server.bypass_cf_url or server.base_url

            if not server.has_cf and not server.has_captcha:
                return func(*args, **kwargs)

            if server.has_cf and not server.has_captcha:
                if server.session is None:
                    server.load_session()

                if server.session:
                    if any(cookie.name == 'cf_clearance' for cookie in get_session_cookies(server.session)):
                        r = server.session_get(url)
                        if r.ok:
                            return func(*args, **kwargs)

            try:
                result = _frontend('webview.challenge', {
                    'server_id': server.id,
                    'server_name': server.name,
                    'url': url,
                    'user_agent': (server.headers or {}).get('User-Agent'),
                })
            except ChallengeRequired:
                raise
            except Exception as exc:
                logger.info('%s: challenge failed: %s', server.id, exc)
                raise ChallengerError() from exc

            if server.http_client == 'curl_cffi' and crequests is not None:
                from komikku.consts import REQUESTS_TIMEOUT
                server.session = crequests.Session(
                    allow_redirects=True,
                    impersonate='chrome',
                    timeout=(REQUESTS_TIMEOUT, REQUESTS_TIMEOUT * 2),
                )
                jar = server.session.cookies.jar
            else:
                server.session = requests.Session()
                jar = server.session.cookies

            server.session.headers.update(server.headers or {'User-Agent': result['user_agent']})

            cookies = _make_cookies(result['cookies'])
            if not any(c.name == 'cf_clearance' for c in cookies):
                # Same trick as upstream: avoid re-detecting a challenge next time
                cookies.append(requests.cookies.create_cookie(
                    name='cf_clearance', value='74k3', domain=urlsplit(url).netloc, path='/'))
            for cookie in cookies:
                jar.set_cookie(cookie)

            server.save_session()
            return func(*args, **kwargs)

        return wrapper


def get_page_html(url, headers=None, wait_js_code=None, with_cookies=False):
    try:
        result = _frontend('webview.get_page_html', {
            'url': url,
            'headers': headers,
            'wait_js_code': wait_js_code,
            'with_cookies': with_cookies,
        }, timeout=120)
    except Exception as exc:
        logger.warning('Failed to get page html: %s (%s)', url, exc)
        raise requests.exceptions.RequestException() from exc

    if with_cookies:
        return result['html'], _make_cookies(result.get('cookies') or [])
    return result['html']


def eval_js(code, uri=None, wait_ready=False):
    try:
        result = _frontend('webview.eval_js', {
            'code': code,
            'uri': uri or 'about:blank',
            'wait_ready': wait_ready,
        }, timeout=120)
    except Exception as exc:
        logger.warning('Failed to eval JS code (%s)', exc)
        raise requests.exceptions.RequestException() from exc

    if result is None:
        raise requests.exceptions.RequestException()
    return result


def get_page_resources(url, paths, timeout=20, headers=None):
    try:
        return _frontend('webview.get_page_resources', {
            'url': url,
            'paths': paths,
            'timeout': timeout,
            'headers': headers,
        }, timeout=timeout + 30)
    except Exception as exc:
        logger.warning('Failed to get page resources: %s (%s)', url, exc)
        raise requests.exceptions.RequestException() from exc


def get_tracker_access_token(url, app_redirect_url, headers=None):  # noqa: ARG001
    raise NotImplementedError('Trackers are not supported yet on macOS')


def install():
    """Import upstream webview (UI parts become stubs) and swap in our helpers."""
    import komikku.webview as upstream

    upstream.CompleteChallenge = CompleteChallenge
    upstream.get_page_html = get_page_html
    upstream.eval_js = eval_js
    upstream.get_page_resources = get_page_resources
    upstream.get_tracker_access_token = get_tracker_access_token
