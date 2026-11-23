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
PYTHON="${PYTHON:-python3}"

echo "==> Building $APP_NAME $VERSION ($ARCH)"

# 1. Build environment (pinned versions in requirements-build.txt)
if [ ! -x "$VENV/bin/pyinstaller" ] || ! cmp -s requirements-build.txt "$VENV/.requirements"; then
  rm -rf "$VENV"
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r requirements-build.txt
  cp requirements-build.txt "$VENV/.requirements"
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
swiftc -O -target "$ARCH-apple-macos12.0" \
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
  <key>LSMinimumSystemVersion</key><string>12.0</string>
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
