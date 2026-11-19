# SPDX-License-Identifier: GPL-3.0-or-later
"""
Bidirectional JSON-RPC over stdio (one JSON object per line).

    frontend -> backend   {"id": 1, "method": "explorer.search", "params": {...}}
    backend  -> frontend  {"id": 1, "result": ...} | {"id": 1, "error": {"message": ...}}

The backend can also call the frontend (WKWebView work) with ids prefixed by
"b", and send notifications without id: {"method": "...", "params": {...}}.
"""

import concurrent.futures
import datetime
import itertools
import json
import logging
import os
import sys
import threading
import traceback

logger = logging.getLogger('komikku_mac.rpc')

_out = None
_out_lock = threading.Lock()
_pending = {}
_pending_lock = threading.Lock()
_ids = itertools.count(1)
_handlers = {}
_executor = concurrent.futures.ThreadPoolExecutor(max_workers=12, thread_name_prefix='rpc')


class RPCError(Exception):
    def __init__(self, message, code='error', data=None):
        super().__init__(message)
        self.code = code
        self.data = data


def method(name):
    def decorator(func):
        _handlers[name] = func
        return func
    return decorator


def _default(obj):
    if isinstance(obj, (datetime.datetime, datetime.date)):
        return obj.isoformat()
    if isinstance(obj, (set, frozenset, tuple)):
        return list(obj)
    if isinstance(obj, bytes):
        return None
    return str(obj)


def _send(message):
    line = json.dumps(message, default=_default, ensure_ascii=False)
    with _out_lock:
        _out.write(line + '\n')
        _out.flush()


def notify(method_name, params=None):
    _send({'method': method_name, 'params': params or {}})


def call_frontend(method_name, params=None, timeout=None):
    """Blocking call into the Swift side. Must not be called from the reader thread."""
    request_id = f'b{next(_ids)}'
    future = concurrent.futures.Future()
    with _pending_lock:
        _pending[request_id] = future
    _send({'id': request_id, 'method': method_name, 'params': params or {}})
    try:
        return future.result(timeout=timeout)
    finally:
        with _pending_lock:
            _pending.pop(request_id, None)


def _run(request_id, method_name, params):
    handler = _handlers.get(method_name)
    if handler is None:
        _send({'id': request_id, 'error': {'code': 'not_found', 'message': f'Unknown method {method_name}'}})
        return
    try:
        result = handler(**(params or {}))
    except RPCError as exc:
        _send({'id': request_id, 'error': {'code': exc.code, 'message': str(exc), 'data': exc.data}})
    except Exception as exc:
        logger.error('%s failed:\n%s', method_name, traceback.format_exc())
        _send({'id': request_id, 'error': {
            'code': type(exc).__name__,
            'message': str(exc) or type(exc).__name__,
        }})
    else:
        _send({'id': request_id, 'result': result})


def _handle_line(line):
    try:
        message = json.loads(line)
    except ValueError:
        logger.warning('Invalid JSON from frontend: %r', line[:200])
        return

    if 'method' in message:
        _executor.submit(_run, message.get('id'), message['method'], message.get('params'))
        return

    # Response to one of our calls
    with _pending_lock:
        future = _pending.get(message.get('id'))
    if future is None:
        return
    if 'error' in message and message['error']:
        error = message['error']
        future.set_exception(RPCError(error.get('message', 'Frontend error'), error.get('code', 'error')))
    else:
        future.set_result(message.get('result'))


def serve():
    """Take over stdio and serve requests until stdin is closed."""
    global _out

    # Keep a private handle on the real stdout for the protocol, and send
    # everything else (print(), C libraries) to stderr.
    protocol_fd = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    _out = os.fdopen(protocol_fd, 'w', encoding='utf-8', buffering=1)

    notify('backend.ready', {'pid': os.getpid()})

    for line in sys.stdin:
        line = line.strip()
        if line:
            _handle_line(line)

    _executor.shutdown(wait=False, cancel_futures=True)
