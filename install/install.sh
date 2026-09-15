#!/usr/bin/env bash
# One-line install on a Mac with Homebrew: tap jeremytondo/atelier and install
# the atelier cask, which pulls Hammerspoon 2 and runs `atelier install`.
#   curl -fsSL https://raw.githubusercontent.com/jeremytondo/atelier-next/main/install/install.sh | bash
set -euo pipefail
command -v brew > /dev/null || { echo 'Install Homebrew first: https://brew.sh' >&2; exit 1; }
brew tap jeremytondo/atelier
brew install --cask "${ATELIER_CASK:-atelier}"
echo
echo "Run 'atelier doctor' to check the installation."
