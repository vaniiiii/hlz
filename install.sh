#!/bin/sh
set -e

REPO="vaniiiii/hlz"

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

# Try /usr/local/bin first, fall back to ~/.local/bin
if [ -w "/usr/local/bin" ]; then
  mv hlz /usr/local/bin/hlz
  echo "Installed to /usr/local/bin/hlz"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo mv hlz /usr/local/bin/hlz
  echo "Installed to /usr/local/bin/hlz"
else
  mkdir -p "$HOME/.local/bin"
  mv hlz "$HOME/.local/bin/hlz"
  echo "Installed to $HOME/.local/bin/hlz"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
fi

hlz version
