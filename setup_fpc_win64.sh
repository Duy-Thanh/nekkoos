#! /bin/bash

# Builds the FPC Win64 RTL (cross target x86_64-win64) from the installed
# fpc-src package and generates .fpc/fpc.cfg so compile_pascal.sh can run
# with `fpc -Twin64`. Designed for openSUSE Tumbleweed (uses zypper paths),
# falls back gracefully on other distros where fpc-src is installed.

set -e

FPC_SRC_RTL="/usr/share/fpcsrc/rtl"
FPC_VERSION="$(fpc -iV)"
INSTALL_DIR="$HOME/.local/share/fpc-win64/units/x86_64-win64"
PROJECT_CFG=".fpc/fpc.cfg"

if [ -z "$FPC_VERSION" ]; then
    echo "fpc not found! Install it first (e.g.: sudo zypper install fpc fpc-src mingw64-cross-binutils)"
    exit 1
fi

echo "FPC version: $FPC_VERSION"

# FPC expects binutils named <target>-<tool> (x86_64-win64-as/ld/strip).
# Symlink them from mingw-w64 cross binutils.
mkdir -p "$HOME/.local/bin"
for t in as ld strip; do
    if command -v "x86_64-w64-mingw32-$t" &> /dev/null; then
        ln -sf "$(command -v "x86_64-w64-mingw32-$t")" "$HOME/.local/bin/x86_64-win64-$t"
    fi
done

if [ ! -d "$FPC_SRC_RTL" ]; then
    echo "FPC RTL sources not found at $FPC_SRC_RTL!"
    echo "Install fpc-src first (e.g.: sudo zypper install fpc-src)"
    exit 1
fi

BUILD_DIR="/tmp/kilo/fpc-win64-rtl"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp -a "$FPC_SRC_RTL" "$BUILD_DIR/rtl"

echo "Building Win64 RTL (this may take a few minutes)..."
make -C "$BUILD_DIR/rtl" all OS_TARGET=win64 CPU_TARGET=x86_64 FPC="$(command -v fpc)" > /dev/null

mkdir -p "$INSTALL_DIR"
cp -a "$BUILD_DIR/rtl/units/x86_64-win64/." "$INSTALL_DIR/"
rm -rf "$BUILD_DIR"

echo "Installed $(ls "$INSTALL_DIR"/*.ppu 2>/dev/null | wc -l) units to $INSTALL_DIR"

# Generate project-local fpc.cfg pointing at the fresh units
mkdir -p .fpc
echo "-Fu$INSTALL_DIR" > "$PROJECT_CFG"
chmod +x .git/hooks/commit-msg 2>/dev/null || true

echo "Wrote $PROJECT_CFG:"
cat "$PROJECT_CFG"
echo "Setup complete! Happy coding!"
