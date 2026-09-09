# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

import requests

from komikku.servers.exceptions import ServerException
from komikku.translators import Translator

# https://api-free.deepl.com/v3/languages?resource=translate_text
# status = 'stable' and features['auto_detection']['status'] = 'stable'
LANGUAGES = {'ace': 'Acehnese', 'af': 'Afrikaans', 'an': 'Aragonese', 'ar': 'Arabic', 'as': 'Assamese', 'ay': 'Aymara', 'az': 'Azerbaijani', 'ba': 'Bashkir', 'be': 'Belarusian', 'bg': 'Bulgarian', 'bho': 'Bhojpuri', 'bn': 'Bengali', 'br': 'Breton', 'bs': 'Bosnian', 'ca': 'Catalan', 'ceb': 'Cebuano', 'ckb': 'Kurdish (Sorani)', 'cs': 'Czech', 'cy': 'Welsh', 'da': 'Danish', 'de': 'German', 'el': 'Greek', 'en': 'English', 'eo': 'Esperanto', 'es': 'Spanish', 'et': 'Estonian', 'eu': 'Basque', 'fa': 'Persian', 'fi': 'Finnish', 'fr': 'French', 'ga': 'Irish', 'gl': 'Galician', 'gn': 'Guarani', 'gom': 'Konkani', 'gu': 'Gujarati', 'ha': 'Hausa', 'he': 'Hebrew', 'hi': 'Hindi', 'hr': 'Croatian', 'ht': 'Haitian Creole', 'hu': 'Hungarian', 'hy': 'Armenian', 'id': 'Indonesian', 'ig': 'Igbo', 'is': 'Icelandic', 'it': 'Italian', 'ja': 'Japanese', 'jv': 'Javanese', 'ka': 'Georgian', 'kk': 'Kazakh', 'kmr': 'Kurdish (Kurmanji)', 'ko': 'Korean', 'ky': 'Kyrgyz', 'la': 'Latin', 'lb': 'Luxembourgish', 'lmo': 'Lombard', 'ln': 'Lingala', 'lt': 'Lithuanian', 'lv': 'Latvian', 'mai': 'Maithili', 'mg': 'Malagasy', 'mi': 'Maori', 'mk': 'Macedonian', 'ml': 'Malayalam', 'mn': 'Mongolian', 'mr': 'Marathi', 'ms': 'Malay', 'mt': 'Maltese', 'my': 'Burmese', 'nb': 'Norwegian (bokmål)', 'ne': 'Nepali', 'nl': 'Dutch', 'oc': 'Occitan', 'om': 'Oromo', 'pa': 'Punjabi', 'pag': 'Pangasinan', 'pam': 'Kapampangan', 'pl': 'Polish', 'prs': 'Dari', 'ps': 'Pashto', 'pt': 'Portuguese', 'qu': 'Quechua', 'ro': 'Romanian', 'ru': 'Russian', 'sa': 'Sanskrit', 'scn': 'Sicilian', 'sk': 'Slovak', 'sl': 'Slovenian', 'sq': 'Albanian', 'sr': 'Serbian', 'st': 'Sesotho', 'su': 'Sundanese', 'sv': 'Swedish', 'sw': 'Swahili', 'ta': 'Tamil', 'te': 'Telugu', 'tg': 'Tajik', 'th': 'Thai', 'tk': 'Turkmen', 'tl': 'Tagalog', 'tn': 'Tswana', 'tr': 'Turkish', 'ts': 'Tsonga', 'tt': 'Tatar', 'uk': 'Ukrainian', 'ur': 'Urdu', 'uz': 'Uzbek', 'vi': 'Vietnamese', 'wo': 'Wolof', 'xh': 'Xhosa', 'yi': 'Yiddish', 'yue': 'Cantonese', 'zh': 'Chinese', 'zu': 'Zulu'}


class Deepl(Translator):
    id = 'deepl'
    name = 'DeepL'
    base_url = 'https://api.deepl.com'

    api_key = None
    api_key_required = True
    headers = {
        'Content-Type': 'application/json',
    }

    def __init__(self, api_key=None):
        self.session = requests.Session()
        self.headers['Authorization'] = f'DeepL-Auth-Key {api_key}'
        self.session.headers.update(self.headers)

        if api_key:
            self.api_key = api_key

            if api_key.endswith(':fx'):
                # Free API detected
                self.base_url = self.base_url.replace('api', 'api-free')

    @property
    def languages_url(self):
        return self.base_url + '/v3/languages?resource=translate_text'

    @property
    def translate_url(self):
        return self.base_url + '/v2/translate'

    def get_languages(self):
        return {
            'src': LANGUAGES,
            'dst': LANGUAGES,
        }

    def translate(self, text, src='auto', dst='en'):
        data = {
            'target_lang': dst,
            'text': [text],
        }
        if src != 'auto':
            data['source_lang'] = src

        r = self.session_post(self.translate_url, json=data)
        if not r.ok:
            if r.status_code == 403:
                message = 'API key is required' if not self.api_key else 'API key is invalid'
            elif r.status_code == 456:
                message = 'Service limit reached'
            elif r.status_code == 429:
                message = 'Too many requests'
            else:
                message = r.json().get('message')

            raise ServerException(f'{self.name} returned HTTP {r.status_code}: {message}')

        translations = r.json().get('translations')
        src_detected = translations[0].get('detected_source_language')

        return {
            'translated': translations[0]['text'],
            'src_detected': src_detected.lower() if src_detected else None,
            'origin_pronunciation': None,
            'pronunciation': None,
            'mistake': None,
        }

    def validate_api_key(self, key):
        url = self.languages_url
        if key.endswith(':fx'):
            # Free API detected
            url = url.replace('api', 'api-free')

        r = self.session_get(
            url,
            headers={
                'Authorization': f'DeepL-Auth-Key {key}'
            }
        )
        return r.ok
