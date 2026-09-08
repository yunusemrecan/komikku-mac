# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

from gettext import gettext as _

from bs4 import BeautifulSoup

from komikku.servers.multi.madara import Madara
from komikku.servers.utils import convert_date_string
from komikku.utils import is_number


class Mangasorigines(Madara):
    id = 'mangasorigines'
    name = 'Mangas Origines'
    lang = 'fr'
    is_nsfw = True

    series_name = 'oeuvre'
    date_format = '%d/%m/%y'
    images_src_attr = 'data-src'

    base_url = 'https://mangas-origines.fr'
    logo_url = base_url + '/wp-content/uploads/2026/09/cropped-icon_MO-32x32.png'
    api_url = base_url + '/wp-admin/admin-ajax.php'

    filters = [
        {
            'key': 'types',
            'type': 'select',
            'name': _('Type'),
            'description': _('Filter by Types'),
            'value_type': 'multiple',
            'options': [
                {'key': 'manhwa', 'name': _('Manhwa'), 'default': False},
                {'key': 'manhua', 'name': _('Manhua'), 'default': False},
                {'key': 'manga', 'name': _('Manga'), 'default': False},
            ],
        },
        {
            'key': 'status',
            'type': 'select',
            'name': _('Status'),
            'description': _('Filter by Status'),
            'value_type': 'single',
            'default': 'tous',
            'options': [
                {'key': 'tous', 'name': _('All')},
                {'key': 'en-cours', 'name': _('Ongoing')},
                {'key': 'termine', 'name': _('Complete')},
            ],
        },
    ]

    def get_manga_data(self, initial_data):
        """
        Returns manga data by scraping manga HTML page content

        Initial data should contain at least manga's slug (provided by search)
        """
        assert 'slug' in initial_data, 'Manga slug is missing in initial data'

        r = self.session_get(
            self.manga_url.format(initial_data['slug']),
            headers={
                'Referer': f'{self.base_url}/',
            }
        )
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

        data['name'] = soup.select_one('.ori-sr-title').text.strip()
        data['cover'] = soup.select_one('.ori-sr-cover img').get('src')

        # Details
        if element := soup.select_one('.ori-sr-badge-statut'):
            status = element.text.strip()
            if status == 'En cours':
                data['status'] = 'ongoing'
            elif status == 'Terminé':
                data['status'] = 'complete'

        for element in soup.select('.ori-sr-signature > a'):
            author = element.text.strip()
            if author not in data['authors']:
                data['authors'].append(author)

        if element := soup.select_one('.ori-sr-badge .ori-flag'):
            type_ = element.parent.text.strip()
            data['genres'].append(type_)

        if element := soup.select_one('.ori-sr-syn-texte'):
            data['synopsis'] = element.text.strip()

        # Chapters
        for element in reversed(soup.select('.ori-chl-liste .ori-chl-row')):
            a_element = element.select_one('.ori-chl-num')
            num = element.get('data-num')
            if date_element := element.select_one('.ori-chl-date'):
                date = date_element.text.strip()
            else:
                date = None

            data['chapters'].append({
                'slug': a_element.get('href').split('/')[-2],
                'title': element.select_one('.ori-chl-nom-long').text.strip(),
                'num': num if is_number(num) else None,
                'date': convert_date_string(date, format=self.date_format, languages=[self.lang]) if date else None,
            })

        return data

    def get_latest_updates(self, types, status):
        return self.search(None, types, status, 'latest')

    def get_most_populars(self, types, status):
        return self.search(None, types, status, 'populars')

    def search(self, term, types, status, orderby=None):
        params = {
            'action': 'madara_child_catalogue',
            's': term or '',
            'genres': '',
            'statut': status,
            'note': '0',
            'origine': ','.join(types),
            'tri': 'recents',
            'chmin': '0',
            'chmax': '0',
            'page': '1',
            'auteur': '',
            'artiste': '',
            'annee': '',
            'vue': 'detail',
        }

        if orderby == 'populars':
            params['tri'] = 'populaire'

        r = self.session_post(self.api_url, data=params)
        if r.status_code != 200:
            return None

        resp_data = r.json()
        if not resp_data.get('success'):
            return None

        soup = BeautifulSoup(resp_data['data']['html'], 'lxml')

        results = []
        for element in soup.select('.ori-cat-fiche'):
            a_element = element.select_one('.ori-cat-fiche-titre')
            cover_element = element.select_one('.ori-cat-fiche-cover > img')
            last_chapter_element = element.select_one('.ori-cat-fiche-chaps a:first-child span')

            results.append({
                'slug': a_element.get('href').split('/')[-2],
                'name': a_element.text.strip(),
                'cover': cover_element.get('src'),
                'last_chapter': last_chapter_element.text.strip() if last_chapter_element else None,
            })

        return results
