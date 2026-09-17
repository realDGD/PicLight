#!/bin/bash
# Verifies the built release artifacts without a display: bundle structure,
# signature, runtime dependencies, deployment target, DMG contents, and the
# in-app acceptance runner launched from the mounted DMG.
#
# Usage: ./scripts/verify-release.sh [image-for-selftest]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="${APP_NAME:-PicLight}"
APP="${APP:-$ROOT/dist/$APP_NAME.app}"
BINARY="$APP/Contents/MacOS/$APP_NAME"
DMG="${DMG:-$(ls "$ROOT"/dist/"$APP_NAME"-*.dmg 2>/dev/null | head -1 || true)}"
SELFTEST_IMAGE="${1:-}"
EXPECTED_VERSION="${EXPECTED_VERSION:-0.1.0}"
EXPECTED_MINOS="${EXPECTED_MINOS:-14.0}"

PASS=0
FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
note() { echo "NOTE $1"; }

[ -d "$APP" ] || { echo "error: $APP not found; run scripts/build-release.sh first" >&2; exit 1; }

# ---------------------------------------------------------------- bundle layout
if [ -x "$BINARY" ]; then pass "bundle executable present"; else fail "bundle executable missing"; fi
if [ -f "$APP/Contents/Info.plist" ]; then pass "Info.plist present"; else fail "Info.plist missing"; fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "")
if [ "$VERSION" = "$EXPECTED_VERSION" ]; then
    pass "bundle version is $EXPECTED_VERSION"
else
    fail "bundle version is '$VERSION', expected '$EXPECTED_VERSION'"
fi

MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "")
if [ "$MINOS" = "$EXPECTED_MINOS" ]; then
    pass "declared minimum system version is $EXPECTED_MINOS"
else
    fail "declared minimum system version is '$MINOS', expected '$EXPECTED_MINOS'"
fi

# Finder-visible document types must cover the required formats.
DOC_TYPES=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:0:LSItemContentTypes" \
    "$APP/Contents/Info.plist" 2>/dev/null | tr -d ' ' | sort | tr '\n' ',' || echo "")
for uti in com.microsoft.bmp com.compuserve.gif com.microsoft.ico public.png public.jpeg public.tiff org.webmproject.webp; do
    case "$DOC_TYPES" in
        *"$uti"*) ;;
        *) fail "document types do not declare $uti" ;;
    esac
done
pass "declared document types cover the v0.1 formats"

# ------------------------------------------------------------- code signature
if codesign --verify --deep --strict --verbose=2 "$APP" 2>/dev/null; then
    pass "codesign --verify --deep --strict"
else
    fail "codesign verification failed"
fi

SIGN_INFO=$(codesign -dv --verbose=2 "$APP" 2>&1 || true)
if echo "$SIGN_INFO" | grep -q "Signature=adhoc"; then
    pass "ad-hoc signed (no Apple Developer Program required)"
else
    note "signature is not ad-hoc; raw codesign output follows"
    echo "$SIGN_INFO" | sed 's/^/      /'
fi

# ------------------------------------------------------- runtime dependencies
DEPS=$(otool -L "$BINARY" | tail -n +2 | awk '{print $1}')
if echo "$DEPS" | grep -q "^/opt/homebrew\|^/usr/local/"; then
    fail "binary links a package-manager library:"
    echo "$DEPS" | grep "^/opt/homebrew\|^/usr/local/" | sed 's/^/      /'
else
    pass "no Homebrew or /usr/local runtime library dependencies"
fi

if echo "$DEPS" | grep -qi "webp"; then
    fail "binary links a WebP library; system ImageIO must be the only decoder"
else
    pass "no libwebp dependency (system ImageIO only)"
fi

UNEXPECTED=$(echo "$DEPS" | grep -v "^/System/Library/\|^/usr/lib/" || true)
if [ -z "$UNEXPECTED" ]; then
    pass "all runtime libraries come from the system"
else
    note "non-system runtime libraries:"
    echo "$UNEXPECTED" | sed 's/^/      /'
fi
note "linked libraries: $(echo "$DEPS" | tr '\n' ' ')"

# --------------------------------------------------------------- build version
BUILD_INFO=$(otool -l "$BINARY" | awk '/LC_BUILD_VERSION/{flag=1} flag&&/minos/{print $2; exit}')
if [ "$BUILD_INFO" = "$EXPECTED_MINOS" ]; then
    pass "Mach-O deployment target is macOS $EXPECTED_MINOS"
else
    fail "Mach-O deployment target is '$BUILD_INFO', expected '$EXPECTED_MINOS'"
fi

# ------------------------------------------------------------- fixture freedom
if strings "$BINARY" 2>/dev/null | grep -q "make-fixtures"; then
    fail "binary references the fixture generator"
else
    pass "binary does not reference the fixture generator"
fi
for tool in cwebp img2webp dwebp; do
    if strings "$BINARY" 2>/dev/null | grep -qw "$tool"; then
        fail "binary references $tool"
    fi
done
pass "binary does not reference the webp CLI tools"

# ------------------------------------------------------------------ DMG checks
if [ -n "$DMG" ] && [ -f "$DMG" ]; then
    if hdiutil verify "$DMG" >/dev/null 2>&1; then
        pass "DMG checksum verifies ($(basename "$DMG"))"
    else
        fail "DMG checksum verification failed"
    fi

    MOUNT_POINT=$(hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null | grep -o '/Volumes/.*' | head -1 || true)
    if [ -n "$MOUNT_POINT" ]; then
        if [ -d "$MOUNT_POINT/$APP_NAME.app" ]; then
            pass "DMG contains $APP_NAME.app"
        else
            fail "DMG does not contain the app"
        fi
        if [ -L "$MOUNT_POINT/Applications" ]; then
            pass "DMG contains the Applications shortcut"
        else
            fail "DMG is missing the Applications shortcut"
        fi
        if codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME.app" 2>/dev/null; then
            pass "mounted bundle signature verifies"
        else
            fail "mounted bundle signature does not verify"
        fi

        MOUNTED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "$MOUNT_POINT/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "")
        if [ "$MOUNTED_VERSION" = "$EXPECTED_VERSION" ]; then
            pass "mounted bundle version is $EXPECTED_VERSION"
        else
            fail "mounted bundle version is '$MOUNTED_VERSION'"
        fi

        if [ -n "$SELFTEST_IMAGE" ] && [ -f "$SELFTEST_IMAGE" ]; then
            SELFTEST_OUTPUT=$(PICVIEW_SELFTEST="$SELFTEST_IMAGE" \
                "$MOUNT_POINT/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>&1 || true)
            if echo "$SELFTEST_OUTPUT" | grep -q "=== ALL PASSED ==="; then
                CHECKS=$(echo "$SELFTEST_OUTPUT" | grep -cE "^(PASS|FAIL)")
                pass "acceptance runner passes from the mounted DMG ($CHECKS checks)"
            else
                fail "acceptance runner failed from the mounted DMG"
                echo "$SELFTEST_OUTPUT" | tail -20 | sed 's/^/      /'
            fi
        else
            note "no image supplied for the mounted-DMG acceptance run (pass one as \$1)"
        fi

        hdiutil detach "$MOUNT_POINT" -quiet || true
    else
        fail "could not mount $DMG"
    fi
else
    note "no DMG found in dist/; skipping DMG checks"
fi

echo
echo "=== verify-release: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
