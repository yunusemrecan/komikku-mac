# SPDX-License-Identifier: GPL-3.0-or-later
"""Collect third-party license texts for the app bundle.

    python third_party_notices.py SITE_PACKAGES REPO_ROOT OUT_NOTICES OUT_COPYLEFT

Writes:
  OUT_NOTICES   one text file with every bundled component's license
  OUT_COPYLEFT  top-level import names (one per line) of packages under a
                copyleft license (GPL/LGPL/AGPL/MPL); the build keeps their
                .py sources in the bundle instead of shipping bytecode only.

Fails (exit 1) if an installed distribution has no license text anywhere:
neither in its .dist-info nor under licenses/extra/<name>.txt.
"""

import sys
from importlib import metadata
from pathlib import Path

SKIP = {"pip", "setuptools", "wheel"}
COPYLEFT_MARKERS = ("GPL", "GNU GENERAL PUBLIC", "GNU LESSER", "GNU AFFERO", "MPL", "MOZILLA PUBLIC")
LICENSE_NAMES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS", "COPYRIGHT")
RULE = "=" * 78


def norm(name):
    return name.lower().replace("_", "-").replace(".", "-")


def license_label(dist):
    md = dist.metadata
    expr = md.get("License-Expression")
    if expr:
        return expr.strip()
    classifiers = [c.split("::")[-1].strip() for c in md.get_all("Classifier") or []
                   if c.startswith("License ::")]
    if classifiers:
        return "; ".join(classifiers)
    lic = (md.get("License") or "").strip()
    if lic and "\n" not in lic and len(lic) < 100:
        return lic
    return "see text below"


def license_files(dist):
    found = []
    for f in dist.files or []:
        parts = f.parts
        if not parts or not parts[0].endswith(".dist-info"):
            continue
        base = parts[-1].upper()
        if any(base.startswith(n) for n in LICENSE_NAMES) or (len(parts) > 2 and parts[1] in ("licenses", "license_files")):
            p = Path(dist.locate_file(f))
            if p.is_file():
                found.append(p)
    return sorted(set(found))


def top_level(dist):
    names = set()
    tl = dist.read_text("top_level.txt")
    if tl:
        names.update(n.strip() for n in tl.splitlines() if n.strip())
    for f in dist.files or []:
        first = f.parts[0]
        if first.endswith((".dist-info", ".data")) or first in ("..", "bin"):
            continue
        names.add(first[:-3] if first.endswith(".py") else first)
    return names


def section(title, body):
    return f"{RULE}\n{title}\n{RULE}\n\n{body.rstrip()}\n\n"


def main():
    site, root, out_notices, out_copyleft = map(Path, sys.argv[1:5])
    extra = root / "licenses" / "extra"
    out = []
    missing = []
    copyleft = set()

    out.append(
        "Mekurimac (macOS interface for Komikku) — third-party notices\n\n"
        "Mekurimac (https://github.com/yunusemrecan/mekurimac) is free software\n"
        "under the GNU General Public License v3.0 or later (see LICENSE in this folder).\n"
        "It bundles the unmodified Komikku application by Valéry Febvre and contributors\n"
        "(https://codeberg.org/valos/Komikku, GPL-3.0-or-later), a standalone CPython\n"
        "build and the Python packages listed below. Each component's license text follows.\n"
        "Complete corresponding source for this build: the repository above at the commit\n"
        "shown in Settings › About, plus the upstream projects linked below.\n\n"
    )

    dists = sorted((d for d in metadata.distributions(path=[str(site)])
                    if norm(d.metadata["Name"]) not in SKIP),
                   key=lambda d: norm(d.metadata["Name"]))

    out.append("Contents\n--------\n")
    for d in dists:
        out.append(f"  {d.metadata['Name']} {d.version} — {license_label(d)}\n")
    out.append("  curl_cffi bundled native libraries (curl-impersonate, curl, BoringSSL, nghttp2,\n"
               "    nghttp3, ngtcp2, zstd, brotli, c-ares)\n"
               "  lxml bundled native libraries (libxml2, libxslt)\n"
               "  Python (python-build-standalone) and its native libraries\n\n")

    for d in dists:
        name, version = d.metadata["Name"], d.version
        label = license_label(d)
        home = d.metadata.get("Home-page") or ""
        for url in d.metadata.get_all("Project-URL") or []:
            if not home and ("source" in url.lower() or "home" in url.lower()):
                home = url.split(",", 1)[-1].strip()
        texts = [(p.name, p.read_text(errors="replace")) for p in license_files(d)]
        fallback = extra / f"{norm(name)}.txt"
        if not texts and fallback.is_file():
            texts = [(fallback.name, fallback.read_text())]
        if not texts:
            missing.append(name)
            continue
        if any(m in label.upper() for m in COPYLEFT_MARKERS):
            copyleft |= top_level(d)
            label += " (source code included in the app bundle)"
        body = f"License: {label}\n" + (f"Source: {home}\n" if home else "")
        for fname, text in texts:
            body += f"\n--- {fname} ---\n\n{text.strip()}\n"
        out.append(section(f"{name} {version}", body))

    for title, folder in (("curl_cffi bundled native libraries", "curl_cffi-bundled"),
                          ("lxml bundled native libraries", "lxml-bundled")):
        body = ""
        for p in sorted((extra / folder).glob("*.txt")):
            body += f"\n--- {p.stem} ---\n\n{p.read_text().strip()}\n"
        out.append(section(title, body))

    pbs = root / "licenses" / "python-build-standalone"
    body = ("Python runtime from https://github.com/astral-sh/python-build-standalone\n"
            "(CPython: https://github.com/python/cpython). Licenses of CPython and the\n"
            "native libraries it was built with (some are not shipped after trimming):\n")
    for p in sorted(pbs.glob("*.txt")):
        body += f"\n--- {p.stem.removeprefix('LICENSE.')} ---\n\n{p.read_text(errors='replace').strip()}\n"
    out.append(section("Python (python-build-standalone)", body))

    if missing:
        print("No license text for: " + ", ".join(missing)
              + " — add licenses/extra/<name>.txt", file=sys.stderr)
        return 1

    out_notices.write_text("".join(out))
    out_copyleft.write_text("".join(f"{n}\n" for n in sorted(copyleft)))
    print(f"{len(dists)} packages; copyleft (sources kept): {', '.join(sorted(copyleft)) or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
