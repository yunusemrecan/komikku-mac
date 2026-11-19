# SPDX-License-Identifier: GPL-3.0-or-later
"""
Pure-Python stand-in for python-magic (libmagic is not bundled on macOS).

Upstream only asks for MIME types of images and of local archives/documents,
so signature sniffing is enough.
"""

_SIGNATURES = (
    (0, b'\xff\xd8\xff', 'image/jpeg'),
    (0, b'\x89PNG\r\n\x1a\n', 'image/png'),
    (0, b'GIF87a', 'image/gif'),
    (0, b'GIF89a', 'image/gif'),
    (0, b'BM', 'image/bmp'),
    (0, b'\xff\x0a', 'image/jxl'),
    (0, b'\x00\x00\x00\x0cJXL \r\n\x87\n', 'image/jxl'),
    (0, b'II*\x00', 'image/tiff'),
    (0, b'MM\x00*', 'image/tiff'),
    (0, b'%PDF', 'application/pdf'),
    (0, b'PK\x03\x04', 'application/zip'),
    (0, b'PK\x05\x06', 'application/zip'),
    (0, b'Rar!\x1a\x07', 'application/vnd.rar'),
    (0, b'7z\xbc\xaf\x27\x1c', 'application/x-7z-compressed'),
    (0, b'<?xml', 'text/xml'),
)

_FTYP_BRANDS = {
    b'avif': 'image/avif',
    b'avis': 'image/avif',
    b'heic': 'image/heic',
    b'heix': 'image/heic',
    b'mif1': 'image/heif',
    b'msf1': 'image/heif',
}


def _sniff(buffer):
    if not buffer:
        return 'application/x-empty'

    head = bytes(buffer[:64])

    if head[:4] == b'RIFF' and head[8:12] == b'WEBP':
        return 'image/webp'

    if head[4:8] == b'ftyp':
        brand = head[8:12]
        if brand in _FTYP_BRANDS:
            return _FTYP_BRANDS[brand]
        return 'video/mp4'

    for offset, signature, mime_type in _SIGNATURES:
        if head[offset:offset + len(signature)] == signature:
            if mime_type == 'application/zip' and b'mimetypeapplication/epub+zip' in bytes(buffer[:128]):
                return 'application/epub+zip'
            return mime_type

    stripped = head.lstrip()
    if stripped[:5].lower() in (b'<!doc', b'<html'):
        return 'text/html'
    if stripped[:4] == b'<svg' or (stripped[:5] == b'<?xml' and b'<svg' in bytes(buffer[:256])):
        return 'image/svg+xml'

    try:
        bytes(buffer[:128]).decode('utf-8')
        return 'text/plain'
    except UnicodeDecodeError:
        return 'application/octet-stream'


def from_buffer(buffer, mime=False):
    mime_type = _sniff(buffer)
    return mime_type if mime else mime_type


def from_file(filename, mime=False):
    with open(filename, 'rb') as fp:
        return from_buffer(fp.read(256), mime=mime)


def version():
    return 0


class MagicException(Exception):
    pass


class Magic:
    def __init__(self, mime=False, **_kwargs):
        self.mime = mime

    def from_buffer(self, buffer):
        return from_buffer(buffer, self.mime)

    def from_file(self, filename):
        return from_file(filename, self.mime)
