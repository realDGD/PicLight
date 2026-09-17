#!/bin/bash
# Builds the Quick Look spike. Deliberately outside the package: nothing here is
# linked into the app, and no production target may depend on QuickLookThumbnailing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/qlspike"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 \
    -framework QuickLookThumbnailing -framework AppKit -framework ImageIO \
    -o "$OUT" "$HERE/main.swift"

echo "built $OUT"
