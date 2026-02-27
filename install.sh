#!/bin/sh
set -e

REPO="vaniiiii/hlz"
INSTALL_DIR="/usr/local/bin"

# Detect OS
OS=$(uname -s)
case "$OS" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *) echo "Unsupported OS: $OS" >&2; exit 1 ;;
esac

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  arch="x64" ;;
  arm64|aarch64)  arch="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

BINARY="hlz-${os}-${arch}"
URL="https://github.com/${REPO}/releases/latest/download/${BINARY}"

echo "Installing hlz (${os}/${arch})..."
curl -fsSL -o hlz "$URL"
chmod +x hlz

if [ -w "$INSTALL_DIR" ]; then
  mv hlz "$INSTALL_DIR/hlz"
else
  sudo mv hlz "$INSTALL_DIR/hlz"
fi

echo "hlz installed to ${INSTALL_DIR}/hlz"
hlz version
