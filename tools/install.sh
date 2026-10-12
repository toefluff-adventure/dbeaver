#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PRODUCT_TARGET_DIR=${DBEAVER_PRODUCT_TARGET_DIR:-"$REPO_DIR/product/community/target"}
INSTALL_ROOT=${DBEAVER_INSTALL_ROOT:-"$HOME/.local/opt/dbeaver-ce"}
BIN_DIR=${DBEAVER_BIN_DIR:-"$HOME/.local/bin"}
DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
APPLICATIONS_DIR="$DATA_HOME/applications"
BUILD_PRODUCT=true

usage() {
    cat <<'EOF'
Usage: tools/install.sh [--skip-build]

Build DBeaver Community Edition and install it for the current user on Linux.
The installation is placed under ~/.local/opt/dbeaver-ce by default, with a
launcher symlink in ~/.local/bin. Override those locations with
DBEAVER_INSTALL_ROOT and DBEAVER_BIN_DIR. Set DBEAVER_PRODUCT_TARGET_DIR to
use product archives from a different build directory.

Options:
  --skip-build  Install the most recently built Linux product archive
  --help        Show this help
EOF
}

for argument in "$@"; do
    case "$argument" in
        --skip-build)
            BUILD_PRODUCT=false
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option: $argument" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$(uname -s)" != Linux ]; then
    echo "Error: this installer supports Linux only" >&2
    exit 1
fi

for command_name in find sort sed tar mktemp readlink ln mv cp grep; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name" >&2
        exit 1
    fi
done

CURRENT_LINK="$INSTALL_ROOT/current"
LAUNCHER_LINK="$BIN_DIR/dbeaver"
DESKTOP_FILE="$APPLICATIONS_DIR/dbeaver-ce.desktop"
if [ -e "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
    echo "Error: refusing to replace non-symlink installation path $CURRENT_LINK" >&2
    exit 1
fi
if [ -L "$CURRENT_LINK" ]; then
    case "$(readlink "$CURRENT_LINK")" in
        "$INSTALL_ROOT"/*) ;;
        *)
            echo "Error: refusing to replace unrelated symlink $CURRENT_LINK" >&2
            exit 1
            ;;
    esac
fi
if [ -e "$LAUNCHER_LINK" ] || [ -L "$LAUNCHER_LINK" ]; then
    if [ ! -L "$LAUNCHER_LINK" ] || [ "$(readlink "$LAUNCHER_LINK")" != "$CURRENT_LINK/dbeaver" ]; then
        echo "Error: refusing to replace existing path $LAUNCHER_LINK" >&2
        exit 1
    fi
fi
if [ -e "$DESKTOP_FILE" ] || [ -L "$DESKTOP_FILE" ]; then
    if [ ! -f "$DESKTOP_FILE" ] || ! grep -q '^# Installed by tools/install.sh$' "$DESKTOP_FILE"; then
        echo "Error: refusing to replace existing path $DESKTOP_FILE" >&2
        exit 1
    fi
fi

if [ "$BUILD_PRODUCT" = true ]; then
    echo "Building DBeaver Community Edition..."
    sh "$SCRIPT_DIR/build.sh"
fi

if [ ! -d "$PRODUCT_TARGET_DIR" ]; then
    echo "Error: product build output not found at $PRODUCT_TARGET_DIR" >&2
    echo "Build the Community Edition first, or run this script without --skip-build." >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64)
        PRODUCT_ARCH=x86_64
        ;;
    aarch64|arm64)
        PRODUCT_ARCH=aarch64
        ;;
    *)
        echo "Error: unsupported Linux architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

PRODUCT_ARCHIVE=$(
    find "$PRODUCT_TARGET_DIR" -type f -name "dbeaver-ce-*-linux*.$PRODUCT_ARCH.tar.gz" -printf '%T@ %p\n' |
        sort -nr |
        sed -n '1s/^[^ ]* //p'
)
if [ -z "$PRODUCT_ARCHIVE" ]; then
    echo "Error: no Linux DBeaver CE archive for $PRODUCT_ARCH found under $PRODUCT_TARGET_DIR" >&2
    exit 1
fi

mkdir -p "$INSTALL_ROOT" "$BIN_DIR" "$APPLICATIONS_DIR"
STAGING_DIR=$(mktemp -d "$INSTALL_ROOT/.install.XXXXXX")
DESKTOP_TEMP=
cleanup() {
    rm -rf "$STAGING_DIR"
    if [ -n "$DESKTOP_TEMP" ]; then
        rm -f "$DESKTOP_TEMP"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

echo "Installing from $PRODUCT_ARCHIVE..."
tar -xzf "$PRODUCT_ARCHIVE" -C "$STAGING_DIR"
if [ ! -x "$STAGING_DIR/dbeaver/dbeaver" ]; then
    echo "Error: archive does not contain an executable dbeaver/dbeaver launcher" >&2
    exit 1
fi
cp "$REPO_DIR/product/community/icons/dbeaver.png" "$STAGING_DIR/dbeaver/dbeaver.png"

VERSION=$(basename "$PRODUCT_ARCHIVE" | sed -e 's/^dbeaver-ce-//' -e 's/-linux.*$//')
VERSION_DIR=$(mktemp -d "$INSTALL_ROOT/$VERSION.XXXXXX")
rmdir "$VERSION_DIR"
mv "$STAGING_DIR/dbeaver" "$VERSION_DIR"

CURRENT_TEMP="$INSTALL_ROOT/.current.$$"
ln -s "$VERSION_DIR" "$CURRENT_TEMP"
mv -Tf "$CURRENT_TEMP" "$CURRENT_LINK"

if [ -e "$LAUNCHER_LINK" ] || [ -L "$LAUNCHER_LINK" ]; then
    :
else
    ln -s "$CURRENT_LINK/dbeaver" "$LAUNCHER_LINK"
fi

DESKTOP_TEMP=$(mktemp "$APPLICATIONS_DIR/.dbeaver-ce.XXXXXX")
cat > "$DESKTOP_TEMP" <<EOF
# Installed by tools/install.sh
[Desktop Entry]
Type=Application
Name=DBeaver Community Edition
Comment=Universal Database Manager
Exec="$CURRENT_LINK/dbeaver" %U
Icon=$CURRENT_LINK/dbeaver.png
Terminal=false
Categories=Development;IDE;Database;
StartupNotify=true
EOF
mv -f "$DESKTOP_TEMP" "$DESKTOP_FILE"
DESKTOP_TEMP=

echo "DBeaver installed at $VERSION_DIR"
echo "Desktop launcher installed at $DESKTOP_FILE"
echo "Run it with: $LAUNCHER_LINK"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Add $BIN_DIR to your PATH to run 'dbeaver' from a terminal." ;;
esac
