# Komikku for macOS

Native macOS (SwiftUI) front end for [Komikku](https://codeberg.org/valos/Komikku), the manga reader by Valéry Febvre.

The GTK user interface is rewritten in SwiftUI; everything else — the 380+ server
plugins, the SQLite database, downloads and page caching — is upstream Komikku's own
Python code, run unmodified from the `upstream/` submodule.

```
┌──────────────────────────┐   JSON-RPC over stdio   ┌─────────────────────────────────┐
│ SwiftUI app (app/)       │ ──────────────────────▶ │ Python backend (backend/)        │
│ library, explorer, card, │                         │  komikku_mac: API + gi shim      │
│ reader windows, menus    │ ◀────────────────────── │  upstream/komikku: servers,      │
│ WKWebView for challenges │   webview.* requests    │  models, database (unchanged)    │
└──────────────────────────┘                         └─────────────────────────────────┘
```

## How upstream runs without GTK

`backend/komikku_mac/shim/gi` stands in for PyGObject:

- `GLib` — user directories mapped to `~/Library/Application Support` and `~/Library/Caches`, `Variant`, timeouts.
- `Gio.Settings` — JSON file backed, defaults and enums read from upstream's GSettings schema.
- Every other namespace (`Gtk`, `Adw`, `WebKit`, …) is a permissive stub so UI modules still import.

`komikku.webview` helpers (Cloudflare/captcha challenges, JS-rendered pages) are replaced by
calls back into the app, which drives a `WKWebView` and shows a window when a captcha needs a human.

`python-magic` is replaced by a pure-Python signature sniffer, so no libmagic is bundled.

## Install

Download `Komikku-macos-arm64.zip` from **Releases → nightly** (or a tagged release), unzip, move
`Komikku.app` to Applications. The app is ad-hoc signed, not notarized, so the first time:

```sh
xattr -dr com.apple.quarantine /Applications/Komikku.app
```

(or right-click → Open). Requires macOS 14+, Apple Silicon.

## Keyboard shortcuts

| Where | Shortcut | Action |
|---|---|---|
| Anywhere | ⌘1 / ⌘2 | Library / Servers |
| | ⌘F | Search |
| | ⌘R | Update library |
| | ⌘, | Settings |
| Manga | ⌘O | Continue reading |
| | ↩ / double-click | Open chapter |
| Reader | ← → | Previous/next page (follows reading direction) |
| | Space / ⇧Space, ↓ ↑, PgDn PgUp | Next / previous page |
| | Home / End | First / last page |
| | ⌘] / ⌘[ | Next / previous chapter |
| | F or ⌃⌘F | Full screen |

## Building

On a Mac with Xcode 15+:

```sh
git clone --recursive https://github.com/yunusemrecan/komikku-mac
cd komikku-mac
scripts/build_app.sh            # -> dist/Komikku.app
```

Every push to `main` is built by GitHub Actions on macOS and published as the `nightly` release.

Development run against a checkout (any Python 3.12+ with `backend/requirements-mac.txt` installed):

```sh
KOMIKKU_BACKEND_DIR=$PWD/backend KOMIKKU_PYTHON=$(which python3) swift run --package-path app
```

Backend test without the UI (works on Linux too):

```sh
python backend/tests/smoke_test.py --live
```

## Updating upstream

```sh
git -C upstream pull origin main && git add upstream && git commit -m "Update upstream Komikku"
```

## Not yet ported

Trackers (AniList, MAL, MangaUpdates), OCR/translation, local CBZ/PDF library, categories,
download manager queue UI, double-page spreads, server login UI.

## License

GPL-3.0-or-later, like Komikku.
