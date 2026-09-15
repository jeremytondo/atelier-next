#!/usr/bin/env bash
# Install the selected Atelier/HS2 pair by fully qualified name. Homebrew
# automatically taps the repository and trusts only these requested casks.
#   curl -fsSL https://raw.githubusercontent.com/jeremytondo/atelier-next/main/install/install.sh | bash
set -euo pipefail
command -v brew > /dev/null || { echo 'Install Homebrew first: https://brew.sh' >&2; exit 1; }
cask=${ATELIER_CASK:-atelier}
case "$cask" in
  atelier) hs2=hammerspoon2 ;;
  atelier@dev) hs2=hammerspoon2@dev ;;
  *) echo 'ATELIER_CASK must be atelier or atelier@dev.' >&2; exit 2 ;;
esac
# A separate `brew tap` can evaluate untrusted casks before install grants
# trust. Name both packages so the HS2 dependency is trusted as well.
echo "Installing jeremytondo/atelier/$cask and its Hammerspoon 2 dependency."
brew install --cask "jeremytondo/atelier/$hs2" "jeremytondo/atelier/$cask"
echo
echo "Run 'atelier doctor' to check the installation."
