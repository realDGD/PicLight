#!/bin/bash
# Builds PicLight.app as an independent bundle (no App Store, no paid
# Developer Program required) and ad-hoc signs it for structural integrity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A process-local default: leave xcode-select and the installed Xcode untouched.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
DIST="$ROOT/dist"
APP_NAME="PicLight"
APP="$DIST/$APP_NAME.app"
BUNDLE_ID="com.example.picviewmac"
# Must match the precompiled resources' deployment target.
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-14.0}"
PRECOMPILED="$ROOT/Resources/Precompiled"

# Fail before Swift or any replacement of the previous app. Daily packaging
# never invokes actool, metal or metallib, and never silently uses stale assets.
python3 "$ROOT/scripts/precompile-resources.py" check \
    --minimum-system-version "$MINIMUM_SYSTEM_VERSION"

echo "==> Building $CONFIGURATION binary"
SWIFT_BUILD_ARGS=(-c "$CONFIGURATION")
# Homebrew already provides the outer build sandbox; SwiftPM cannot nest one.
if [ "${PICLIGHT_SWIFTPM_DISABLE_SANDBOX:-0}" = "1" ]; then
    SWIFT_BUILD_ARGS+=(--disable-sandbox)
fi
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/PicViewMac"
test -x "$BIN"

# Recheck after compilation in case inputs changed while Swift was building.
python3 "$ROOT/scripts/precompile-resources.py" check \
    --minimum-system-version "$MINIMUM_SYSTEM_VERSION"
RESOURCE_BUNDLE="$BIN_DIR/PicViewMac_PicViewMac.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "error: SwiftPM resource bundle not found at $RESOURCE_BUNDLE" >&2
    exit 1
fi

# Assemble and sign off to the side; failures preserve the previous app.
FINAL_APP="$APP"
mkdir -p "$DIST"
STAGING="$(mktemp -d "$DIST/.PicLight-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/$APP_NAME.app"
echo "==> Assembling $FINAL_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
BUNDLE_IN_APP="$APP/Contents/Resources/PicViewMac_PicViewMac.bundle"
cp -R "$RESOURCE_BUNDLE" "$BUNDLE_IN_APP"
mkdir -p "$BUNDLE_IN_APP/Contents/Resources"
cp "$PRECOMPILED/default.metallib" "$BUNDLE_IN_APP/Contents/Resources/default.metallib"
cp "$PRECOMPILED/Assets.car" "$APP/Contents/Resources/Assets.car"
ICON_NAME="PicLight"
# Keep the reviewed 16–1024 px fallback. actool's generated ICNS has fewer sizes.
cp "$ROOT/Resources/AppIcon/$ICON_NAME.icns" "$APP/Contents/Resources/$ICON_NAME.icns"
echo "==> Copied validated Metal library, icon catalog and ICNS"
ICON_PLIST_ENTRIES="    <key>CFBundleIconName</key><string>$ICON_NAME</string>
    <key>CFBundleIconFile</key><string>$ICON_NAME</string>
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

# Publish only the signed result; restore the previous app if the move fails.
if [ -e "$FINAL_APP" ]; then
    mv "$FINAL_APP" "$STAGING/previous.app"
fi
if ! mv "$APP" "$FINAL_APP"; then
    if [ -e "$STAGING/previous.app" ]; then
        mv "$STAGING/previous.app" "$FINAL_APP"
    fi
    exit 1
fi
echo "==> Built $FINAL_APP"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$FINAL_APP/Contents/Info.plist"
echo "    icon: Assets.car (macOS 26/27) + $ICON_NAME.icns (macOS 14/15)"
