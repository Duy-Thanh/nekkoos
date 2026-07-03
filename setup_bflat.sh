#! /bin/bash

BFLAT_VERSION="10.0.0-rc.1"
BFLAT_FILE="bflat-${BFLAT_VERSION}-linux-glibc-x64.tar.gz"
BFLAT_URL="https://github.com/bflattened/bflat/releases/download/v${BFLAT_VERSION}/${BFLAT_FILE}"
INSTALL_DIR="$HOME/bflat"

echo "Checking dependencies..."
if ! command -v wget &> /dev/null; then
    echo "wget not found. Installing..."
    if command -v pacman &> /dev/null; then
        sudo pacman -S --noconfirm wget
    elif command -v apt &> /dev/null; then
        sudo apt update && sudo apt install -y wget
    fi
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit

echo "Downloading bflat v${BFLAT_VERSION}..."
wget -q --show-progress "$BFLAT_URL"

echo "Extracting..."
tar -xzf "$BFLAT_FILE"
rm "$BFLAT_FILE"

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "Adding bflat to PATH in .bashrc..."
    echo "export PATH=\$PATH:$INSTALL_DIR" >> ~/.bashrc
    echo "Run 'source ~/.bashrc' to use bflat immediately."
fi

echo "Setup complete! Happy coding!"
