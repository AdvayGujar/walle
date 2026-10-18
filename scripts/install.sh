#!/usr/bin/env bash
# install.sh - build walle, install it under PREFIX, and put the CLI on PATH.
#
# Layout after install:
#   PREFIX/Walle.app/Contents/MacOS/walle-picker
#   PREFIX/bin/walle          the real CLI
#   PREFIX/bin/walle-picker   relative sibling link, inside the prefix
#   BIN_DIR/walle -> PREFIX/bin/walle
#
# The config file is created once and never overwritten. Running the installer
# twice is safe.
#
# End users get the defaults above. Packagers (Homebrew and friends) should pass
# --packager, which keeps every write inside PREFIX:
#
#   ./scripts/install.sh --packager --prefix /opt/homebrew/Cellar/walle/1.1.0
#
# --packager implies --no-config (no writes to ~/.config), defaults --bin-dir to
# PREFIX/bin (no PATH symlink outside the prefix) and never prompts. Combined
# with --dry-run it changes nothing at all. This script never calls sudo.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFIX="${HOME}/.local/share/walle"
BIN_DIR="${HOME}/.local/bin"
BIN_DIR_GIVEN=0
VERSION=""
NO_CONFIG=0
CLEAN=0
DRY_RUN=0
PACKAGER=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --prefix DIR   install root (default: $HOME/.local/share/walle)
  --bin-dir DIR  directory for the 'walle' command (default: $HOME/.local/bin)
  --version VER  version to stamp into the app (default: WalleVersion.swift)
  --packager     install only inside --prefix: implies --no-config, defaults
                 --bin-dir to PREFIX/bin, and never prompts
  --no-config    do not create a default config file
  --clean        remove the .build intermediates after installing
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

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || { echo "install.sh: --prefix needs a directory" >&2; exit 2; }
            PREFIX="$2"; shift 2 ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"; shift ;;
        --bin-dir)
            [ $# -ge 2 ] || { echo "install.sh: --bin-dir needs a directory" >&2; exit 2; }
            BIN_DIR="$2"; BIN_DIR_GIVEN=1; shift 2 ;;
        --bin-dir=*)
            BIN_DIR="${1#--bin-dir=}"; BIN_DIR_GIVEN=1; shift ;;
        --version)
            [ $# -ge 2 ] || { echo "install.sh: --version needs a value" >&2; exit 2; }
            VERSION="$2"; shift 2 ;;
        --version=*)
            VERSION="${1#--version=}"; shift ;;
        --packager) PACKAGER=1; shift ;;
        --no-config) NO_CONFIG=1; shift ;;
        --clean) CLEAN=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

PREFIX="$(abs_path "$PREFIX")"
# A packager owns only PREFIX. Keep the CLI inside it rather than symlinking into
# the user's ~/.local/bin, and never write a config file into the user's home.
if [ "$PACKAGER" -eq 1 ]; then
    NO_CONFIG=1
    if [ "$BIN_DIR_GIVEN" -eq 0 ]; then
        BIN_DIR="$PREFIX/bin"
    fi
fi
BIN_DIR="$(abs_path "$BIN_DIR")"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_FILE="$CONFIG_HOME/walle/config"
TARGET="$PREFIX/bin/walle"
LINK="$BIN_DIR/walle"

echo "==> walle installer"
echo "    prefix:  $PREFIX"
echo "    bin dir: $BIN_DIR"
if [ "$PACKAGER" -eq 1 ]; then
    echo "    mode:    packager (writes stay inside the prefix)"
elif [ "$DRY_RUN" -eq 1 ]; then
    echo "    mode:    dry run"
fi

# 1. Build first, so a broken build never leaves a half install. build.sh owns
# every step that writes: dist/ and, when asked, the prefix itself.
build_args=(--prefix "$PREFIX")
if [ -n "$VERSION" ]; then
    build_args+=(--version "$VERSION")
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> Would run $ROOT/scripts/build.sh ${build_args[*]}"
else
    if [ ! -x "$ROOT/scripts/build.sh" ]; then
        echo "install.sh: $ROOT/scripts/build.sh is missing or not executable" >&2
        exit 1
    fi
    echo "==> Building and staging into $PREFIX"
    if ! "$ROOT/scripts/build.sh" "${build_args[@]}"; then
        echo "install.sh: build.sh failed; nothing installed" >&2
        exit 1
    fi
fi

# 2. Confirm the build staged what we are about to report as installed.
if [ "$DRY_RUN" -eq 0 ] && { [ ! -x "$TARGET" ] || [ ! -d "$PREFIX/Walle.app" ]; }; then
    echo "install.sh: build.sh did not stage a complete tree into $PREFIX" >&2
    exit 1
fi

