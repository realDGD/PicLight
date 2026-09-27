#!/bin/bash
# Regenerate every PicLight app-icon artifact in this directory from src/.
#
#   src/make_art.py   vector artwork generator  -> src/beam.svg, src/artwork.svg
#   src/icon.json     Icon Composer document    -> AppIcon.icon/
#
# Products (all of them are committed; nothing here is wired into the app yet):
#   AppIcon.icon/        Liquid Glass icon document for macOS 26/27 (Xcode 26+/27+)
#   AppIcon.appiconset/  asset-catalog app icon for macOS 14/15 back-compat and the App Store
#   PicLight.iconset/    iconutil source
#   PicLight.icns        loose bundle icon for Info.plist CFBundleIconFile
#   preview/*.png        contact sheets for review
#   build/               intermediates, incl. a real Assets.car produced by actool
#
# Requires: macOS 26+ with Icon Composer (ships with Xcode 26+), Xcode command line tools.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ICT="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
if [ ! -x "$ICT" ]; then
    ICT="$(xcrun --find ictool 2>/dev/null || true)"
fi
if [ ! -x "$ICT" ]; then
    echo "error: ictool not found. It ships inside Icon Composer.app (Xcode 26+):" >&2
    echo "       /Applications/Xcode.app/Contents/Applications/Icon Composer.app" >&2
    echo "       Icon Composer is only available on macOS 26 or later." >&2
    exit 1
fi

DOC="$HERE/AppIcon.icon"
ICONSET="$HERE/PicLight.iconset"
APPICONSET="$HERE/AppIcon.appiconset"
PREVIEW="$HERE/preview"
BUILD="$HERE/build"
TOOLS="$BUILD/bin"

ART_FRACTION=0.8047   # 824/1024: squircle side inside the classic macOS icon canvas
LEGACY_SHADOW=0.30

log() { printf '==> %s\n' "$*"; }

# ------------------------------------------------------------------ tools
log "Compiling helper tools"
mkdir -p "$TOOLS" "$PREVIEW" "$BUILD/masters"
for t in legacy montage imgstat; do
    if [ ! -x "$TOOLS/$t" ] || [ "$HERE/tools/$t.swift" -nt "$TOOLS/$t" ]; then
        swiftc -O -o "$TOOLS/$t" "$HERE/tools/$t.swift"
    fi
done
LEGACY="$TOOLS/legacy"

# ------------------------------------------------------------------ artwork
log "Generating SVG layers"
python3 src/make_art.py src

# ------------------------------------------------------------------ .icon document
log "Assembling AppIcon.icon"
rm -rf "$DOC"
mkdir -p "$DOC/Assets"
cp src/icon.json "$DOC/icon.json"
cp src/beam.svg src/artwork.svg "$DOC/Assets/"

# ------------------------------------------------------------------ master renders
# Every rendition Icon Composer can produce, at 1024, for both design generations.
log "Rendering masters with ictool"
render() { # rendition size out [generation]   (ictool prints a JSON blob on stdout; silence it)
    "$ICT" "$DOC" --export-image --output-file "$3" --platform macOS --rendition "$1" \
        --width "$2" --height "$2" --scale 1 ${4:+--design-generation "$4"} >/dev/null
}
for gen in 26 27; do
    for r in Default Dark TintedLight TintedDark ClearLight ClearDark; do
        render "$r" 1024 "$BUILD/masters/${r}-${gen}.png" "$gen"
    done
done

# ------------------------------------------------------------------ legacy grid + .iconset
# macOS 14/15 show the art on the classic grid: a 824 pt squircle with a drop shadow inside a
# 1024 pt canvas. ictool renders the squircle full-bleed, so each size is rendered at
# size*ART_FRACTION and composited onto the grid by tools/legacy.swift.
log "Building PicLight.iconset on the classic macOS grid"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
build_size() { # pixel-size
    local px="$1" art
    art=$(python3 -c "print(max(8, round($px * $ART_FRACTION)))")
    render Default "$art" "$BUILD/sq-${px}.png" 27 >/dev/null
    "$LEGACY" "$BUILD/sq-${px}.png" "$ICONSET/icon_${2}${3}.png" "$px" "$ART_FRACTION" "$LEGACY_SHADOW" >/dev/null
}
build_size 16  16x16   ""
build_size 32  16x16   "@2x"
build_size 32  32x32   ""
build_size 64  32x32   "@2x"
build_size 128 128x128 ""
build_size 256 128x128 "@2x"
build_size 256 256x256 ""
build_size 512 256x256 "@2x"
build_size 512 512x512 ""
build_size 1024 512x512 "@2x"

log "Packing PicLight.icns"
iconutil -c icns "$ICONSET" -o "$HERE/PicLight.icns"

