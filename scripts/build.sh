#!/bin/bash
# Builds a self-contained "iCloud Photo Backup.app" (Python + icloudpd bundled inside)
# and a versioned DMG in dist/. Nothing needs to be installed on the Mac that runs the app.
#
# Usage: scripts/build.sh            (uses VERSION file)
# Env:   PYTHON=/path/to/python3     (Python used for the build venv; default: python3 on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(tr -d '[:space:]' < VERSION)"
ARCH="$(uname -m)"
APP_NAME="iCloud Photo Backup"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/iCloud-Photo-Backup-$VERSION-$ARCH.dmg"
BUILD="$ROOT/.build"
VENV="$BUILD/venv"
MIN_MACOS="12.0"   # oldest macOS the app supports

# The bundled Python must run on MIN_MACOS. Homebrew's Python is built only for the
# macOS it was installed on, so prefer the python.org installer's Python when present.
if [ -z "${PYTHON:-}" ]; then
  PYTHON="$(ls /Library/Frameworks/Python.framework/Versions/3.1[0-9]/bin/python3 2>/dev/null | sort -V | tail -1 || true)"
  PYTHON="${PYTHON:-python3}"
fi
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

echo "==> Building $APP_NAME $VERSION ($ARCH) with $("$PYTHON" -c 'import sys; print(sys.executable)')"

# 1. Build environment (pinned versions in requirements-build.txt)
STAMP="$(cat requirements-build.txt; "$PYTHON" -c 'import sys; print(sys.executable, sys.version)')"
if [ ! -x "$VENV/bin/pyinstaller" ] || [ "$STAMP" != "$(cat "$VENV/.stamp" 2>/dev/null)" ]; then
  rm -rf "$VENV"
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r requirements-build.txt
  echo "$STAMP" > "$VENV/.stamp"
fi

# 2. Freeze the server with its own Python, and add the official standalone
#    icloudpd binary (the icloudpd wheel on PyPI ships one that needs no Python).
rm -rf "$BUILD/dist" "$BUILD/work"
"$VENV/bin/pyinstaller" --noconfirm --clean --log-level WARN \
  --name icpb-engine --onedir \
  --distpath "$BUILD/dist" --workpath "$BUILD/work" --specpath "$BUILD" \
  --add-data "$ROOT/app/index.html:." \
  --add-data "$ROOT/VERSION:." \
  "$ROOT/app/server.py"
ICLOUDPD_DIR="$("$VENV/bin/python" -c 'import icloudpd, os; print(os.path.dirname(icloudpd.__file__))')"
cp "$ICLOUDPD_DIR/icloudpd" "$BUILD/dist/icpb-engine/icloudpd"
chmod +x "$BUILD/dist/icpb-engine/icloudpd"

# Guard: every binary in the engine must run on MIN_MACOS, or the app fails on
# older Macs with "The backup engine stopped unexpectedly (code 255)".
TOO_NEW="$(find "$BUILD/dist/icpb-engine" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' -o -name Python \) -print0 |
  xargs -0 -n1 sh -c 'v=$(otool -l "$0" 2>/dev/null | grep -A4 LC_BUILD_VERSION | awk "/minos/{print \$2; exit}"); [ -n "$v" ] && echo "$v $0"' |
  awk -v min="$MIN_MACOS" '{ split($1,a,"."); split(min,b,"."); if (a[1]+0 > b[1]+0 || (a[1]+0 == b[1]+0 && a[2]+0 > b[2]+0)) print }')"
if [ -n "$TOO_NEW" ]; then
  echo "ERROR: these files need a newer macOS than $MIN_MACOS:" >&2
  echo "$TOO_NEW" | head -5 >&2
  echo "Build with Python from python.org (https://www.python.org/downloads/macos/), e.g. PYTHON=/Library/Frameworks/Python.framework/Versions/3.12/bin/python3" >&2
  exit 1
fi

# 3. App bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/licenses"
cp -R "$BUILD/dist/icpb-engine" "$APP/Contents/Resources/engine"

# Licenses of everything we ship
cp LICENSE "$APP/Contents/Resources/licenses/iCloud-Photo-Backup-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/licenses/"
ICLOUDPD_LICENSE="$(find "$VENV/lib" -path '*icloudpd-*.dist-info/licenses/LICENSE*' | head -1)"
[ -n "$ICLOUDPD_LICENSE" ] && cp "$ICLOUDPD_LICENSE" "$APP/Contents/Resources/licenses/icloudpd-LICENSE.md"

# Native window app (Swift + WebKit) that runs the engine and shows its interface.
swiftc -O -target "$ARCH-apple-macos$MIN_MACOS" \
  -framework Cocoa -framework WebKit \
  -o "$APP/Contents/MacOS/iCloudPhotoBackup" "$ROOT/app/main.swift"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>iCloud Photo Backup</string>
  <key>CFBundleDisplayName</key><string>iCloud Photo Backup</string>
  <key>CFBundleIdentifier</key><string>io.github.icloud-photo-backup</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>iCloudPhotoBackup</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Developed by c-na.dev · MIT License. Not affiliated with Apple Inc.</string>
</dict></plist>
EOF

# 4. App icon (cloud with arrow), rendered once with Swift
ICNS="$BUILD/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
  TMP="$(mktemp -d)"
  swift "$ROOT/scripts/make_icon.swift" "$TMP/icon.png"
  ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$TMP"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# 5. Ad-hoc code signature (required on Apple Silicon; the app is not notarized)
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# 6. DMG with an Applications shortcut for drag-to-install
STAGE="$BUILD/dmg"
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "==> Built: $APP"
echo "==> Built: $DMG ($(du -h "$DMG" | cut -f1))"
