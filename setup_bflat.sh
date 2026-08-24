#! /bin/bash

BFLAT_VERSION="10.0.0-rc.1"
BFLAT_FILE="bflat-${BFLAT_VERSION}-linux-glibc-x64.tar.gz"
BFLAT_URL="https://github.com/bflattened/bflat/releases/download/v${BFLAT_VERSION}/${BFLAT_FILE}"
INSTALL_DIR="$HOME/bflat"

echo "Checking dependencies..."
if ! command -v wget &> /dev/null; then
    echo "wget not found. Installing..."
    if command -v zypper &> /dev/null; then
        sudo zypper --non-interactive install wget
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --noconfirm wget
    elif command -v apt &> /dev/null; then
        sudo apt update && sudo apt install -y wget
    fi
fi

mkdir -p "$INSTALL_DIR"

if [ -x "$INSTALL_DIR/bflat" ]; then
    echo "bflat v${BFLAT_VERSION} already installed in $INSTALL_DIR, skipping download."
else
    cd "$INSTALL_DIR" || exit

    echo "Downloading bflat v${BFLAT_VERSION}..."
    wget -q --show-progress "$BFLAT_URL"

    echo "Extracting..."
    tar -xzf "$BFLAT_FILE"
    rm "$BFLAT_FILE"
fi

# Detect the login shell and pick the matching rc file (zsh, bash, ...)
SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    fish) RC_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.bashrc" ;;
esac

RC_LINE="export PATH=\"\$PATH:$INSTALL_DIR\""
if [ "$SHELL_NAME" = "fish" ]; then
    RC_LINE="fish_add_path $INSTALL_DIR"
fi

if [ -f "$RC_FILE" ] && grep -qF "$INSTALL_DIR" "$RC_FILE"; then
    echo "PATH already configured in $RC_FILE."
else
    echo "Adding bflat to PATH in $RC_FILE..."
    printf '\n%s\n' "$RC_LINE" >> "$RC_FILE"
    echo "Run 'source $RC_FILE' to use bflat immediately."
fi

echo "Setup complete! Happy coding!"
