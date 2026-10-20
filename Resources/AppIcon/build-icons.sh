#!/bin/bash
# Repack PicLight.icns — the loose icon macOS 14/15 read through CFBundleIconFile —
# from the Icon Composer document next to this script.
#
#   Resources/AppIcon/build-icons.sh
#
# The document is the source; this script never edits it. macOS 26/27 do not read
# this file: they take the icon stack that `actool` compiles from the same
# document (scripts/precompile-resources.py update builds it). This
# pack exists for the back-deployment path and as the fallback when actool is
# unavailable. See README.md.
#
# Requires: macOS 26+ with Icon Composer (ships inside Xcode 26+), swiftc, iconutil.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

DOC="PicLight.icon"
ICNS="PicLight.icns"

ICT="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
if [ ! -x "$ICT" ]; then
    ICT="$(xcrun --find ictool 2>/dev/null || true)"
fi
if [ ! -x "$ICT" ]; then
    echo "error: ictool not found. It ships inside Icon Composer.app (Xcode 26+):" >&2
    echo "       /Applications/Xcode.app/Contents/Applications/Icon Composer.app" >&2
    exit 1
fi
[ -d "$DOC" ] || { echo "error: $DOC not found next to this script" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The classic canvas: an 824/1024 tile plus a short shadow. The packed result
# measures side/canvas 0.8477 at 1024 px, against 0.8516 measured on Apple's own
# system icons; the tile alone is 824/1024 = 0.8046875.
ART_FRACTION=0.8046875
SHADOW_ALPHA=0.25

echo "==> Rendering the default appearance at 1024"
"$ICT" "$DOC" --export-image --output-file "$WORK/master.png" --platform macOS \
    --rendition Default --width 1024 --height 1024 --scale 1 --design-generation 26 >/dev/null

echo "==> Composing the classic grid"
swiftc -O tools/export-grid.swift -o "$WORK/export-grid"
ICONSET="$WORK/PicLight.iconset"
mkdir -p "$ICONSET"
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
    points="${spec%%:*}"
    scale="${spec##*:}"
    suffix=""
    if [ "$scale" = "2" ]; then suffix="@2x"; fi
    "$WORK/export-grid" "$WORK/master.png" "$ICONSET/icon_${points}x${points}${suffix}.png" \
        "$((points * scale))" "$ART_FRACTION" "$SHADOW_ALPHA" >/dev/null
done

echo "==> Packing $ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"
echo "    $(stat -f%z "$ICNS") bytes, $(ls "$ICONSET" | wc -l | tr -d ' ') renditions"
