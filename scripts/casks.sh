#!/usr/bin/env bash
# Generate the Homebrew casks the tap publishes: hammerspoon2 from the pin's
# upstream release, and atelier or atelier@dev from a release manifest. The
# tap only ever references upstream's signed release ZIPs, so hammerspoon2 is
# skipped while the pin has no release.
# shellcheck disable=SC2154  # manifest fields are defined by load_release_plan
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -ge 1 && $# -le 2 ]] || die 'usage: mise run casks OUTPUT_DIR [MANIFEST.json]'
output=$1
mkdir -p "$output"
pin="$root/hammerspoon2.json"

if [[ $(jq -r '.release' "$pin") != null ]]; then
  hs2_tag=$(jq -er .release.tag "$pin")
  hs2_sha256=$(jq -er .release.sha256 "$pin")
  cat > "$output/hammerspoon2.rb" <<CASK
cask "hammerspoon2" do
  version "$hs2_tag"
  sha256 "$hs2_sha256"

  url "https://github.com/cmsj/Hammerspoon2/releases/download/#{version}/Hammerspoon.2.zip"
  name "Hammerspoon 2"
  desc "Automation with a JavaScript engine, at the release Atelier is tested with"
  homepage "https://github.com/cmsj/Hammerspoon2"

  depends_on macos: :tahoe

  app "Hammerspoon 2.app"

  uninstall quit: "net.tenshu.Hammerspoon-2"

  zap trash: "~/Library/Preferences/net.tenshu.Hammerspoon-2.plist"
end
CASK
  echo "$output/hammerspoon2.rb"
else
  echo 'hammerspoon2 cask skipped: the pin has no upstream release yet.' >&2
fi

[[ $# -eq 2 ]] || exit 0
manifest=$2
load_release_plan "$manifest"
asset=$(jq -er .asset "$manifest")
sha256=$(jq -er .sha256 "$manifest")
[[ $asset == "atelier-$version-macos-arm64.tar.gz" && $tag == "v$version" ]] || die 'manifest asset and tag must follow the version'
if [[ $channel == dev ]]; then
  token='atelier@dev'; other=atelier
  note='This cask follows the newest dev release; each dev release replaces the previous one.'
else
  token=atelier; other='atelier@dev'
  note='Stable releases keep their versioned downloads.'
fi
cat > "$output/$token.rb" <<CASK
cask "$token" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/$repository/releases/download/v#{version}/atelier-#{version}-macos-arm64.tar.gz"
  name "Atelier"
  desc "Customizable workspace on Hammerspoon 2: Desktops, Groups, and Quick Apps"
  homepage "https://github.com/$repository"

  conflicts_with cask: "jeremytondo/atelier/$other"
  depends_on cask: "jeremytondo/atelier/hammerspoon2"
  depends_on arch: :arm64
  depends_on macos: :golden_gate

  binary "bin/atelier"
  artifact "share/atelier", target: "#{HOMEBREW_PREFIX}/share/atelier"

  postflight do
    system_command "#{HOMEBREW_PREFIX}/bin/atelier", args: ["install"]
  end

  # Uninstall removes the package files. Zap also undoes what \`atelier install\`
  # wrote into Hammerspoon 2's settings and Login Items; the init file stays.
  zap login_item: "Hammerspoon 2",
      script:     {
        executable:   "/bin/sh",
        args:         ["-c",
                       "for key in configLocation hasCompletedOnboarding dockMenuBehaviour SUEnableAutomaticChecks; do defaults delete net.tenshu.Hammerspoon-2 \"\$key\" 2>/dev/null; done; true"],
        must_succeed: false,
      }

  caveats <<~EOS
    $note
    Your configuration is ~/.config/atelier/init.js and is never removed.
    Run \`atelier doctor\` to check the installation.
  EOS
end
CASK
echo "$output/$token.rb"
