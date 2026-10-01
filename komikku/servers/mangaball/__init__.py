# SPDX-FileCopyrightText: 2019-2025 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

from gettext import gettext as _

import requests

from komikku.consts import USER_AGENT
from komikku.servers import Server
from komikku.servers.utils import convert_date_string
from komikku.utils import get_buffer_mime_type
from komikku.utils import is_number

LANGUAGES_CODES = {
    'ar': ['ar'],
    'cs': ['cs'],
    'de': ['de'],
    'en': ['en'],
    'es': ['es', 'es-es', 'es-419', 'es-ar', 'es-mx', 'es-la'],
    'es_419': ['es', 'es-es', 'es-419', 'es-ar', 'es-mx', 'es-la'],
    'fa': ['fa'],
    'fr': ['fr'],
    'id': ['id'],
    'it': ['it', 'it-it'],
    'ja': ['ja', 'jp'],
    'ko': ['ko', 'kr'],
    'nl': ['nl', 'nl-be'],
    'pl': ['pl'],
    'pt': ['pt', 'pt-pt'],
    'pt_BR': ['pt-br'],
    'ru': ['ru'],
    'th': ['th', 'th-hk', 'th-kh', 'th-la', 'th-my', 'th-sg'],
    'tr': ['tr'],
    'uk': ['uk'],
    'vi': ['vi'],
    'zh_Hant': ['cn', 'zh-cn', 'zh', 'zh-hk', 'zh-mo', 'zh-sg', 'zh-tw'],
    'zh_Hans': ['cn', 'zh-cn', 'zh', 'zh-hk', 'zh-mo', 'zh-sg', 'zh-tw'],
}


