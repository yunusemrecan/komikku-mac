# SPDX-License-Identifier: GPL-3.0-or-later
"""
Localization of the SwiftUI app. Turkish is the source language: the Turkish
text in the Swift code is the localization key. Translations live in
app/Localization/<lang>.json as {"Turkish source literal": "translation"}, where
interpolations are written exactly as in the code, e.g.
    "\\(count) yeni bölüm": "\\(count) new chapters"

    python scripts/i18n.py generate OUT_DIR   write <lang>.lproj/Localizable.strings (+ empty tr.lproj)
    python scripts/i18n.py check              list Turkish UI literals without an English translation
    python scripts/i18n.py wrap               wrap Turkish literals in String contexts with String(localized:)

Keys follow Swift's rules: each interpolation becomes a format specifier whose
type is only known to the compiler (%@ for strings, %lld for Int, %d for Int32,
%lf for Double), so every combination is written; the unused ones are harmless.
"""

import glob
import itertools
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, 'app', 'Sources', 'Komikku')
LOCALIZATION = os.path.join(ROOT, 'app', 'Localization')
TR_CHARS = re.compile(r'[çğıöşüÇĞİÖŞÜ]')

# SwiftUI initializers / modifiers whose first argument is a LocalizedStringKey
LSK_CALLS = {
    'Text', 'Button', 'Label', 'Toggle', 'Section', 'Picker', 'Menu', 'LabeledContent', 'TextField',
    'SecureField', 'Link', 'Stepper', 'GroupBox', 'CommandMenu', 'Window', 'WindowGroup',
    'ContentUnavailableView', 'help', 'navigationTitle', 'alert', 'confirmationDialog', 'badge',
    'accessibilityLabel', 'accessibilityHint', 'accessibilityValue', 'Slider',
}


def literals(source):
    """Yield (start, end, text) of single-line string literals; text excludes the quotes.

    Skips comments and multi-line (triple-quoted) literals. Handles interpolations
    containing nested string literals."""
    i, n = 0, len(source)
    while i < n:
        if source.startswith('//', i):
            i = source.find('\n', i)
            if i < 0:
                return
            continue
        if source.startswith('/*', i):
            i = source.find('*/', i) + 2
            continue
        if source.startswith('"""', i):
            i = source.find('"""', i + 3) + 3
            continue
        if source[i] == '"':
            j = i + 1
            depth = 0
            while j < n:
                c = source[j]
                if depth == 0:
                    if c == '\\':
                        if source[j + 1] == '(':
                            depth = 1
                            j += 2
                            continue
                        j += 2
                        continue
                    if c == '"':
                        break
                    if c == '\n':
                        break
                else:
                    if c == '"':  # nested literal inside an interpolation
                        k = j + 1
                        while k < n and source[k] != '"':
                            k += 2 if source[k] == '\\' else 1
                        j = k + 1
                        continue
                    if c == '(':
                        depth += 1
                    elif c == ')':
                        depth -= 1
                j += 1
            yield i, j + 1, source[i + 1:j]
            i = j + 1
            continue
        i += 1


def segments(text):
    """Split a literal body into ('text', s) and ('expr', expression) parts."""
    parts, buf, i = [], '', 0
    while i < len(text):
        if text.startswith('\\(', i):
            depth, j = 1, i + 2
            while depth:
                if text[j] == '"':
                    j = text.index('"', j + 1)
                elif text[j] == '(':
                    depth += 1
                elif text[j] == ')':
                    depth -= 1
                j += 1
            if buf:
                parts.append(('text', buf))
                buf = ''
            parts.append(('expr', text[i + 2:j - 1]))
            i = j
        else:
            buf += text[i]
            i += 1
    if buf:
        parts.append(('text', buf))
    return parts


def is_ui_text(text):
    plain = ''.join(s for kind, s in segments(text) if kind == 'text')
    return bool(TR_CHARS.search(plain))


def ui_literals():
    for path in sorted(glob.glob(os.path.join(SOURCES, '*.swift'))):
        source = open(path, encoding='utf-8').read()
        for start, end, text in literals(source):
            line_start = source.rfind('\n', 0, start) + 1
            line = source[line_start:source.find('\n', start)]
            if 'AppLog.write' in line or line.strip().startswith('//'):
                continue
            if is_ui_text(text):
                yield path, source, start, end, text


def load(lang):
    with open(os.path.join(LOCALIZATION, f'{lang}.json'), encoding='utf-8') as f:
        return json.load(f)


def escape(s):
    return s.replace('\\"', '"').replace('"', '\\"')


