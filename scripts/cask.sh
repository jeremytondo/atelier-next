#!/usr/bin/env bash
# Print the Homebrew cask of one channel for one build. The two channels are
# the same app in the same place, so each names the other as a conflict and
# only one is installed at a time; they differ in name, in where the download
# is, and in what the other is called.
#
# The cask runs nothing of Atelier's. It does remove quarantine from the CLI
# executable: invoking a quarantined executable nested inside an app can leave
# macOS waiting for an app-launch confirmation that does not reliably surface
# from a terminal command. The app stays quarantined for its normal first launch.
# Homebrew runs a cask's steps in a sandbox without the network, which counts
# Atelier's socket, so a step could not ask the running app anything.
#
# usage: scripts/cask.sh dev|stable VERSION BUILD SHA256
set -euo pipefail
[[ $# -eq 4 ]] || {
  echo 'usage: scripts/cask.sh dev|stable VERSION BUILD SHA256' >&2
  exit 1
}
channel=$1 version=$2 build=$3 sha256=$4
case $channel in
  dev) token='atelier@dev' other='atelier' tag='dev' ;;
  stable) token='atelier' other='atelier@dev' tag="v#{version.csv.first}" ;;
  *)
    echo "cask.sh: expected dev or stable, not $channel" >&2
    exit 1
    ;;
esac
if [[ $channel == dev ]]; then
  note='This cask follows the newest development build; each one replaces the last.'
else
  note='Stable releases keep their versioned downloads.'
fi
cat <<CASK
cask "$token" do
  version "$version,$build"
  sha256 "$sha256"

  url "https://github.com/jeremytondo/atelier-next/releases/download/$tag/Atelier-#{version.csv.first}-#{version.csv.second}.zip"
  name "Atelier"
  desc "Keyboard-driven workspace: Desktops, numbered windows, Quick Apps, leader menu"
  homepage "https://github.com/jeremytondo/atelier-next"

  conflicts_with cask: "jeremytondo/tap/$other"
  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "Atelier.app"
  binary "#{appdir}/Atelier.app/Contents/Helpers/atelier"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/Atelier.app/Contents/Helpers/atelier"]
  end

  # On an upgrade Homebrew quits a running Atelier with this and opens the new
  # one afterwards; one that was closed stays closed. Atelier finishes a command
  # in progress before it goes.
  uninstall quit: "com.elevenideas.Atelier"

  # The configuration in ~/.config/atelier is yours and is never removed.
  zap trash: "~/Library/Application Support/Atelier"

  caveats <<~EOS
    $note
    Your configuration and the window lists are kept through upgrades, channel
    changes, and uninstalling; \`atelier config open\` opens the configuration.
    Run \`atelier doctor\` after an upgrade. If Homebrew could not quit Atelier,
    it says the old build is still running, and \`atelier restart\` puts that right.
  EOS
end
CASK
