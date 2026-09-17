#!/bin/bash
# Creates dist/PicViewMac-<version>.dmg containing the app and an Applications
# shortcut, so installation is a single drag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
DIST="$ROOT/dist"
APP="$DIST/PicViewMac.app"
DMG="$DIST/PicViewMac-$VERSION.dmg"
STAGING="$DIST/dmg-staging"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/build-release.sh first" >&2
    exit 1
fi

echo "==> Staging DMG contents"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
hdiutil create -volname "PicViewMac" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

rm -rf "$STAGING"
echo "==> Built $DMG"
ls -lh "$DMG" | awk '{print $5, $9}'
