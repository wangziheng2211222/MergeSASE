#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="蝉舒宝"
BUNDLE_DIR="$APP_NAME.app"
EXECUTABLE="MergeSASE"

echo "=== Building $APP_NAME ==="

swift build -c release --arch arm64

BUILD_PATH=".build/arm64-apple-macosx/release"
if [ ! -f "$BUILD_PATH/$EXECUTABLE" ]; then
    BUILD_PATH=".build/release"
fi

if [ ! -f "$BUILD_PATH/$EXECUTABLE" ]; then
    echo "ERROR: Build failed, executable not found"
    exit 1
fi

echo "=== Creating .app bundle ==="
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$BUILD_PATH/$EXECUTABLE" "$BUNDLE_DIR/Contents/MacOS/"
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

# Ad-hoc sign and remove quarantine
xattr -cr "$BUNDLE_DIR" 2>/dev/null
codesign --force --deep --sign - "$BUNDLE_DIR" 2>/dev/null

echo "=== Done: $BUNDLE_DIR ==="
echo "Run: open $BUNDLE_DIR"

if [ "${PACKAGE:-0}" = "1" ]; then
    ZIP_PATH="../ChanShuBao.zip"
    rm -f "$ZIP_PATH"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$BUNDLE_DIR" "$ZIP_PATH"
    echo "=== Package: $ZIP_PATH ==="
fi
