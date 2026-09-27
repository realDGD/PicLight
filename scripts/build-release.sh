#!/bin/bash
# Builds PicLight.app as an independent bundle (no App Store, no paid
# Developer Program required) and ad-hoc signs it for structural integrity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
DIST="$ROOT/dist"
APP_NAME="PicLight"
APP="$DIST/$APP_NAME.app"
BUNDLE_ID="com.example.picviewmac"
# Declared in LSMinimumSystemVersion *and* passed to actool, which uses it to
# decide which icon renditions to flatten: a minimum that is not the real one
# would build the wrong back-compat icon.
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-14.0}"

echo "==> Building $CONFIGURATION binary"
swift build -c "$CONFIGURATION"
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/PicViewMac"
test -x "$BIN"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# --------------------------------------------------------------- Metal shader
# A shipped app must carry a *compiled* Metal library: MetalLibraryLocator prefers it
# and only falls back to compiling the shipped .metal source in development.
RESOURCE_BUNDLE="$(swift build -c "$CONFIGURATION" --show-bin-path)/PicViewMac_PicViewMac.bundle"
BUNDLE_IN_APP="$APP/Contents/Resources/PicViewMac_PicViewMac.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$BUNDLE_IN_APP"
    echo "==> Copied $(basename "$RESOURCE_BUNDLE") into the app"
else
    echo "error: SwiftPM resource bundle not found at $RESOURCE_BUNDLE" >&2
    exit 1
fi

METALLIB="$BUNDLE_IN_APP/Contents/Resources/default.metallib"
SHADER="$ROOT/PicViewMac/Shaders/ImageShaders.metal"
WORK="$(mktemp -d)"
if xcrun -sdk macosx metal -c "$SHADER" -o "$WORK/ImageShaders.air" 2>"$WORK/metal.log" \
   && xcrun -sdk macosx metallib "$WORK/ImageShaders.air" -o "$METALLIB"; then
    echo "==> Compiled ImageShaders.metal -> default.metallib ($(stat -f%z "$METALLIB") bytes)"
else
    if [ "${PICLIGHT_ALLOW_SOURCE_SHADER:-0}" = "1" ]; then
        echo "WARNING: Metal toolchain unavailable; packaging the shader SOURCE only." >&2
        echo "         This is a DEVELOPMENT build and must not be shipped;" >&2
        echo "         verify-release.sh will report the compiled-library check as SKIPPED." >&2
    else
        echo "error: cannot compile the Metal shader into default.metallib." >&2
        sed 's/^/       /' "$WORK/metal.log" >&2 || true
        echo "       Install the toolchain:  xcodebuild -downloadComponent MetalToolchain" >&2
        echo "       Development-only override: PICLIGHT_ALLOW_SOURCE_SHADER=1" >&2
        rm -rf "$WORK" "$APP"
        exit 1
    fi
fi
rm -rf "$WORK"

# ------------------------------------------------------------------- app icon
# macOS reads an app icon out of the bundle, never out of the executable, so
# without these two files PicLight.app shows the generic application icon in
# Finder, in the Dock and in ⌘-Tab.
#
#   macOS 26 / 27   CFBundleIconName -> Assets.car    (the Icon Composer icon
#                   stack: the system renders the light, dark, clear and tinted
#                   appearances from it)
#   macOS 14 / 15   CFBundleIconFile -> PicLight.icns (flat renditions, 16–1024)
#
# actool emits a PicLight.icns of its own, but only 16–256 px: the document is
# full-bleed artwork and there is no 512/1024 flat source for it to flatten, so
# its fallback would be upscaled in Finder on macOS 14/15. The complete,
# reviewed .icns is shipped here instead. See Resources/AppIcon/README.md.
ICON_DIR="$ROOT/Resources/AppIcon"
ICON_NAME="PicLight"
ICON_DOC="$ICON_DIR/$ICON_NAME.icon"
ICON_ICNS="$ICON_DIR/$ICON_NAME.icns"
ICON_WORK="$(mktemp -d)"
mkdir -p "$ICON_WORK/car"

ASSET_CAR_READY=0
if [ ! -d "$ICON_DOC" ]; then
    echo "error: icon document not found at $ICON_DOC" >&2
    rm -rf "$ICON_WORK" "$APP"
    exit 1
fi
if xcrun actool --output-format human-readable-text --notices --warnings --errors \
    --platform macosx --target-device mac \
    --minimum-deployment-target "$MINIMUM_SYSTEM_VERSION" \
    --app-icon "$ICON_NAME" \
    --output-partial-info-plist "$ICON_WORK/partial.plist" \
    --compile "$ICON_WORK/car" "$ICON_DOC" >"$ICON_WORK/actool.log" 2>&1; then
    cp "$ICON_WORK/car/Assets.car" "$APP/Contents/Resources/Assets.car"
    ASSET_CAR_READY=1
    echo "==> Compiled $ICON_NAME.icon -> Assets.car ($(stat -f%z "$APP/Contents/Resources/Assets.car") bytes)"
elif [ "${PICLIGHT_ALLOW_LOOSE_ICON:-0}" = "1" ]; then
    echo "WARNING: actool could not compile $ICON_NAME.icon; shipping the .icns only." >&2
    echo "         macOS 26/27 then wrap that in their own generic material and" >&2
    echo "         verify-release.sh reports the icon stack as SKIPPED." >&2
    sed 's/^/       /' "$ICON_WORK/actool.log" >&2 || true
else
    echo "error: actool could not compile $ICON_NAME.icon into Assets.car." >&2
    sed 's/^/       /' "$ICON_WORK/actool.log" >&2 || true
    echo "       actool ships with Xcode: xcrun actool. macOS 26/27 take the icon from it." >&2
    echo "       Development-only override: PICLIGHT_ALLOW_LOOSE_ICON=1" >&2
    rm -rf "$ICON_WORK" "$APP"
    exit 1
fi

if [ -f "$ICON_ICNS" ]; then
    cp "$ICON_ICNS" "$APP/Contents/Resources/$ICON_NAME.icns"
    echo "==> Packaged $ICON_NAME.icns ($(stat -f%z "$APP/Contents/Resources/$ICON_NAME.icns") bytes)"
else
    echo "error: loose icon not found at $ICON_ICNS" >&2
    rm -rf "$ICON_WORK" "$APP"
    exit 1
fi
rm -rf "$ICON_WORK"

# Frame the icon keys for the Info.plist below. CFBundleIconName is written only
# when the catalog that defines it was actually compiled.
ICON_PLIST_ENTRIES=""
if [ "$ASSET_CAR_READY" = "1" ]; then
    ICON_PLIST_ENTRIES="    <key>CFBundleIconName</key><string>$ICON_NAME</string>
"
fi
ICON_PLIST_ENTRIES="$ICON_PLIST_ENTRIES    <key>CFBundleIconFile</key><string>$ICON_NAME</string>
"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PicLight</string>
    <key>CFBundleDisplayName</key><string>PicLight</string>
    <key>CFBundleExecutable</key><string>PicLight</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
${ICON_PLIST_ENTRIES}    <key>LSMinimumSystemVersion</key><string>$MINIMUM_SYSTEM_VERSION</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.bmp</string>
                <string>com.compuserve.gif</string>
                <string>com.microsoft.ico</string>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>public.tiff</string>
                <string>org.webmproject.webp</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Built $APP"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
if [ "$ASSET_CAR_READY" = "1" ]; then
    echo "    icon: Assets.car (macOS 26/27) + $ICON_NAME.icns (macOS 14/15)"
else
    echo "    icon: $ICON_NAME.icns only — no Assets.car (development build)"
fi
