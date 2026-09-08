#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="蝉舒宝"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
BUNDLE_DIR="$OUTPUT_DIR/$APP_NAME.app"
EXECUTABLE="MergeSASE"

echo "=== Building $APP_NAME ==="

swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM_BINARY=".build/arm64-apple-macosx/release/$EXECUTABLE"
X86_BINARY=".build/x86_64-apple-macosx/release/$EXECUTABLE"
if [ ! -f "$ARM_BINARY" ] || [ ! -f "$X86_BINARY" ]; then
    echo "ERROR: Build failed, executable not found"
    exit 1
fi

echo "=== Creating .app bundle ==="
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

/usr/bin/lipo -create "$ARM_BINARY" "$X86_BINARY" -output "$BUNDLE_DIR/Contents/MacOS/$EXECUTABLE"
/usr/bin/lipo "$BUNDLE_DIR/Contents/MacOS/$EXECUTABLE" -verify_arch arm64 x86_64
cp Info.plist "$BUNDLE_DIR/Contents/"
echo -n "APPL????" > "$BUNDLE_DIR/Contents/PkgInfo"

# Generate icns from PNG
if [ -f "../图标.png" ]; then
    cp "../图标.png" "$BUNDLE_DIR/Contents/Resources/AppIcon.png"
    ICONSET="/tmp/ChanShuBao.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "../图标.png" --out "$ICONSET/icon_${size}x${size}.png" 2>/dev/null
        sips -z $((size*2)) $((size*2)) "../图标.png" --out "$ICONSET/icon_${size}x${size}@2x.png" 2>/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$BUNDLE_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null
    rm -rf "$ICONSET"
    echo "  App icon created"
fi

if [ -f "Resources/Title.svg" ]; then
    cp "Resources/Title.svg" "$BUNDLE_DIR/Contents/Resources/Title.svg"
    TITLE_TMP="/tmp/ChanShuBaoTitle"
    rm -rf "$TITLE_TMP"
    mkdir -p "$TITLE_TMP"
    TITLE_SVG="$TITLE_TMP/Title.svg"
    sed -E '0,/<svg width="[^"]+" height="[^"]+"/s//<svg width="1304" height="1872"/' "Resources/Title.svg" > "$TITLE_SVG"
    TITLE_RAW="$TITLE_TMP/Title.raw.png"
    if sips -s format png "$TITLE_SVG" --out "$TITLE_RAW" >/dev/null 2>&1 \
        && sips -z 1872 1304 "$TITLE_RAW" --out "$BUNDLE_DIR/Contents/Resources/Title.png" >/dev/null 2>&1; then
        echo "  Splash title created"
    fi
    rm -rf "$TITLE_TMP"
fi

# Local builds use ad-hoc signing. Release packaging requires Developer ID.
xattr -cr "$BUNDLE_DIR" 2>/dev/null
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$BUNDLE_DIR"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BUNDLE_DIR"
fi
codesign --verify --deep --strict "$BUNDLE_DIR"

echo "=== Done: $BUNDLE_DIR ==="
echo "Run: open $BUNDLE_DIR"

if [ "${PACKAGE:-0}" = "1" ]; then
    APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
    if [ -z "${RELEASE_VERSION:-}" ] || [ "${RELEASE_VERSION#v}" != "$APP_VERSION" ]; then
        echo "ERROR: RELEASE_VERSION must match Info.plist version $APP_VERSION"
        exit 1
    fi
    if [ "$SIGN_IDENTITY" = "-" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
        echo "ERROR: Release packaging requires SIGN_IDENTITY and NOTARY_PROFILE"
        exit 1
    fi
    if [ -z "${EXPECTED_TEAM_ID:-}" ]; then
        echo "ERROR: Release packaging requires EXPECTED_TEAM_ID"
        exit 1
    fi
    if ! codesign -dv --verbose=4 "$BUNDLE_DIR" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
        echo "ERROR: Release packaging requires a Developer ID Application signature"
        exit 1
    fi
    ACTUAL_TEAM_ID=$(codesign -dv --verbose=4 "$BUNDLE_DIR" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
    if [ "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]; then
        echo "ERROR: Signed Team ID $ACTUAL_TEAM_ID does not match EXPECTED_TEAM_ID"
        exit 1
    fi
    INSTALLER_TEAM_ID=$(awk -F'"' '/^EXPECTED_TEAM_ID=/{print $2; exit}' ../install.sh)
    if [ "$INSTALLER_TEAM_ID" != "$EXPECTED_TEAM_ID" ]; then
        echo "ERROR: install.sh EXPECTED_TEAM_ID must match the signed Team ID"
        exit 1
    fi

    if [ -z "${PACKAGE_PATH:-}" ] || [[ "$PACKAGE_PATH" != /* ]]; then
        echo "ERROR: PACKAGE_PATH must be an absolute path outside the repository"
        exit 1
    fi
    if [ "$(basename "$PACKAGE_PATH")" != "ChanShuBao.zip" ]; then
        echo "ERROR: PACKAGE_PATH filename must be ChanShuBao.zip"
        exit 1
    fi
    PACKAGE_PARENT=$(dirname "$PACKAGE_PATH")
    mkdir -p "$PACKAGE_PARENT"
    CANONICAL_PACKAGE_PARENT=$(cd "$PACKAGE_PARENT" && pwd -P)
    REPOSITORY_ROOT=$(cd .. && pwd -P)
    case "$CANONICAL_PACKAGE_PARENT/" in
        "$REPOSITORY_ROOT/"*)
            echo "ERROR: PACKAGE_PATH must be outside the repository"
            exit 1
            ;;
    esac
    ZIP_PATH="$CANONICAL_PACKAGE_PARENT/ChanShuBao.zip"
    NOTARY_ZIP="${ZIP_PATH}.notary-upload.zip"
    rm -f "$NOTARY_ZIP"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$BUNDLE_DIR" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$BUNDLE_DIR"
    xcrun stapler validate "$BUNDLE_DIR"
    spctl -a --type execute "$BUNDLE_DIR"
    rm -f "$NOTARY_ZIP"

    rm -f "$ZIP_PATH"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$BUNDLE_DIR" "$ZIP_PATH"
    shasum -a 256 "$ZIP_PATH" | awk '{print $1}' > "${ZIP_PATH}.sha256"
    echo "=== Package: $ZIP_PATH ==="
fi
