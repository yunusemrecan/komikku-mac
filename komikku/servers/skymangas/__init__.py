# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

from gettext import gettext as _
import time

import requests

from komikku.consts import DOWNLOAD_MAX_DELAY
from komikku.servers.multi.manga_stream import MangaStream
from komikku.servers.utils import convert_date_string
from komikku.utils import get_buffer_mime_type
from komikku.utils import get_response_elapsed
from komikku.utils import is_number

SEARCH_RESULTS_PAGES = 4
SEARCH_RESULTS_PER_PAGE = 24


class Skymangas(MangaStream):
    id = 'skymangas'
    name = 'SkyMangas'
    lang = 'es'

    base_url = 'https://skymangas.com'
    logo_url = base_url + '/assets/LogoSimbolo.png'
    manga_url = base_url + '/manhua/{0}'

    api_url = 'https://api.skymangas.com/api/v1'
    api_image_url = 'https://api.skymangas.com/{0}'
    api_manga_list_url = api_url + '/manhuas/search'
    api_manga_url = api_url + '/manhuas/{0}'
    api_chapters_url = api_url + '/chapters/manhua/{0}'
    api_chapter_url = api_url + '/chapters/{0}/{1}'

    filters = [
        {
            'key': 'status',
            'type': 'select',
            'name': _('Status'),
            'description': _('Filter by Status'),
            'value_type': 'single',
            'default': '',
            'options': [
                {'key': '', 'name': _('All')},
                {'key': '1', 'name': _('Ongoing')},
                {'key': '2', 'name': _('Complete')},
                {'key': '3', 'name': _('Hiatus')},
                {'key': '4', 'name': _('Suspended')},
            ]
        },
        {
            'key': 'type',
            'type': 'select',
            'name': _('Type'),
            'description': _('Filter by Type'),
            'value_type': 'single',
            'default': '',
            'options': [
                {'key': '', 'name': _('All')},
                {'key': '1', 'name': _('Manhua')},
                {'key': '2', 'name': _('Manhwa')},
                {'key': '3', 'name': _('Manga')},
                {'key': '4', 'name': _('Manfra')},
                {'key': '5', 'name': _('OEL')},
                {'key': '6', 'name': _('Other')},
            ],
        },
        {
            'key': 'demographic',
            'type': 'select',
            'name': _('Demographic'),
            'description': _('Filter by Publication Demographic'),
            'value_type': 'single',
            'default': '',
            'options': [
                {'key': '', 'name': _('All')},
                {'key': '1', 'name': _('Shounen')},
                {'key': '2', 'name': _('Shoujo')},
                {'key': '3', 'name': _('Seinen')},
                {'key': '4', 'name': _('Josei')},
                {'key': '5', 'name': _('Kodomo')},
                {'key': '6', 'name': _('Other')},
            ],
        }
    ]

    def __init__(self):
        if self.session is None:
            self.session = requests.Session()
            self.session.headers = self.headers

    def get_manga_data(self, initial_data):
        """
        Returns manga data from API

        Initial data should contain at least manga's slug (provided by search)
        """
        assert 'slug' in initial_data, 'Slug is missing in initial data'

        id, slug = initial_data['slug'].split(':')
        r = self.session_get(
            self.api_manga_url.format(slug),
            headers={
                'Referer': f'{self.base_url}/',
            }
        )
        if r.status_code != 200:
            return None

        resp_json = r.json()
        if not resp_json.get('success'):
            return None

        resp_data = resp_json['data']

        data = initial_data.copy()
        data.update({
            'authors': [],
            'scanlators': [],  # not available
            'genres': [],
            'status': None,
            'synopsis': None,
            'chapters': [],
            'server_id': self.id,
            'cover': None,
        })

        data['name'] = resp_data['title']
        data['cover'] = self.api_image_url.format(resp_data.get('coverThumbUrl'))

        # Details
        data['status'] = ['ongoing', 'complete', 'hiatus', 'suspended'][resp_data['statusId']]

        if genres := resp_data.get('genres'):
            for genre in genres:
                data['genres'].append(genre['name'])

        if tags := resp_data.get('tags'):
            for tag in tags:
                if tag['name'] in data['genres']:
                    continue
                data['genres'].append(tag['name'])

        if type_ := resp_data.get('originationName'):
            data['genres'].append(type_)

        if demographic := resp_data.get('demographicId'):
            data['genres'].append(['Shounen', 'Shoujo', 'Seinen', 'Josei', 'Kodomo', 'Ninguna'][demographic])

        if authors := resp_data['author']:
            for author in authors.split(','):
                author = author.strip()
                data['authors'].append(author)
        if authors := resp_data['artist']:
            for author in authors.split(','):
                author = author.strip()
                if author not in data['authors']:
                    data['authors'].append(author)

        if synopsis := resp_data.get('synopsis'):
            data['synopsis'] = synopsis

        data['chapters'] = self.get_manga_chapters_data(initial_data['slug'])

        return data

    def get_manga_chapter_data(self, manga_slug, manga_name, chapter_slug, chapter_url):
        """
        Returns manga chapter data from API

        Currently, only pages are expected.
        """
        _manga_id, manga_slug = manga_slug.split(':')
        r = self.session_get(
            self.api_chapter_url.format(manga_slug, chapter_slug),
            headers={
                'Referer': f'{self.base_url}/',
            }
        )
        if r.status_code != 200:
            return [], False, None

        resp_json = r.json()
        if not resp_json.get('success'):
            return None

        resp_data = resp_json['data']['pages']

        data = {
            'pages': [],
        }
        for page in resp_data:
            data['pages'].append({
                'slug': None,
                'image': self.api_image_url.format(page['imageWebp']),
                'index': page['pageNumber'],
            })

        return data

    def get_manga_chapters_data(self, manga_slug):
        id, _slug = manga_slug.split(':')

        def get_page(page):
            params = {
                'page': page,
                'perPage': 500,
                'sort': 'desc',
            }

            r = self.session_get(
                self.api_chapters_url.format(id),
                params=params,
                headers={
                    'Referer': f'{self.base_url}/',
                }
            )
            if r.status_code != 200:
                return [], False, None

            resp_data = r.json()
            if not resp_data.get('success'):
                return [], False, None

            more = page < resp_data['meta']['totalPages']

            return resp_data['data'], more, get_response_elapsed(r)

        chapters = []
        delay = None
        more = True
        page = 1
        while more:
            if delay:
                time.sleep(delay)

            items, more, rtime = get_page(page)
            for item in items:
                num = item.get('chapterNumber')
                num_volume = item.get('volume')

                chapters.append({
                    'slug': num,
                    'title': item['title'] or f'Cap. {num}',
                    'num': num if is_number(num) else None,
                    'num_volume': num_volume if is_number(num_volume) else None,
                    'scanlators': item['groupNames'].split(',') if item.get('groupNames') else None,
                    'date': convert_date_string(item['publishedAt'].split('T')[0], format='%Y-%m-%d'),
                })

            delay = min(rtime * 4, DOWNLOAD_MAX_DELAY) if rtime else None
            page += 1

        return list(reversed(chapters))

    def get_manga_chapter_page_image(self, manga_slug, manga_name, chapter_slug, page):
        """
        Returns chapter page scan (image) content
        """
        r = self.session_get(page['image'])
        if r.status_code != 200:
            return None

        mime_type = get_buffer_mime_type(r.content)
        if not mime_type.startswith('image'):
            return None

        return {
            'buffer': r.content,
            'mime_type': mime_type,
            'name': '{0}.{1}'.format(page['index'], mime_type.split('/')[-1]),
        }

    def get_manga_url(self, slug, url):
        """
        Returns manga absolute URL
        """
        _id, slug = slug.split(':')
        return self.manga_url.format(slug)

    def get_manga_list(self, term=None, demographic=None, status=None, type=None, orderby=None):
        def get_page(page):
            params = {
                'page': page,
                'perPage': SEARCH_RESULTS_PER_PAGE,
            }
            if term:
                params['q'] = term

            if status:
                params['statusId'] = status
            if type:
                params['originationId'] = type
            if demographic:
                params['demographicId'] = demographic

            if orderby == 'latest':
                params['sort'] = 'updated'
            else:
                params['sort'] = 'popular'

            r = self.session_get(
                self.api_manga_list_url,
                params=params,
                headers={
                    'Referer': f'{self.base_url}/',
                }
            )
            if r.status_code != 200:
                return [], False, None

            resp_data = r.json()
            if not resp_data.get('success'):
                return [], False, None

            more = page < resp_data['meta']['totalPages'] and page < SEARCH_RESULTS_PAGES

            return resp_data['data'], more, get_response_elapsed(r)

        results = []
        delay = None
        more = True
        page = 1
        while more:
            if delay:
                time.sleep(delay)

            items, more, rtime = get_page(page)
            for item in items:
                results.append({
                    'slug': f'{item["id"]}:{item["slug"]}',
                    'name': item['title'],
                    'cover': self.api_image_url.format(item['coverThumbUrl']),
                })

            delay = min(rtime * 4, DOWNLOAD_MAX_DELAY) if rtime else None
            page += 1

        return results

    def get_latest_updates(self, demographic=None, status=None, type=None):
        return self.get_manga_list(demographic=demographic, status=status, type=type, orderby='latest')

    def get_most_populars(self, demographic=None, status=None, type=None):
        return self.get_manga_list(demographic=demographic, status=status, type=type, orderby='popular')

    def search(self, term, demographic=None, status=None, type=None):
        return self.get_manga_list(term=term, demographic=demographic, status=status, type=type)
