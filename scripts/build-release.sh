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

echo "==> Building $CONFIGURATION binary"
swift build -c "$CONFIGURATION"
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/PicViewMac"
test -x "$BIN"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cp "$ROOT/Resources/Assets.xcassets/Contents.json" "$APP/Contents/Resources/Assets.json" 2>/dev/null || true

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
    <key>LSMinimumSystemVersion</key><string>14.0</string>
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
