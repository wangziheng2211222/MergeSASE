#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="MergeSASE"
BUNDLE_DIR="$APP_NAME.app"
EXECUTABLE="$APP_NAME"

echo "=== Building $APP_NAME ==="

swift build -c release --arch arm64 2>&1 | tail -3

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
    ICONSET="/tmp/MergeSASE.iconset"
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

# Ad-hoc sign and remove quarantine
xattr -cr "$BUNDLE_DIR" 2>/dev/null
codesign --force --deep --sign - "$BUNDLE_DIR" 2>/dev/null

echo "=== Done: $BUNDLE_DIR ==="
echo "Run: open $BUNDLE_DIR"
