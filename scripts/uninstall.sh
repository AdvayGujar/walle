#!/usr/bin/env bash
# uninstall.sh - remove an installed walle and its PATH symlink.
#
# The user's config, wallpaper library, caches and thumbnails are never touched.
set -eo pipefail

PREFIX="${HOME}/.local/share/walle"
BIN_DIR="${HOME}/.local/bin"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --prefix DIR   install root to remove (default: $HOME/.local/share/walle)
  --bin-dir DIR  directory holding the 'walle' symlink (default: $HOME/.local/bin)
  --dry-run      print what would happen and change nothing
  -h, --help     show this help
EOF
}

abs_path() {
    local p="$1"
    case "$p" in
        /*) ;;
        *) p="${PWD%/}/$p" ;;
    esac
    while [ "${p%/}" != "$p" ]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

remove_path() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        run rm -rf "$1"
        echo "removed $1"
    else
        echo "not present $1"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || { echo "uninstall.sh: --prefix needs a directory" >&2; exit 2; }
            PREFIX="$2"; shift 2 ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"; shift ;;
        --bin-dir)
            [ $# -ge 2 ] || { echo "uninstall.sh: --bin-dir needs a directory" >&2; exit 2; }
            BIN_DIR="$2"; shift 2 ;;
        --bin-dir=*)
            BIN_DIR="${1#--bin-dir=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "uninstall.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

PREFIX="$(abs_path "$PREFIX")"
BIN_DIR="$(abs_path "$BIN_DIR")"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/walle/config"
TARGET="$PREFIX/bin/walle"
LINK="$BIN_DIR/walle"

echo "==> Uninstalling walle"
echo "    prefix:  $PREFIX"
echo "    bin dir: $BIN_DIR"

# Remove the PATH symlink before the target it points at.
if [ -L "$LINK" ]; then
    dest="$(readlink "$LINK")"
    if [ "$dest" = "$TARGET" ]; then
        run rm -f "$LINK"
        echo "removed symlink $LINK"
    else
        echo "leaving $LINK (points at $dest, not $TARGET)"
    fi
elif [ -e "$LINK" ]; then
    if [ -f "$LINK" ] && [ -f "$TARGET" ] && cmp -s "$LINK" "$TARGET"; then
        run rm -f "$LINK"
        echo "removed duplicate CLI at $LINK"
    else
        echo "leaving $LINK (a real file that is not the installed walle)"
    fi
else
    echo "no CLI at $LINK"
fi

remove_path "$PREFIX/Walle.app"
remove_path "$PREFIX/bin/walle"
remove_path "$PREFIX/bin/walle-picker"

# Tidy the directories only if the installer left them empty.
if [ "$DRY_RUN" -eq 0 ]; then
    rmdir "$PREFIX/bin" 2>/dev/null || true
    rmdir "$PREFIX" 2>/dev/null || true
fi

echo
echo "Left untouched on purpose:"
echo "  config:     $CONFIG_FILE"
echo "  wallpaper directories, thumbnails and caches are not managed here"