# ------------------------------------------------------------------ asset catalog
log "Building AppIcon.appiconset"
rm -rf "$APPICONSET"
mkdir -p "$APPICONSET"
cp "$ICONSET"/*.png "$APPICONSET/"
cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# ------------------------------------------------------------------ previews
log "Rendering preview sheets"
PARTS="$BUILD/parts"
rm -rf "$PARTS"; mkdir -p "$PARTS"
render Default 1024 "$PARTS/light-big.png" 27
render Dark    1024 "$PARTS/dark-big.png" 27
for s in 16 32 64 128 256 512; do
    render Default "$s" "$PARTS/light-$s.png" 27
    render Dark    "$s" "$PARTS/dark-$s.png" 27
done
render Default     256 "$PARTS/app-default.png" 27
render ClearLight  256 "$PARTS/app-mono.png" 27
render TintedLight 256 "$PARTS/app-tint.png" 27

if [ ! -x "$TOOLS/sheet" ] || [ "$HERE/tools/sheet.swift" -nt "$TOOLS/sheet" ]; then
    swiftc -O -o "$TOOLS/sheet" "$HERE/tools/sheet.swift"
fi
"$TOOLS/sheet" "$PARTS" "$PREVIEW/00-overview.png"

"$TOOLS/montage" --out "$PREVIEW/01-size-ladder.png" --cols 6 --cell 190x190 \
    --bg 0.93,0.94,0.96 --title "PicLight — true-size ladder, light appearance (macOS 27)" \
    "512=$PARTS/light-512.png" "256=$PARTS/light-256.png" "128=$PARTS/light-128.png" \
    "64=$PARTS/light-64.png" "32=$PARTS/light-32.png" "16=$PARTS/light-16.png"
"$TOOLS/montage" --out "$PREVIEW/02-size-ladder-dark.png" --cols 6 --cell 190x190 \
    --bg 0.15,0.16,0.19 --title "PicLight — true-size ladder, dark appearance (macOS 27)" \
    "512=$PARTS/dark-512.png" "256=$PARTS/dark-256.png" "128=$PARTS/dark-128.png" \
    "64=$PARTS/dark-64.png" "32=$PARTS/dark-32.png" "16=$PARTS/dark-16.png"
"$TOOLS/montage" --out "$PREVIEW/03-renditions.png" --cols 6 --cell 210x210 \
    --bg 0.55,0.57,0.61 --title "All six renditions Icon Composer can produce (macOS 27)" \
    "Default=$BUILD/masters/Default-27.png" "Dark=$BUILD/masters/Dark-27.png" \
    "TintedLight=$BUILD/masters/TintedLight-27.png" "TintedDark=$BUILD/masters/TintedDark-27.png" \
    "ClearLight=$BUILD/masters/ClearLight-27.png" "ClearDark=$BUILD/masters/ClearDark-27.png"
"$TOOLS/montage" --out "$PREVIEW/04-design-generation.png" --cols 4 --cell 320x320 \
    --bg 0.55,0.57,0.61 --title "macOS 26 vs macOS 27 design generation (same document)" \
    "26 Default=$BUILD/masters/Default-26.png" "27 Default=$BUILD/masters/Default-27.png" \
    "26 Dark=$BUILD/masters/Dark-26.png" "27 Dark=$BUILD/masters/Dark-27.png"
"$TOOLS/montage" --out "$PREVIEW/05-legacy-iconset.png" --cols 6 --cell 190x190 \
    --bg 0.93,0.94,0.96 --title "Legacy grid for macOS 14–15 (824/1024 squircle + shadow)" \
    "16=$ICONSET/icon_16x16.png" "32=$ICONSET/icon_32x32.png" "64=$ICONSET/icon_32x32@2x.png" \
    "128=$ICONSET/icon_128x128.png" "256=$ICONSET/icon_256x256.png" "512=$ICONSET/icon_512x512.png"

# ------------------------------------------------------------------ verify
log "Verifying"
"$TOOLS/imgstat" "$ICONSET/icon_512x512@2x.png" | grep -E "alpha bbox|coverage"
echo "    (shipped system icons measure side/canvas 0.8516 — this must match)"

CAROK="no"
if xcrun --find actool >/dev/null 2>&1; then
    rm -rf "$BUILD/car"; mkdir -p "$BUILD/car"
    TMPDOC="$BUILD/AppIcon.icon"
    rm -rf "$TMPDOC"; cp -R "$DOC" "$TMPDOC"
    if xcrun actool --output-format human-readable-text --notices --warnings --errors \
        --platform macosx --target-device mac --minimum-deployment-target 14.0 \
        --app-icon AppIcon --include-all-app-icons \
        --output-partial-info-plist "$BUILD/car/partial.plist" \
        --compile "$BUILD/car" "$APPICONSET" "$TMPDOC" >"$BUILD/car/actool.log" 2>&1; then
        CAROK="yes"
        echo "    actool: ok -> $(cd "$BUILD/car" && ls | tr '\n' ' ')"
    else
        echo "    actool: FAILED (see build/car/actool.log)" >&2
        sed 's/^/        /' "$BUILD/car/actool.log" >&2
    fi
else
    echo "    actool: not available, skipped"
fi

log "Done. Products:"
echo "    AppIcon.icon/        $(du -sh "$DOC" | cut -f1)"
echo "    AppIcon.appiconset/  $(du -sh "$APPICONSET" | cut -f1)"
echo "    PicLight.icns        $(du -h "$HERE/PicLight.icns" | cut -f1)"
echo "    preview/             $(ls "$PREVIEW" | grep -c '\.png$') sheets"
echo "    Assets.car           $CAROK"
