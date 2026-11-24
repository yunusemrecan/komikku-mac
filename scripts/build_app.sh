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
PY_VERSION="3.13"   # must match PBS_PYTHON in python-standalone.env
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

echo "==> Fetching standalone Python (pinned, checksum-verified)"
# Pinned in scripts/python-standalone.env (tag, version, SHA256 per architecture)
source "$ROOT/scripts/python-standalone.env"
PY_SHA256_VAR="PBS_SHA256_${PBS_ARCH}"
PY_SHA256="${!PY_SHA256_VAR}"
PY_NAME="cpython-${PBS_PYTHON}+${PBS_TAG}-${PBS_ARCH}-apple-darwin-install_only_stripped.tar.gz"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PY_NAME//+/%2B}"
PY_TARBALL="$BUILD/$PY_NAME"
if [[ ! -f "$PY_TARBALL" ]]; then
    echo "    $PY_URL"
    curl -fsSL -o "$PY_TARBALL" "$PY_URL"
fi
echo "$PY_SHA256  $PY_TARBALL" | shasum -a 256 -c - || {
    echo "Checksum mismatch for $PY_NAME — refusing to build" >&2
    rm -f "$PY_TARBALL"
    exit 1
}
tar -xzf "$PY_TARBALL" -C "$RES"          # creates Resources/python
PY="$RES/python/bin/python3"
"$PY" --version

echo "==> Installing backend dependencies"
# Exact versions + SHA256 of every file (backend/requirements-mac.lock)
"$PY" -m pip install --disable-pip-version-check --no-warn-script-location --quiet \
    --require-hashes --only-binary=lxml,pillow,brotli,curl_cffi,cryptography,cffi \
    -r "$ROOT/backend/requirements-mac.lock"

echo "==> Copying backend and upstream Komikku"
mkdir -p "$RES/backend" "$RES/upstream"
rsync -a --exclude '__pycache__' --exclude 'tests' "$ROOT/backend/komikku_mac" "$RES/backend/"
rsync -a --exclude '__pycache__' "$ROOT/upstream/komikku" "$RES/upstream/"
mkdir -p "$RES/upstream/data"
cp "$ROOT/upstream/data/info.febvre.Komikku.gschema.xml.in" "$RES/upstream/data/"
cp "$ROOT/upstream/LICENSE" "$RES/upstream/LICENSE"
git -C "$ROOT/upstream" rev-parse --short HEAD > "$RES/upstream/UPSTREAM_COMMIT" 2>/dev/null || true

echo "==> Compiling upstream translations"
"$PY" -m pip install --quiet --disable-pip-version-check --target "$BUILD/tools" \
    --require-hashes -r "$ROOT/scripts/build-tools.lock"
PYTHONPATH="$BUILD/tools" "$PY" "$ROOT/scripts/compile_translations.py" "$ROOT/upstream/po" "$RES/upstream/locale"

echo "==> Third-party licenses"
mkdir -p "$RES/Licenses"
"$PY" -I "$ROOT/scripts/third_party_notices.py" "$RES/python/lib/python$PY_VERSION/site-packages" "$ROOT" \
    "$RES/Licenses/THIRD-PARTY-NOTICES.txt" "$BUILD/copyleft-modules.txt"
cp "$ROOT/LICENSE" "$RES/Licenses/LICENSE"

echo "==> Trimming bundled Python (nothing the app uses at runtime)"
LIB="$RES/python/lib/python$PY_VERSION"
SITE="$LIB/site-packages"
# Stdlib parts for tests, GUI (Tk), docs, package installation
rm -rf "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/turtle.py" \
       "$LIB/ensurepip" "$LIB/pydoc_data" \
       "$LIB/lib-dynload/"_tkinter* \
       "$RES/python/lib/"tcl* "$RES/python/lib/"tk* "$RES/python/lib/"libtcl* "$RES/python/lib/"libtk* \
       "$RES/python/lib/"itcl* "$RES/python/lib/"thread* \
       "$RES/python/share" "$RES/python/include" \
       "$RES/python/bin/"pip* "$RES/python/bin/"idle* "$RES/python/bin/"pydoc*