def format_keys(source_text, translation):
    """All (key, value) pairs for one entry, one per specifier combination."""
    src = segments(source_text)
    exprs = [s for kind, s in src if kind == 'expr']
    dst = segments(translation)
    out = []
    specs = ['%@', '%lld', '%d', '%lf'] if len(exprs) <= 2 else ['%@', '%lld']
    for combo in itertools.product(specs, repeat=len(exprs)):
        key = ''
        k = 0
        for kind, s in src:
            if kind == 'text':
                key += s.replace('%', '%%')
            else:
                key += combo[k]
                k += 1
        value = ''
        for kind, s in dst:
            if kind == 'text':
                value += s.replace('%', '%%')
            else:
                if s not in exprs:
                    raise ValueError(f'Interpolation \\({s}) of {translation!r} not in source {source_text!r}')
                pos = exprs.index(s)
                value += f'%{pos + 1}${combo[pos][1:]}' if len(exprs) > 1 else combo[pos]
        out.append((key, value))
    return out


def generate(out_dir):
    for path in sorted(glob.glob(os.path.join(LOCALIZATION, '*.json'))):
        lang = os.path.splitext(os.path.basename(path))[0]
        lines = ['/* Generated by scripts/i18n.py from app/Localization/%s.json */' % lang]
        for source_text, translation in sorted(load(lang).items()):
            if not translation:
                continue
            for key, value in format_keys(source_text, translation):
                lines.append(f'"{escape(key)}" = "{escape(value)}";')
        folder = os.path.join(out_dir, f'{lang}.lproj')
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, 'Localizable.strings'), 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
    # Turkish is the source language: an (empty) tr.lproj tells macOS the app speaks Turkish
    os.makedirs(os.path.join(out_dir, 'tr.lproj'), exist_ok=True)
    with open(os.path.join(out_dir, 'tr.lproj', 'Localizable.strings'), 'w', encoding='utf-8') as f:
        f.write('/* Turkish is the source language: keys are the Turkish texts */\n')


def check():
    en = load('en')
    missing = {}
    for path, _source, _start, _end, text in ui_literals():
        if text not in en:
            missing.setdefault(text, os.path.basename(path))
    for text, where in missing.items():
        print(f'{where}: "{text}"')
    sources = ''.join(open(p, encoding='utf-8').read() for p in glob.glob(os.path.join(SOURCES, '*.swift')))
    unused = {t for t in en if f'"{t}"' not in sources}
    for text in sorted(unused):
        print(f'unused translation: "{text}"')
    return 1 if missing else 0


def lsk_context(prefix):
    """Is a literal preceded by `prefix` (same statement) the LocalizedStringKey argument
    of a SwiftUI call?"""
    if re.search(r'String\(localized:\s*$', prefix):
        return True  # already wrapped
    # innermost unclosed parenthesis
    depth, i = 0, len(prefix) - 1
    while i >= 0:
        c = prefix[i]
        if c == ')':
            depth += 1
        elif c == '(':
            if depth == 0:
                break
            depth -= 1
        i -= 1
    if i < 0:
        return False
    name = re.search(r'([A-Za-z_][A-Za-z0-9_]*)\s*$', prefix[:i])
    if not name or name.group(1) not in LSK_CALLS:
        return False
    between = prefix[i + 1:]
    # first argument, possibly the branch of a ternary
    return between.strip() == '' or re.fullmatch(r'[^,]*\?\s*(?:"[^"]*"\s*:\s*)?', between) is not None


def wrap():
    """Only literals that have a translation are touched (identifiers stay as they are)."""
    en = load('en')
    changed = 0
    for path in sorted(glob.glob(os.path.join(SOURCES, '*.swift'))):
        source = open(path, encoding='utf-8').read()
        edits = []
        for start, end, text in literals(source):
            if text not in en:
                continue
            line_start = source.rfind('\n', 0, start) + 1
            line = source[line_start:source.find('\n', start)]
            if 'AppLog.write' in line or line.strip().startswith('//'):
                continue
            # the statement may start on an earlier line (multi-line calls)
            context_start = max(source.rfind('\n\n', 0, start), source.rfind('{\n', 0, start), 0)
            prefix = source[max(context_start, start - 400):start]
            if lsk_context(prefix):
                continue
            edits.append((start, end))
        for start, end in reversed(edits):
            source = source[:start] + 'String(localized: ' + source[start:end] + ')' + source[end:]
        if edits:
            changed += len(edits)
            open(path, 'w', encoding='utf-8').write(source)
            print(f'{os.path.basename(path)}: {len(edits)} wrapped')
    print(f'{changed} literals wrapped')


if __name__ == '__main__':
    command = sys.argv[1]
    if command == 'generate':
        generate(sys.argv[2])
    elif command == 'check':
        sys.exit(check())
    elif command == 'wrap':
        wrap()
    elif command == 'list':
        seen = set()
        for path, _s, _a, _b, text in ui_literals():
            if text not in seen:
                seen.add(text)
                print(json.dumps(text, ensure_ascii=False))
