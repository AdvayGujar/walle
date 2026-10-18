#!/usr/bin/env bash
# build.sh - build the walle release binaries and assemble an install tree.
#
# Two modes:
#
#   End users / developers (default). Builds and stages into dist/ only. Nothing
#   outside the repository is written, so this is safe to run anywhere:
#
#       ./scripts/build.sh
#
#   Packagers (Homebrew, MacPorts, ...). Stages a finished tree under an
#   arbitrary prefix and touches nothing else - no ~/.local, no PATH, no config
#   file, no sudo, no prompts:
#
#       ./scripts/build.sh --prefix /opt/homebrew/Cellar/walle/1.1.0
#
#   Either way the resulting tree is the same:
#       PREFIX/bin/walle                            the CLI
#       PREFIX/bin/walle-picker -> ../Walle.app/... the picker, on PATH too
#       PREFIX/Walle.app/Contents/MacOS/walle-picker
#       PREFIX/Walle.app/Contents/Info.plist
#
# The version comes from Sources/WalleCore/WalleVersion.swift unless --version
# or WALLE_VERSION overrides it. A packager building from a release tarball has
# no .git, so the tag cannot be recovered there; that is what the override is
# for.
#
# walle deliberately does not link AppKit; only walle-picker does.
# No code signing: there is no certificate, and a build does not need one.
#
# This script never calls sudo. Run it as the user who owns the prefix.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Walle"
BUNDLE_ID="com.walle.picker"
VERSION_FILE="$ROOT/Sources/WalleCore/WalleVersion.swift"

PREFIX=""
VERSION=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --prefix DIR    stage a finished install tree under DIR (packagers)
  --version VER   version to stamp into the app (default: WalleVersion.swift)
  -h, --help      show this help

Environment:
  WALLE_VERSION   same as --version
  WALLE_SWIFT_TAG same as scripts/swift.sh, to isolate concurrent builds
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || { echo "build.sh: --prefix needs a directory" >&2; exit 2; }
            PREFIX="$2"; shift 2 ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"; shift ;;
        --version)
            [ $# -ge 2 ] || { echo "build.sh: --version needs a value" >&2; exit 2; }
            VERSION="$2"; shift 2 ;;
        --version=*)
            VERSION="${1#--version=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "build.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# One version, one place it is written down. The sed is deliberately narrow: it
# only matches the exact declaration in WalleVersion.swift.
if [ -z "$VERSION" ]; then
    VERSION="${WALLE_VERSION:-}"
fi
if [ -z "$VERSION" ]; then
    VERSION="$(sed -n 's/.*public static let string = "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -n 1)"
fi
if [ -z "$VERSION" ]; then
    echo "build.sh: could not determine a version; expected one in $VERSION_FILE" >&2
    exit 1
fi

# scripts/swift.sh isolates its scratch and cache directories with WALLE_SWIFT_TAG,
# so the release directory has to follow the same tag.
SCRATCH="$ROOT/.build/scratch${WALLE_SWIFT_TAG:-}"
RELEASE_BIN="$SCRATCH/release"

echo "==> Building walle $VERSION (scripts/swift.sh build -c release)"
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

# A dist/bin/walle-picker sibling, as a relative link, so the tree works from
# anywhere and survives being copied into a keg. The CLI itself finds the picker
# through ../Walle.app, so this is for callers that want both on PATH.
ln -sfn "../$APP_NAME.app/Contents/MacOS/walle-picker" "$DIST/bin/walle-picker"

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
[ -x "$DIST/bin/walle-picker" ] || { echo "build.sh: $DIST/bin/walle-picker is not executable" >&2; status=1; }
plutil -lint "$CONTENTS/Info.plist" || status=1
if [ "$status" -ne 0 ]; then
    echo "build.sh: verification failed" >&2
    exit 1
fi

# The built binary must report the version we just stamped, or the release is
# internally inconsistent. Cheap to check here rather than after publishing.
reported="$("$DIST/bin/walle" --version)"
if [ "$reported" != "walle $VERSION" ]; then
    echo "build.sh: $DIST/bin/walle reports '$reported', expected 'walle $VERSION'" >&2
    exit 1
fi

# Staging is the only step that writes outside the repository, and it runs only
# when a packager asks for it. Nothing here needs sudo or writes to the user's
# home directory.
if [ -n "$PREFIX" ]; then
    case "$PREFIX" in
        /*) ;;
        *) PREFIX="$PWD/$PREFIX" ;;
    esac
    echo "==> Staging into $PREFIX"
    mkdir -p "$PREFIX/bin"
    rm -rf "$PREFIX/$APP_NAME.app"
    cp -R "$APP" "$PREFIX/$APP_NAME.app"
    rm -f "$PREFIX/bin/walle" "$PREFIX/bin/walle-picker"
    cp "$DIST/bin/walle" "$PREFIX/bin/walle"
    chmod +x "$PREFIX/bin/walle" "$PREFIX/$APP_NAME.app/Contents/MacOS/walle-picker"
    # Relative link, so the keg can be relocated without rewriting it.
    ln -sfn "../$APP_NAME.app/Contents/MacOS/walle-picker" "$PREFIX/bin/walle-picker"

    staged="$("$PREFIX/bin/walle" --version)"
    if [ "$staged" != "walle $VERSION" ]; then
        echo "build.sh: staged $PREFIX/bin/walle reports '$staged', expected 'walle $VERSION'" >&2
        exit 1
    fi
fi

human_size() { du -sh "$1" | awk '{print $1}'; }
byte_size() { stat -f%z "$1"; }

echo "==> Sizes"
echo "    dist/bin/walle              $(human_size "$DIST/bin/walle")  ($(byte_size "$DIST/bin/walle") bytes)"
echo "    Walle.app picker            $(human_size "$MACOS/walle-picker")  ($(byte_size "$MACOS/walle-picker") bytes)"
echo "    Walle.app bundle            $(human_size "$APP")"
if [ -n "$PREFIX" ]; then
    echo "    staged prefix               $PREFIX"
fi

# The SwiftPM intermediates are large, dominated by precompiled macOS SDK modules, and are
# never shipped. Say so, or a 117 MB .build next to a 1 MB app looks alarming and unexplained.
if [ -d "$ROOT/.build" ]; then
    echo "    .build intermediates        $(human_size "$ROOT/.build")  (not shipped; ./scripts/clean.sh reclaims it)"
fi
