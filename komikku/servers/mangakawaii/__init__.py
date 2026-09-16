# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

from gettext import gettext as _
import json
import time

from bs4 import BeautifulSoup
import requests

from komikku.consts import DOWNLOAD_MAX_DELAY
from komikku.consts import USER_AGENT
from komikku.servers import Server
from komikku.servers.utils import convert_date_string
from komikku.servers.utils import get_soup_element_inner_text
from komikku.utils import get_buffer_mime_type
from komikku.utils import get_response_elapsed
from komikku.utils import is_number


class Mangakawaii(Server):
    id = 'mangakawaii'
    name = 'MangaKawaii'
    lang = 'fr'

    is_nsfw = True

    base_url = 'https://www.mangakawaii.fr'
    logo_url = base_url + '/assets/img/favicon-32x32.png'
    search_url = base_url + '/mangas'
    manga_url = base_url + '/manga/{0}'
    chapter_url = base_url + '/manga/{0}/{1}'
    chapters_url = base_url + '/manga/{0}/chapitres'
    cover_url = 'https://cdn.mangakawaii.fr/uploads/manga/{0}/cover/cover_250x350.webp?v=1'

    filters = [
        {
            'key': 'statuses',
            'type': 'select',
            'name': _('Status'),
            'description': _('Filter by Statuses'),
            'value_type': 'multiple',
            'options': [
                {'key': 'abandonne', 'name': _('Suspended'), 'default': False},
                {'key': 'en-cours', 'name': _('Ongoing'), 'default': False},
                {'key': 'en-pause', 'name': _('Hiatus'), 'default': False},
                {'key': 'termine', 'name': _('Complete'), 'default': False},
            ]
        },
        {
            'key': 'types',
            'type': 'select',
            'name': _('Type'),
            'description': _('Filter by Types'),
            'value_type': 'multiple',
            'options': [
                {'key': 'comic', 'name': _('Comic'), 'default': False},
                {'key': 'doujinshi', 'name': _('Doujinshi'), 'default': False},
                {'key': 'manga', 'name': _('Manga'), 'default': False},
                {'key': 'manhua', 'name': _('Manhua'), 'default': False},
                {'key': 'manhwa', 'name': _('Manhwa'), 'default': False},
                {'key': 'one-shot', 'name': _('Oneshot'), 'default': False},
                {'key': 'webtoon', 'name': _('Webtoon'), 'default': False},
            ],
        },
    ]

    long_strip_genres = ['Webtoon', ]

    def __init__(self):
        if self.session is None:
            self.session = requests.Session()
            self.session.headers.update({'User-Agent': USER_AGENT})

    def get_manga_data(self, initial_data):
        """
        Returns manga data by scraping manga HTML page content

        Initial data should contain at least manga's slug (provided by search)
        """
        assert 'slug' in initial_data, 'Manga slug is missing in initial data'

        r = self.session_get(self.manga_url.format(initial_data['slug']))
        if r.status_code != 200:
            return None

        soup = BeautifulSoup(r.text, 'lxml')

        data = initial_data.copy()
        data.update({
            'authors': [],
            'scanlators': [],
            'genres': [],
            'status': None,
            'synopsis': None,
            'chapters': [],
            'server_id': self.id,
        })

        data['name'] = soup.find('h1').text.strip()
        if data.get('cover') is None:
            data['cover'] = self.cover_url.format(data['slug'])

        # Details
        for element in soup.select('div.justify-center > a.mk-pill'):
            genre = element.text.strip()
            if genre not in data['genres']:
                data['genres'].append(genre)

        if element := soup.select_one('span.absolute.bg-brand.inset-x-0'):
            licensed = element.text.strip()
            data['genres'].append(licensed)

        if element := soup.select_one('details p'):
            for text in element.text.split('·'):
                text = text.strip()
                if text == 'En Cours':
                    data['status'] = 'ongoing'
                elif text == 'Terminé':
                    data['status'] = 'complete'
                elif text == 'En Pause':
                    data['status'] = 'hiatus'
                elif text == 'Abandonné':
                    data['status'] = 'suspended'
                elif not is_number(text):
                    if text not in data['genres']:
                        data['genres'].append(text)

        if element := soup.select_one('.mk-card:-soup-contains("Traduit par") a'):
            data['scanlators'].append(get_soup_element_inner_text(element, recursive=False))

        if element := soup.select_one('.mk-card.mk-card-pad p'):
            data['synopsis'] = element.text.strip()

        # Chapters
        data['chapters'] = self.get_manga_chapters_data(initial_data['slug'])

        return data

    def get_manga_chapter_data(self, manga_slug, manga_name, chapter_slug, chapter_url):
        """
        Returns manga chapter data by scraping chapter HTML page content

        Currently, only pages are expected.
        """
        r = self.session_get(self.chapter_url.format(manga_slug, chapter_slug))
        if r.status_code != 200:
            return None

        soup = BeautifulSoup(r.text, 'lxml')

        data = {
            'pages': [],
        }
        if element := soup.select_one('div[x-data^="rd(JSON.parse("]'):
            # rd(JSON.parse('json_data'))
            xdata = element.get('x-data')[15:-3]
            xdata = rf'{xdata}'.replace('\\u0022', '"').replace('\\u0026', '&').replace('\\', '')
            xdata = json.loads(xdata)
            if images := xdata.get('imgs'):
                for index, image in enumerate(images, start=1):
                    data['pages'].append({
                        'slug': None,
                        'image': image,
                        'index': index,
                    })

        return data

    def get_manga_chapters_data(self, manga_slug):
        def get_page(page):
            r = self.session_get(
                self.chapters_url.format(manga_slug),
                params={
                    'page': page,
                    'ch': None,
                },
                headers={
                    'Referer': f'{self.base_url}/',
                }
            )
            if r.status_code != 200:
                return [], False, None

            soup = BeautifulSoup(r.text, 'lxml')

            more = soup.select_one('span').get('data-ch-next') != ''

            return soup, more, get_response_elapsed(r)

        chapters = []
        delay = None
        more = True
        page = 1
        while more:
            if delay:
                time.sleep(delay)

            soup, more, rtime = get_page(page)
            for element in soup.select('.ch-row'):
                a_element = element.select_one('a.ch-num')
                if not a_element:
                    # External chapter
                    continue
                date_element = element.select_one('.min-w-0.flex-1 p')
                if icon_element := element.select_one('i.fa-user'):
                    scanlator_element = icon_element.parent
                else:
                    scanlator_element = None
                if num_element := element.select_one('input'):
                    num = num_element.get('data-num')
                else:
                    num = None

                chapters.append({
                    'slug': a_element.get('href').split('/')[-1],
                    'title': a_element.text.strip(),
                    'num': num if is_number(num) else None,
                    'scanlators': [scanlator_element.text.strip()] if scanlator_element else None,
                    'date': convert_date_string(date_element.text.strip(), languages=[self.lang]) if date_element else None,
                })

            delay = min(rtime * 4, DOWNLOAD_MAX_DELAY) if rtime else None
            page += 1

        return list(reversed(chapters))

    def get_manga_chapter_page_image(self, manga_slug, manga_name, chapter_slug, page, retry=False):
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
            if r.status_code in (403, 410) and not retry and page.get('index'):
                # Image URL is outdated
                data = self.get_manga_chapter_data(manga_slug, manga_name, chapter_slug, None)
                if not data or not data['pages'] or page['index'] > len(data['pages']):
                    return None

                page = data['pages'][page['index'] - 1]
                return self.get_manga_chapter_page_image(manga_slug, manga_name, chapter_slug, page, retry=True)

            return None

        mime_type = get_buffer_mime_type(r.content)
        if not mime_type.startswith('image'):
            return None

        return {
            'buffer': r.content,
            'mime_type': mime_type,
            'name': page['image'].split('?')[0].split('/')[-1],
        }

    def get_manga_url(self, slug, url):
        """
        Returns manga absolute URL
        """
        return self.manga_url.format(slug)

    def get_latest_updates(self, statuses=None, types=None):
        """
        Returns latest updates
        """
        return self.search(statuses=statuses, types=types, orderby='latest')

    def get_most_populars(self, statuses=None, types=None):
        """
        Returns list of popular manga
        """
        return self.search(statuses=statuses, types=types, orderby='populars')

    def search(self, term=None, statuses=None, types=None, orderby=None):
        params = {
            'sort': 'views',
            'dir': 'desc',
            'status[]': statuses,
            'types[]': types,
        }
        if term:
            params['q'] = term
        if orderby == 'latest':
            params['sort'] = 'last_updated'

        r = self.session_get(
            self.search_url,
            params=params,
            headers={
                'Referer': f'{self.base_url}/',
            }
        )
        if r.status_code != 200:
            return None

        soup = BeautifulSoup(r.text, 'lxml')

        results = []
        for a_element in soup.select('a.mk-card.mk-hover'):
            img_element = a_element.select_one('.object-cover')

            results.append({
                'slug': a_element.get('href').split('/')[-1],
                'name': a_element.select_one('.mk-display').text.strip(),
                'cover': img_element.get('src'),
            })

        return results


class Mangakawaii_en(Mangakawaii):
    id = 'mangakawaii_en'
    lang = 'en'
    status = 'disabled'
