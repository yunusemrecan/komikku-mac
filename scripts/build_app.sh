#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build Komikku.app (macOS, Apple Silicon by default).
#
#   scripts/build_app.sh [--arch arm64|x86_64] [--python-version 3.13]
#
# Steps: build the SwiftUI executable, download a relocatable CPython
# (astral-sh/python-build-standalone), install backend dependencies into it,
# copy backend + upstream Komikku sources, assemble and ad-hoc sign the bundle.
# Output: dist/Komikku.app and dist/Komikku-macos-<arch>.zip

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="arm64"
PY_VERSION="3.13"
VERSION="${KOMIKKU_MAC_VERSION:-0.1.0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --python-version) PY_VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

case "$ARCH" in
    arm64) PBS_ARCH="aarch64" ;;
    x86_64) PBS_ARCH="x86_64" ;;
    *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/Komikku.app"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$BUILD" "$DIST" "$APP/Contents/MacOS" "$RES"

echo "==> Building Swift app ($ARCH)"
swift build --package-path "$ROOT/app" -c release --arch "$ARCH"
BIN_DIR="$(swift build --package-path "$ROOT/app" -c release --arch "$ARCH" --show-bin-path)"
cp "$BIN_DIR/Komikku" "$APP/Contents/MacOS/Komikku"

echo "==> Fetching standalone Python $PY_VERSION ($PBS_ARCH)"
PY_TARBALL="$BUILD/python-$PY_VERSION-$PBS_ARCH.tar.gz"
if [[ ! -f "$PY_TARBALL" ]]; then
    # Resolve the newest release asset, e.g.
    # cpython-3.13.9+20251014-aarch64-apple-darwin-install_only_stripped.tar.gz
    API="https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"
    AUTH=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
    PY_URL="$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} "$API" | python3 -c "
import json, re, sys
assets = json.load(sys.stdin)['assets']
pattern = re.compile(r'^cpython-${PY_VERSION//./\\.}\.\d+\+\d+-${PBS_ARCH}-apple-darwin-install_only_stripped\.tar\.gz$')
urls = [a['browser_download_url'] for a in assets if pattern.match(a['name'])]
print(urls[0] if urls else '')
")"
    if [[ -z "$PY_URL" ]]; then
        echo "Could not find a python-build-standalone asset for $PY_VERSION/$PBS_ARCH" >&2
        exit 1
    fi
    echo "    $PY_URL"
    curl -fsSL -o "$PY_TARBALL" "$PY_URL"
fi
tar -xzf "$PY_TARBALL" -C "$RES"          # creates Resources/python
PY="$RES/python/bin/python3"
"$PY" --version

echo "==> Installing backend dependencies"
"$PY" -m pip install --disable-pip-version-check --no-warn-script-location --quiet \
    --only-binary=lxml,pillow,brotli,curl_cffi \
    -r "$ROOT/backend/requirements-mac.txt"

echo "==> Copying backend and upstream Komikku"
mkdir -p "$RES/backend" "$RES/upstream"
rsync -a --exclude '__pycache__' --exclude 'tests' "$ROOT/backend/komikku_mac" "$RES/backend/"
rsync -a --exclude '__pycache__' "$ROOT/upstream/komikku" "$RES/upstream/"
mkdir -p "$RES/upstream/data"
cp "$ROOT/upstream/data/info.febvre.Komikku.gschema.xml.in" "$RES/upstream/data/"
cp "$ROOT/upstream/LICENSE" "$RES/upstream/LICENSE"
git -C "$ROOT/upstream" rev-parse --short HEAD > "$RES/upstream/UPSTREAM_COMMIT" 2>/dev/null || true

echo "==> Precompiling Python sources"
"$PY" -m compileall -q -j 0 "$RES/backend" "$RES/upstream/komikku" >/dev/null || true

echo "==> Trimming bundled Python"
rm -rf "$RES/python/lib/python$PY_VERSION/test" \
       "$RES/python/lib/python$PY_VERSION/idlelib" \
       "$RES/python/lib/python$PY_VERSION/tkinter" \
       "$RES/python/lib/python$PY_VERSION/turtledemo" \
       "$RES/python/share" \
       "$RES/python/include"
find "$RES/python" -name '*.a' -delete

echo "==> Info.plist and icon"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" \
    "$ROOT/app/Resources/Info.plist" > "$APP/Contents/Info.plist"
iconutil -c icns "$ROOT/app/Resources/AppIcon.iconset" -o "$RES/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing"
# Re-sign every Mach-O in the embedded Python (pip may have rewritten some),
# then the bundle itself. Apple Silicon refuses to run unsigned code.
find "$RES/python" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 \
    | while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then
            codesign --force --sign - --timestamp=none "$f"
        fi
    done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> Zipping"
rm -f "$DIST/Komikku-macos-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Komikku-macos-$ARCH.zip"

du -sh "$APP" "$DIST/Komikku-macos-$ARCH.zip"
echo "Done: $APP"
