# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

from functools import wraps
import json
import logging
import re
from urllib.parse import urlparse

from bs4 import BeautifulSoup
import requests

from komikku.consts import USER_AGENT
from komikku.servers import Server
from komikku.servers.utils import convert_date_string
from komikku.utils import get_buffer_mime_type

logger = logging.getLogger(__name__)


def get_chapters_jump_url(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        server = args[0]

        if server.chapters_jump_url:
            return func(*args, **kwargs)

        if results := server.get_latest_updates():
            first = results[0]
            r = server.session_get(
                server.get_manga_url(first['slug'], None),
                headers={
                    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                }
            )
            if not r.ok:
                return func(*args, **kwargs)

            soup = BeautifulSoup(r.text, 'lxml')

            if element := soup.select_one('a[href*="/go/rds/"]'):
                url = element.get('href')
                url_parsed = urlparse(url)
                server.chapters_jump_referer = f'{url_parsed.scheme}://{url_parsed.netloc}/'

                r = server.session_get(
                    url,
                    allow_redirects=False,
                    headers={
                        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                        'Accept-Language': 'fr,en-US;q=0.9',
                        'Accept-Encoding': 'gzip, deflate, br, zstd',
                        'Referer': f'{server.base_url}/',
                        'Sec-Fetch-Dest': 'document',
                        'Sec-Fetch-Mode': 'navigate',
                        'Sec-Fetch-Site': 'cross-site',
                        'Sec-GPC': '1',
                        'Sec-Fetch-User': '?1',
                    }
                )
                if not r.ok:
                    return func(*args, **kwargs)

                soup = BeautifulSoup(r.text, 'lxml')
                if script_element := soup.select_one('script'):
                    script = script_element.string
                    if not script:
                        return func(*args, **kwargs)

                    if matches := re.search(r"document\.location\s*=\s*'([^']+)'", script):
                        url = matches.group(1)
                        url_parsed = urlparse(url)
                        server.chapters_jump_url = f'{url_parsed.scheme}://{url_parsed.netloc}{url_parsed.path}'

        return func(*args, **kwargs)

    return wrapper


class Niadd(Server):
    id = 'niadd'
    name = 'Niadd'
    lang = 'en'
    lang_code = 'en'

    is_nsfw = True

    base_url = 'https://www.niadd.com'
    logo_url = base_url + '/files/images/favicon.ico?v=178'
    search_url = base_url + '/ajax/search/'
    latest_updates_url = base_url + '/list/New-Update/'
    most_populars_url = base_url + '/list/Hot-Manga/'
    manga_url = base_url + '/{0}/{1}.html'
    chapters_url = base_url + '/{0}/{1}/chapters.html'

    chapters_jump_url = None
    chapters_jump_referer = None

    def __init__(self):
        if self.session is None:
            self.session = requests.Session()
            self.session.headers = {
                'User-Agent': USER_AGENT,
            }

    @classmethod
    def get_manga_initial_data_from_url(cls, url):
        url_split = url.split('/')
        manga_type = url_split[-2]
        manga_slug = url_split[-1].replace('.html', '')

        return f'{manga_type}:{manga_slug}'

    def get_manga_data(self, initial_data):
        """
        Returns manga data by scraping manga HTML page content

        Initial data should contain at least manga's slug (provided by search)
        """
        assert 'slug' in initial_data, 'Slug is missing in initial data'

        manga_type, manga_slug = initial_data['slug'].split(':')
        r = self.session_get(self.manga_url.format(manga_type, manga_slug))
        if r.status_code != 200:
            return None

        if r.url == f'{self.base_url}/no_book.html':
            # Manga page doesn't exist, we have been redirected to homepage
            return None

        soup = BeautifulSoup(r.text, 'lxml')

        data = initial_data.copy()
        data.update({
            'authors': [],
            'scanlators': [],  # not available
            'genres': [],
            'status': None,
            'synopsis': None,
            'chapters': [],
            'server_id': self.id,
        })

        data['name'] = soup.select_one('h1[itemprop="name"]').text.strip()
        data['cover'] = soup.select_one('img[itemprop="image"]').get('src')

        # Details
        if element := soup.select_one('.book-status'):
            status = element.text.strip().lower()
            if status in ('ongoing', 'en marcha', 'en cours', 'laufend', 'in corso', 'em progresso', 'постоянный'):
                data['status'] = 'ongoing'
            else:
                data['status'] = 'complete'

        for element in soup.select('div[itemprop="author"] span[itemprop="name"]'):
            author = element.text.strip()
            if author not in data['authors']:
                data['authors'].append(author)

        for element in soup.select('.detail-section span[itemprop="genre"]'):
            data['genres'].append(element.text.strip())

        if element := soup.select_one('.detail-section-box:nth-child(5) > section:nth-child(2)'):
            data['synopsis'] = element.text.strip()

        # Chapters
        r = self.session_get(
            self.chapters_url.format(manga_type, manga_slug),
            headers={
                'Sec-Fetch-Dest': 'none',
            }
        )
        if r.status_code != 200:
            return data

        soup = BeautifulSoup(r.text, 'lxml')

        for element in reversed(soup.select('.chapter-list > a.hover-underline[href*="/chapter/"]')):
            url = element.get('href')

            data['chapters'].append({
                'slug': url.split('/')[-2],
                'title': element.select_one('.chp-title').text.strip(),
                'date': convert_date_string(element.select_one('.chp-time').text.strip(), format='%b %d, %Y', languages=[self.lang]),
            })

        return data

    @get_chapters_jump_url
    def get_manga_chapter_data(self, manga_slug, manga_name, chapter_slug, chapter_url):
        """
        Returns manga chapter data by scraping chapter HTML page content

        Currently, only pages are expected.
        """
        if not self.chapters_jump_url:
            logger.warning('Failed to get chapters jump URL')
            return None

        manga_type, manga_slug = manga_slug.split(':')

        r = self.session_get(
            self.chapters_jump_url,
            params={
                'type': f'{self.lang_code}niadd' if manga_type == 'manga' else 'ogniadd',
                'cid': chapter_slug,
            },
            headers={
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'fr,en-US;q=0.9',
                'Accept-Encoding': 'gzip, deflate, br',
                'Referer': self.chapters_jump_referer,
                'Sec-Fetch-Dest': 'document',
                'Sec-Fetch-Mode': 'navigate',
                'Sec-Fetch-Site': 'cross-site',
                'Sec-GPC': '1',
            }
        )
        if r.status_code != 200:
            self.chapters_jump_url = None
            return None

        soup = BeautifulSoup(r.text, 'lxml')

        urls = None
        for script_element in soup.select('script'):
            script = script_element.string
            if not script or 'all_imgs_url' not in script:
                continue

            if matches := re.search(r'all_imgs_url\s*:\s*\[([\s\S]*?)\]', script):
                urls = json.loads(f'[{matches.group(1).strip()[:-1]}]')

            break

        if not urls:
            logger.warning('Failed to get chapter URLs')
            return None

        data = {
            'pages': [],
        }
        for url in urls:
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
                'Referer': 'f{self.base_url}/',
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
        manga_type, manga_slug = slug.split(':')
        return self.manga_url.format(manga_type, manga_slug)

    def get_latest_updates(self):
        """
        Returns Latest Updates list
        """
        r = self.session_get(self.latest_updates_url)
        if r.status_code != 200:
            return None

        soup = BeautifulSoup(r.text, 'lxml')

        results = []
        for element in soup.select('.manga-list .manga-item'):
            a_element = element.select_one('.manga-part > a')
            img_element = element.select_one('.manga-img img')
            last_chapter_a_element = element.select_one('.manga-latest-chp')

            slug = a_element.get('href').split('/')[-1].replace('.html', '')
            type_ = a_element.get('href').split('/')[-2]

            results.append({
                'name': a_element.get('title'),
                'slug': f'{type_}:{slug}',
                'cover': img_element.get('src'),
                'last_chapter': last_chapter_a_element.text.strip(),
            })

        return results

    def get_most_populars(self):
        """
        Returns Hot manga list
        """
        r = self.session_get(self.latest_updates_url)
        if r.status_code != 200:
            return None

        soup = BeautifulSoup(r.text, 'lxml')

        results = []
        for element in soup.select('.manga-list .manga-item'):
            a_element = element.select_one('.manga-part > a')
            img_element = element.select_one('.manga-img img')
            last_chapter_a_element = element.select_one('.manga-latest-chp')

            slug = a_element.get('href').split('/')[-1].replace('.html', '')
            type_ = a_element.get('href').split('/')[-2]

            results.append({
                'name': a_element.get('title'),
                'slug': f'{type_}:{slug}',
                'cover': img_element.get('src'),
                'last_chapter': last_chapter_a_element.text.strip(),
            })

        return results

    def search(self, term):
        r = self.session_get(
            self.search_url,
            params={
                'term': term,
            },
            headers={
                'Referer': f'{self.base_url}/',
            }
        )
        if r.status_code != 200:
            return None

        results = []
        for item in r.json():
            if item['is_original']:
                slug = f'original:{item["id"]}'
            else:
                slug = f'manga:{item["visit_path"]}'

            results.append({
                'name': item['name'],
                'slug': slug,
                'cover': item['cover'],
                'last_chapter': item['last_chapter_title'],
            })

        return results


class Niadd_pt_br(Niadd):
    id = 'niadd_pt_br'
    lang = 'pt_BR'
    lang_code = 'br'

    base_url = 'https://br.niadd.com'
    search_url = base_url + '/ajax/search/'
    latest_updates_url = base_url + '/list/New-Update/'
    most_populars_url = base_url + '/list/Hot-Manga/'
    manga_url = base_url + '/{0}/{1}.html'
    chapters_url = base_url + '/{0}/{1}/chapters.html'


class Niadd_de(Niadd):
    id = 'niadd_de'
    lang = 'de'
    lang_code = 'de'

    base_url = 'https://de.niadd.com'
    search_url = base_url + '/ajax/search/'
    latest_updates_url = base_url + '/list/New-Update/'
    most_populars_url = base_url + '/list/Hot-Manga/'
    manga_url = base_url + '/{0}/{1}.html'
    chapters_url = base_url + '/{0}/{1}/chapters.html'


class Niadd_es(Niadd):
    id = 'niadd_es'
    lang = 'es'
    lang_code = 'es'

    base_url = 'https://es.niadd.com'
    search_url = base_url + '/ajax/search/'
    latest_updates_url = base_url + '/list/New-Update/'
    most_populars_url = base_url + '/list/Hot-Manga/'
    manga_url = base_url + '/{0}/{1}.html'
    chapters_url = base_url + '/{0}/{1}/chapters.html'


class Niadd_fr(Niadd):
    id = 'niadd_fr'
    lang = 'fr'
    lang_code = 'fr'

    base_url = 'https://fr.niadd.com'
    search_url = base_url + '/ajax/search/'
    latest_updates_url = base_url + '/list/New-Update/'
    most_populars_url = base_url + '/list/Hot-Manga/'
    manga_url = base_url + '/{0}/{1}.html'
    chapters_url = base_url + '/{0}/{1}/chapters.html'


class Niadd_it(Niadd):
    id = 'niadd_it'
    lang = 'it'
    lang_code = 'it'

    base_url = 'https://it.niadd.com'
    search_url = base_url + '/ajax/search/'
    latest_updates_url = base_url + '/list/New-Update/'
    most_populars_url = base_url + '/list/Hot-Manga/'
    manga_url = base_url + '/{0}/{1}.html'
    chapters_url = base_url + '/{0}/{1}/chapters.html'


class Niadd_ru(Niadd):
    id = 'niadd_ru'
    lang = 'ru'
    lang_code = 'ru'

    base_url = 'https://ru.niadd.com'
    search_url = base_url + '/ajax/search/'
    latest_updates_url = base_url + '/list/New-Update/'
    most_populars_url = base_url + '/list/Hot-Manga/'
    manga_url = base_url + '/{0}/{1}.html'
    chapters_url = base_url + '/{0}/{1}/chapters.html'
