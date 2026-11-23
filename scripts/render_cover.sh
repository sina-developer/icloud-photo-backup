#!/bin/bash
# Renders docs/cover.html to docs/assets/cover.png (1280x640, also used as the
# GitHub social preview). Needs Google Chrome.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1280,640 --screenshot="$(pwd)/docs/assets/cover@2x.png" \
  "file://$(pwd)/docs/cover.html" 2>/dev/null
sips -z 640 1280 docs/assets/cover@2x.png --out docs/assets/cover.png >/dev/null
echo "Rendered docs/assets/cover.png and docs/assets/cover@2x.png"
