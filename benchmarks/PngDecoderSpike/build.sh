#!/bin/bash
# Builds the PNG decoder spike (libspng driver + the same-session ImageIO control).
# The upstream clone is kept under .work/ and is never part of the package: no
# production target links libspng, and no source from it is vendored into PicViewMac.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/.work"
LIBSPNG="${LIBSPNG_DIR:-$WORK/libspng}"

if [ ! -f "$LIBSPNG/spng/spng.c" ]; then
    mkdir -p "$WORK"
    echo "cloning libspng v0.7.4 into $LIBSPNG" >&2
    git clone --depth 1 --branch v0.7.4 https://github.com/randy408/libspng.git "$LIBSPNG" >&2
fi

cc -O2 -I "$LIBSPNG/spng" -o "$HERE/pngspike" "$HERE/pngspike.c" "$LIBSPNG/spng/spng.c" -lz
echo "built $HERE/pngspike (libspng $(grep -m1 SPNG_VERSION_STRING "$LIBSPNG/spng/spng.h" | tr -d ' '))"

SDK="$(xcrun --show-sdk-path --sdk macosx)"
swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 -framework ImageIO \
    -o "$HERE/control" "$HERE/control.swift"
echo "built $HERE/control"