# 3. Link the CLI onto the user's PATH. In packager mode this is inside PREFIX
# already, so it is a no-op.
if [ "$BIN_DIR" = "$PREFIX/bin" ]; then
    echo "==> $LINK is the installed CLI itself; no PATH symlink needed"
else
    echo "==> Linking $LINK -> $TARGET"
    if [ -L "$LINK" ]; then
        run rm -f "$LINK"
    elif [ -e "$LINK" ]; then
        if [ -f "$LINK" ] && [ -f "$TARGET" ] && cmp -s "$LINK" "$TARGET"; then
            echo "    replacing a previous copy of the CLI"
            run rm -f "$LINK"
        else
            echo "install.sh: refusing to overwrite $LINK" >&2
            echo "            it is a real file that is not a walle install" >&2
            exit 1
        fi
    fi
    run mkdir -p "$BIN_DIR"
    run ln -s "$TARGET" "$LINK"
fi

# 4. Create the config once. Never overwrite an existing one. This is the one
# write outside PREFIX, which is why --packager turns it off entirely.
if [ "$NO_CONFIG" -eq 1 ]; then
    if [ "$PACKAGER" -eq 1 ]; then
        echo "==> Config: skipped (packager mode; created on first run)"
    else
        echo "==> Config: skipped (--no-config)"
    fi
elif [ -e "$CONFIG_FILE" ]; then
    echo "==> Config: keeping existing $CONFIG_FILE"
else
    echo "==> Config: writing defaults to $CONFIG_FILE"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] mkdir -p $CONFIG_HOME/walle"
        echo "  [dry-run] $TARGET config list > $CONFIG_FILE"
    else
        mkdir -p "$CONFIG_HOME/walle"
        tmp="$CONFIG_FILE.tmp.$$"
        if "$TARGET" config list > "$tmp" && [ -s "$tmp" ]; then
            mv "$tmp" "$CONFIG_FILE"
        else
            rm -f "$tmp"
            echo "install.sh: could not write a default config" >&2
            exit 1
        fi
    fi
fi

# 5. Report.
if [ "$DRY_RUN" -eq 0 ]; then
    echo "==> Sizes"
    echo "    Walle.app   $(du -sh "$PREFIX/Walle.app" | awk '{print $1}')"
    echo "    walle CLI   $(du -sh "$PREFIX/bin/walle" | awk '{print $1}')"
fi

echo
echo "==> Installed"
echo "    app:     $PREFIX/Walle.app"
echo "    CLI:     $PREFIX/bin/walle"

# Everything below is end-user guidance for a hand install. A package manager
# reports the same things through its own caveats, so keep it out of the way.
if [ "$PACKAGER" -eq 1 ]; then
    exit 0
fi

echo "    config:  $CONFIG_FILE"
case ":$PATH:" in
    *":$BIN_DIR:"*) ON_PATH=1 ;;
    *) ON_PATH=0 ;;
esac
if [ "$ON_PATH" -eq 1 ]; then
    echo "    PATH:    $BIN_DIR is on PATH"
else
    echo "    PATH:    $BIN_DIR is NOT on PATH"
    echo "             add this line to your shell profile:"
    echo "               export PATH=$BIN_DIR:"'$PATH'
fi

cat <<EOF

==> skhd setup (run these yourself; install.sh does not touch skhd)
    brew install koekeishiya/formulae/skhd
    skhd --start-service

  Add this binding to ~/.config/skhd/skhdrc:
    cmd + alt - w : $BIN_DIR/walle

  'walle' with no subcommand opens the picker. skhd also needs Accessibility
  access in System Settings > Privacy & Security > Accessibility; no CLI can
  grant that.
EOF

# SwiftPM leaves a large intermediate directory behind. None of it is needed to run walle,
# so offer to reclaim it rather than leaving the user to wonder why the project is 100 MB.
if [ "$DRY_RUN" -eq 0 ] && [ -d "$ROOT/.build" ]; then
    SIZE="$(du -sh "$ROOT/.build" | awk '{print $1}')"
    if [ "$CLEAN" -eq 1 ]; then
        echo
        echo "==> Removing build intermediates ($SIZE)"
        rm -rf "$ROOT/.build"
    elif [ -t 0 ]; then
        echo
        printf '==> %s of build intermediates are no longer needed. Remove them? [y/N] ' "$SIZE"
        read -r REPLY || REPLY=""
        case "$REPLY" in
            [yY]|[yY][eE][sS])
                rm -rf "$ROOT/.build"
                echo "    removed"
                ;;
            *)
                echo "    kept; ./scripts/clean.sh reclaims it at any time"
                ;;
        esac
    else
        echo
        echo "==> $SIZE of build intermediates remain in $ROOT/.build"
        echo "    they are not needed to run walle."
        echo "    ./scripts/clean.sh reclaims them, or use install.sh --clean next time."
    fi
fi
