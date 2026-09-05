# SPDX-FileCopyrightText: 2019-2026 Valéry Febvre
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Valéry Febvre <vfebvre@easter-eggs.com>

from abc import ABC
from abc import abstractmethod
import logging

from komikku.utils import BaseServer

logger = logging.getLogger(__name__)


class Translator(BaseServer, ABC):
    base_url: str

    chars_limit: int = 2000

    api_key_required: bool = False
    instance_url_required: bool = False

    @abstractmethod
    def get_languages(self):
        """Return dict of supported src/dst languages"""

    @abstractmethod
    def translate(self, text, src='auto', dst='en'):
        """Translate text from src language to dst language"""

    def validate_api_key(self):
        return self.api_key_required

    def validate_instance_url(self):
        return self.instance_url_required
