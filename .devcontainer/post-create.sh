#!/bin/bash
set -e

echo "=== Unison Development Container Setup ==="

# Install system dependencies
echo "Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    libffi-dev \
    libgmp-dev \
    libncurses-dev \
    libtinfo-dev \
    pkg-config \
    zlib1g-dev \
    xz-utils \
    libnuma-dev

# Install GHCup
echo "Installing GHCup..."
export BOOTSTRAP_HASKELL_NONINTERACTIVE=1
export BOOTSTRAP_HASKELL_GHC_VERSION=9.6.5
export BOOTSTRAP_HASKELL_CABAL_VERSION=3.10.3.0
export BOOTSTRAP_HASKELL_INSTALL_HLS=1
export BOOTSTRAP_HASKELL_INSTALL_STACK=1
export BOOTSTRAP_HASKELL_ADJUST_BASHRC=1

curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

# Source GHCup environment
source "$HOME/.ghcup/env"

# Ensure GHCup env is sourced in future shell sessions
if ! grep -q 'ghcup/env' "$HOME/.bashrc" 2>/dev/null; then
    echo '[ -f "$HOME/.ghcup/env" ] && source "$HOME/.ghcup/env"' >> "$HOME/.bashrc"
fi

# Install specific Stack version
echo "Installing Stack 2.15.7..."
ghcup install stack 2.15.7
ghcup set stack 2.15.7

# Verify installations
echo ""
echo "Verifying installations..."
ghc --version
stack --version
cabal --version
haskell-language-server-wrapper --version || true

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To start developing:"
echo "  1. Build the project: stack build"
echo "  2. Run tests: stack test --fast"
echo "  3. Run Unison: stack exec unison"
echo ""
echo "See development.markdown for more details."