class Mangaball(Server):
    id = 'mangaball'
    name = 'MangaBall'
    lang = 'en'

    is_nsfw = True

    base_url = 'https://mangaball.com'
    logo_url = base_url + '/images/favicon.png'

    search_url = base_url + '/search-advanced/'
    manga_url = base_url + '/title-detail/{0}'
    chapter_url = base_url + '/chapter-detail/{0}?chapter={1}'
    cover_url = 'https://bulbasaur.poke-black-and-white.net/covers/{0}'

    api_url = 'https://api.mangaball.com/api/v1'
    api_search_url = api_url + '/title/search-advanced'
    api_manga_url = api_url + '/title/detail/{0}'
    api_chapters_url = api_url + '/chapter/chapter-listing-by-title-id'
    api_chapter_url = api_url + '/chapter-detail'

    filters = [
        {
            'key': 'demographic',
            'type': 'select',
            'name': _('Demographic'),
            'description': _('Filter by Publication Demographic'),
            'value_type': 'single',
            'default': '',
            'options': [
                {'key': '', 'name': _('Any')},
                {'key': 'shounen', 'name': _('Shounen')},
                {'key': 'shoujo', 'name': _('Shoujo')},
                {'key': 'seinen', 'name': _('Seinen')},
                {'key': 'josei', 'name': _('Josei')},
                {'key': 'yuri', 'name': _('Yuri')},
                {'key': 'yaoi', 'name': _('Yaoi')},
            ],
        },
        {
            'key': 'status',
            'type': 'select',
            'name': _('Status'),
            'description': _('Filter by Status'),
            'value_type': 'single',
            'default': '',
            'options': [
                {'key': '', 'name': _('Any')},
                {'key': 'ongoing', 'name': _('Ongoing')},
                {'key': 'completed', 'name': _('Completed')},
                {'key': 'hiatus', 'name': _('Hiatus')},
                {'key': 'cancelled', 'name': _('Canceled')},
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
                {'key': '', 'name': _('Any')},
                {'key': 'manga', 'name': _('Manga')},
                {'key': 'manhwa', 'name': _('Manhwa')},
                {'key': 'manhua', 'name': _('Manhua')},
                {'key': 'comics', 'name': _('Comic')},
            ]
        },
        {
            'key': 'nsfw',
            'type': 'checkbox',
            'name': _('Adult Content'),
            'description': _('Whether to show series containing adult content'),
            'default': False,
        },
    ]

    def __init__(self):
        if self.session is None:
            self.session = requests.Session()
            self.session.headers.update({'User-Agent': USER_AGENT})

    def get_manga_data(self, initial_data):
        """
        Returns manga data using API

        Initial data should contain at least manga's slug (provided by search)
        """
        assert 'slug' in initial_data, 'Slug is missing in initial data'

        r = self.session_get(self.api_manga_url.format(initial_data['slug']))
        if r.status_code != 200:
            return None

        resp_data = r.json()['data']

        data = initial_data.copy()
        data.update({
            'name': resp_data['name'],
            'authors': [],
            'scanlators': [],
            'genres': [],
            'status': None,
            'synopsis': None,
            'chapters': [],
            'server_id': self.id,
            'cover': None,
        })

        cover_path = None
        if image := resp_data.get('image'):
            cover_path = image['cover'].get('path') if image.get('cover') else None
        if cover_path:
            data['cover'] = self.cover_url.format(cover_path)

        if status := resp_data.get('status'):
            if status == 'completed':
                data['status'] = 'complete'
            elif status == 'ongoing':
                data['status'] = 'ongoing'
            elif status == 'hiatus':
                data['status'] = 'hiatus'
            elif status == 'cancelled':
                data['status'] = 'suspended'

        for tag in resp_data.get('tags'):
            data['genres'].append(tag['name'].strip())

        for author in resp_data.get('authors'):
            author = author['name'].strip()
            if author not in data['authors']:
                data['authors'].append(author)

        data['synopsis'] = '\n'.join(resp_data['description'])

        # Chapters
        r = self.session_post(
            self.api_chapters_url,
            json={
                'title_id': data['slug'],
                'lang': LANGUAGES_CODES[self.lang][0],
                'user_id': 'demo_user',
            },
            headers={
                'Content-Type': 'application/json',
                'Referer': f'{self.base_url}/',
            }
        )
        if r.status_code != 200:
            return None

        resp_data = r.json()['data']

        for item in reversed(resp_data):
            num = item.get('number')
            if num is None:
                num = item.get('chapter_number')

            if item['lang'] not in LANGUAGES_CODES[self.lang]:
                continue

            data['chapters'].append({
                'slug': f'{item["id"]}:{num}',
                'title': f'Ch. {num}',
                'num': num if is_number(num) else None,
                'scanlators': [item.get('group_name')],
                'date': convert_date_string(item['updated_at'].split('T')[0], format='%Y-%m-%d'),
            })

        return data

    def get_manga_chapter_data(self, manga_slug, manga_name, chapter_slug, chapter_url):
        """
        Returns manga chapter data using API

        Currently, only pages are expected.
        """
        chapter_id, chapter_slug = chapter_slug.split(':')
        r = self.session_get(
            self.api_chapter_url.format(chapter_slug),
            params={
                'chapter_id': chapter_id,
                'user_id': 'demo_user',
                'chapter': chapter_slug,
            },
            headers={
                'Referer': self.chapter_url.format(chapter_id, chapter_slug),
            }
        )
        if r.status_code != 200:
            return None

        resp_data = r.json()['data']

        data = {
            'pages': [],
        }
        for url in resp_data['chapter']['pages']:
            data['pages'].append({
                'slug': None,
                'image': url,
            })

        return data

    def get_manga_chapter_page_image(self, manga_slug, manga_name, chapter_slug, page):
        """
        Returns chapter page scan (image) content
        """
        r = self.session_get(
            page['image'],
            headers={
                'Referer': f'{self.base_url}/',
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

    def get_manga_list(self, term=None, demographic=None, status=None, type=None, nsfw=False, orderby=None):
        payload = {}
        if term:
            payload['keyword'] = term

        payload.update({
            'sort_by': orderby or 'name',
            'sort_order': 'desc',
            'adult_mode': 'all' if nsfw else 'no_18',
            'tag_mode': 'AND',
            'use_user_settings': 'true',
            'page': 1,
            'limit': 24,
            'user_id': 'demo_user',
        })

        if type:
            payload['type'] = type
        if demographic:
            payload['publicationDemographic'] = demographic
        if status:
            payload['status'] = status

        r = self.session_get(
            self.api_search_url,
            params=payload,
            headers={
                'Accept': 'application/json, text/plain, */*',
                'Referer': f'{self.base_url}/',
            }
        )
        if r.status_code != 200:
            return None

        resp_data = r.json()
        if resp_data.get('status') != 'success':
            return None

        results = []
        for item in resp_data['data']:
            cover_path = None
            if image := item.get('image'):
                cover_path = image['cover'].get('path') if image.get('cover') else None

            results.append({
                'slug': item['id'],
                'name': item['name'],
                'cover': self.cover_url.format(cover_path.replace('\\', '/')) if cover_path else None,
            })

        return results

    def get_latest_updates(self, demographic=None, status=None, type=None, nsfw=False):
        return self.get_manga_list(demographic=demographic, status=status, type=type, nsfw=nsfw, orderby='lastupdate')

    def get_most_populars(self, demographic=None, status=None, type=None, nsfw=False):
        return self.get_manga_list(demographic=demographic, status=status, type=type, nsfw=nsfw, orderby='views')

    def search(self, term, demographic=None, status=None, type=None, nsfw=False):
        return self.get_manga_list(term=term, demographic=demographic, status=status, nsfw=nsfw, type=type)


class Mangaball_ar(Mangaball):
    id = 'mangaball_ar'
    lang = 'ar'


class Mangaball_cs(Mangaball):
    id = 'mangaball_cs'
    lang = 'cs'


class Mangaball_de(Mangaball):
    id = 'mangaball_de'
    lang = 'de'


class Mangaball_es(Mangaball):
    id = 'mangaball_es'
    lang = 'es'


class Mangaball_es_419(Mangaball):
    id = 'mangaball_es_419'
    lang = 'es_419'


class Mangaball_fa(Mangaball):
    id = 'mangaball_fa'
    lang = 'fa'


class Mangaball_fr(Mangaball):
    id = 'mangaball_fr'
    lang = 'fr'


class Mangaball_id(Mangaball):
    id = 'mangaball_id'
    lang = 'id'


class Mangaball_it(Mangaball):
    id = 'mangaball_it'
    lang = 'it'


class Mangaball_ja(Mangaball):
    id = 'mangaball_ja'
    lang = 'ja'


class Mangaball_ko(Mangaball):
    id = 'mangaball_ko'
    lang = 'ko'


class Mangaball_nl(Mangaball):
    id = 'mangaball_nl'
    lang = 'nl'


class Mangaball_pl(Mangaball):
    id = 'mangaball_pl'
    lang = 'pl'


class Mangaball_pt(Mangaball):
    id = 'mangaball_pt'
    lang = 'pt'


class Mangaball_pt_br(Mangaball):
    id = 'mangaball_pt_br'
    lang = 'pt_BR'


class Mangaball_ru(Mangaball):
    id = 'mangaball_ru'
    lang = 'ru'


class Mangaball_th(Mangaball):
    id = 'mangaball_th'
    lang = 'th'


class Mangaball_tr(Mangaball):
    id = 'mangaball_tr'
    lang = 'tr'


class Mangaball_uk(Mangaball):
    id = 'mangaball_uk'
    lang = 'uk'


class Mangaball_vi(Mangaball):
    id = 'mangaball_vi'
    lang = 'vi'


class Mangaball_zh_hant(Mangaball):
    id = 'mangaball_zh_hant'
    lang = 'zh_Hant'


class Mangaball_zh_hans(Mangaball):
    id = 'mangaball_zh_hans'
    lang = 'zh_Hans'
