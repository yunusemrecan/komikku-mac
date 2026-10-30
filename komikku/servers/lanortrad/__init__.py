# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

from functools import wraps
import json
import logging

import requests

from komikku.consts import USER_AGENT
from komikku.servers import Server
from komikku.servers.utils import convert_date_string
from komikku.utils import get_buffer_mime_type
from komikku.webview import eval_js

logger = logging.getLogger(__name__)


def get_chapters(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        server = args[0]

        if not server.chapters:
            try:
                res = eval_js('JSON.stringify(window.CHAPTERS)', server.search_url, wait_ready=True)
            except Exception:
                return None

            server.chapters = json.loads(res)

        return func(*args, **kwargs)

    return wrapper


def get_series(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        server = args[0]

        if not server.series:
            try:
                res = eval_js('JSON.stringify(window.SERIES)', server.search_url, wait_ready=True)
            except Exception:
                return None

            for serie in json.loads(res):
                server.series[serie['id']] = serie

        return func(*args, **kwargs)

    return wrapper


class Lanortrad(Server):
    id = 'lanortrad'
    name = 'LanorTrad'
    lang = 'fr'

    base_url = 'https://lanortrad.com'
    logo_url = base_url + '/images/icons/icon-192x192.png'
    search_url = base_url + '/catalogue.html'
    manga_url = base_url + '/manga/{0}/'
    chapter_url = base_url + '/manga/{0}/{1}/'
    image_url = base_url + '/Manga/{0}/Chapitres/Chapitre {1:02d}/{2}'
    image_oneshot_url = base_url + '/Manga/{0}/Oneshot/{1}'

    series = {}
    chapters = {}

    def __init__(self):
        if self.session is None:
            self.session = requests.Session()
            self.session.headers = {
                'User-Agent': USER_AGENT,
            }

    @get_series
    @get_chapters
    def get_manga_data(self, initial_data):
        """
        Returns manga data

        Initial data should contain at least manga's slug (provided by search)
        """
        assert 'slug' in initial_data, 'Manga slug is missing in initial data'

        serie_data = self.series[initial_data['slug']]

        data = initial_data.copy()
        data.update({
            'authors': [],
            'scanlators': [self.name, ],
            'genres': serie_data.get('genres'),
            'status': 'ongoing',
            'synopsis': None,
            'chapters': [],
            'server_id': self.id,
            'cover': None,
        })

        data['name'] = serie_data['title']
        if cover := serie_data.get('cover'):
            data['cover'] = f'{self.base_url}/{cover}'

        # Details
        if type_ := serie_data.get('type'):
            data['genres'].append(type_)
        if year := serie_data.get('year'):
            data['genres'].append(str(year))

        if author := serie_data.get('author'):
            data['authors'].append(author)
        if author := serie_data.get('artist'):
            if author not in data['authors']:
                data['authors'].append(author)

        if status := serie_data.get('status'):
            if status == 'En cours':
                data['status'] = 'ongoing'
            elif status == 'Terminé':
                data['status'] = 'complete'

        if synopsis := serie_data.get('description'):
            data['synopsis'] = synopsis

        # Chapters
        for chapter in reversed(self.chapters[data['slug']]):
            num = chapter['num']
            date = chapter.get('d')

            data['chapters'].append({
                'slug': f'chapitre-{num}',
                'title': f'Chapitre {num}',
                'num': num,
                'date': convert_date_string(date.split('T')[0], format='%Y-%m-%d') if date else None,
            })

        return data

    def get_manga_chapter_data(self, manga_slug, manga_name, chapter_slug, chapter_url):
        """
        Returns manga chapter data

        Currently, only pages are expected.
        """
        try:
            url = self.chapter_url.format(manga_slug.lower().replace(' ', '-'), chapter_slug)
            res = eval_js('JSON.stringify(window.CHAPTER_FILES)', url, wait_ready=True)
        except Exception:
            return None

        chapter_num = chapter_slug.split('-')[-1]
        chapters_files = json.loads(res)[manga_slug]
        pages = chapters_files[chapter_num]['f']
        oneshot = len(chapters_files) == 1

        data = {
            'pages': [],
        }
        for name in pages:
            if oneshot:
                image = self.image_oneshot_url.format(manga_slug, name)
            else:
                image = self.image_url.format(manga_slug, int(chapter_num), name)

            data['pages'].append({
                'slug': None,
                'image': image,
            })

        return data

    def get_manga_chapter_page_image(self, manga_slug, manga_name, chapter_slug, page):
        """
        Returns chapter page scan (image) content
        """
        r = self.session_get(
            page['image'],
            headers={
                'Referer': self.chapter_url.format(manga_slug, chapter_slug),
            }
        )
        if r.status_code != 200:
            return None

        mime_type = get_buffer_mime_type(r.content)
        if not mime_type.startswith('image'):
            return None

        return {
            'buffer': r.content,
            'mime_type': mime_type,
            'name': page['image'].split('/')[-1],
        }

    def get_manga_url(self, slug, url):
        """
        Returns manga absolute URL
        """
        return self.manga_url.format(slug)

    def get_most_populars(self):
        return self.search()

    @get_series
    def search(self, term=None):
        results = []
        for id, serie in self.series.items():
            if term and term.lower() not in serie['title'].lower():
                continue

            results.append({
                'slug': serie['id'],
                'name': serie['title'],
                'cover': f'{self.base_url}/{serie["cover"]}',
            })

        return results