find "$RES/python" -name '*.a' -delete
# pip itself and build-time-only files of packages
rm -rf "$SITE"/pip "$SITE"/pip-*.dist-info "$SITE/lxml/includes"
find "$SITE" \( -name '*.pyx' -o -name '*.pxd' -o -name '*.pyi' -o -name '*.h' -o -name '*.c' \) -type f -delete
find "$SITE" -type d \( -name tests -o -name test \) -prune -exec rm -rf {} +

echo "==> Precompiling Python (stdlib/packages bytecode-only; backend/upstream keep sources)"
# Everything is compiled before signing: Python must never need to write a .pyc
# inside the bundle afterwards (that would break the code signature).
# Stdlib and third-party packages ship as legacy .pyc next to where the .py was
# (sourceless); os.py stays as the stdlib landmark Python looks for at startup.
# Copyleft packages (GPL/AGPL/MPL, listed by third_party_notices.py) keep their
# sources: they are set aside here and compiled normally afterwards.
KEEP="$BUILD/keep-sources"
rm -rf "$KEEP"; mkdir -p "$KEEP"
while IFS= read -r mod; do
    for p in "$SITE/$mod" "$SITE/$mod.py"; do
        if [[ -e "$p" ]]; then mv "$p" "$KEEP/"; fi
    done
done < "$BUILD/copyleft-modules.txt"
"$PY" -m compileall -q -j 0 -b "$LIB" >/dev/null || true
find "$LIB" -name '*.py' ! -path "$LIB/os.py" -type f -delete
find "$LIB" -name '__pycache__' -type d -prune -exec rm -rf {} +
"$PY" -m compileall -q -j 0 "$LIB/os.py" >/dev/null || true
for p in "$KEEP"/*; do
    [[ -e "$p" ]] || continue
    mv "$p" "$SITE/"
    "$PY" -m compileall -q -j 0 "$SITE/$(basename "$p")" >/dev/null || true
done
# License compliance guard: notices present, copyleft sources really kept
test -s "$RES/Licenses/THIRD-PARTY-NOTICES.txt" && test -s "$RES/Licenses/LICENSE"
while IFS= read -r mod; do
    if [[ -d "$SITE/$mod" ]]; then
        find "$SITE/$mod" -name '*.py' | grep -q . || { echo "Sources of $mod missing" >&2; exit 1; }
    elif [[ ! -f "$SITE/$mod.py" ]]; then
        echo "Sources of $mod missing" >&2; exit 1
    fi
done < "$BUILD/copyleft-modules.txt"
# Our code and upstream Komikku keep their sources (readable tracebacks in the log)
"$PY" -m compileall -q -j 0 "$RES/backend" "$RES/upstream/komikku" >/dev/null || true

echo "==> App localizations (Turkish source, English)"
python3 "$ROOT/scripts/i18n.py" generate "$RES"

echo "==> Info.plist and icon"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" -e "s/@COMMIT@/$COMMIT/" \
    "$ROOT/app/Resources/Info.plist" > "$APP/Contents/Info.plist"
iconutil -c icns "$ROOT/app/Resources/AppIcon.iconset" -o "$RES/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# From here on the bundle is sealed: never let Python write bytecode into it
export PYTHONDONTWRITEBYTECODE=1

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

echo "==> Disk image (drag to Applications)"
rm -f "$DIST/Komikku-macos-$ARCH.dmg"
PYTHONPATH="$BUILD/tools" "$PY" -B -c '
import sys, dmgbuild
app, root, out = sys.argv[1:4]
dmgbuild.build_dmg(out, "Komikku", settings_file=f"{root}/scripts/dmg_settings.py",
                   defines={"app": app, "root": root})
' "$APP" "$ROOT" "$DIST/Komikku-macos-$ARCH.dmg"
hdiutil verify "$DIST/Komikku-macos-$ARCH.dmg"

echo "==> Signature still intact after packaging?"
codesign --verify --deep "$APP"

du -sh "$APP" "$RES/python" "$SITE" "$RES/upstream" "$DIST/Komikku-macos-$ARCH.zip" "$DIST/Komikku-macos-$ARCH.dmg"
echo "Done: $APP"
