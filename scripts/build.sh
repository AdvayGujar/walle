#!/usr/bin/env bash
# build.sh - build the walle release binaries and assemble dist/Walle.app.
#
# Produces:
#   dist/Walle.app/Contents/Info.plist
#   dist/Walle.app/Contents/MacOS/walle-picker
#   dist/Walle.app/Contents/PkgInfo
#   dist/bin/walle
#
# walle deliberately does not link AppKit; only walle-picker does.
# No code signing: there is no certificate, and a local build does not need one.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="0.1.0"
APP_NAME="Walle"
BUNDLE_ID="com.walle.picker"

# scripts/swift.sh isolates its scratch and cache directories with WALLE_SWIFT_TAG,
# so the release directory has to follow the same tag.
SCRATCH="$ROOT/.build/scratch${WALLE_SWIFT_TAG:-}"
RELEASE_BIN="$SCRATCH/release"

echo "==> Building release binaries (scripts/swift.sh build -c release)"
./scripts/swift.sh build -c release

for tool in walle walle-picker; do
    if [ ! -x "$RELEASE_BIN/$tool" ]; then
        echo "build.sh: expected executable $RELEASE_BIN/$tool after the build" >&2
        exit 1
    fi
done

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "==> Assembling $APP"
rm -rf "$DIST"
mkdir -p "$MACOS" "$DIST/bin"

cp "$RELEASE_BIN/walle-picker" "$MACOS/walle-picker"
cp "$RELEASE_BIN/walle" "$DIST/bin/walle"
chmod +x "$MACOS/walle-picker" "$DIST/bin/walle"

# LSUIElement keeps the picker out of the Dock and the application switcher.
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>walle-picker</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Stripping binaries (xcrun strip -x)"
xcrun strip -x "$MACOS/walle-picker"
xcrun strip -x "$DIST/bin/walle"

echo "==> Verifying"
status=0
[ -d "$APP" ] || { echo "build.sh: missing $APP" >&2; status=1; }
[ -x "$MACOS/walle-picker" ] || { echo "build.sh: $MACOS/walle-picker is not executable" >&2; status=1; }
[ -x "$DIST/bin/walle" ] || { echo "build.sh: $DIST/bin/walle is not executable" >&2; status=1; }
plutil -lint "$CONTENTS/Info.plist" || status=1
if [ "$status" -ne 0 ]; then
    echo "build.sh: verification failed" >&2
    exit 1
fi

human_size() { du -sh "$1" | awk '{print $1}'; }
byte_size() { stat -f%z "$1"; }

echo "==> Sizes"
echo "    dist/bin/walle              $(human_size "$DIST/bin/walle")  ($(byte_size "$DIST/bin/walle") bytes)"
echo "    Walle.app picker            $(human_size "$MACOS/walle-picker")  ($(byte_size "$MACOS/walle-picker") bytes)"
echo "    Walle.app bundle            $(human_size "$APP")"

# The SwiftPM intermediates are large, dominated by precompiled macOS SDK modules, and are
# never shipped. Say so, or a 117 MB .build next to a 1 MB app looks alarming and unexplained.
if [ -d "$ROOT/.build" ]; then
    echo "    .build intermediates        $(human_size "$ROOT/.build")  (not shipped; ./scripts/clean.sh reclaims it)"
fi
