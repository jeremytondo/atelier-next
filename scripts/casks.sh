#!/usr/bin/env bash
# Generate only the selected channel pair from verified release metadata.
# Stable and dev may share a ZIP while keeping independent dependency casks.
# shellcheck disable=SC2154  # manifest fields are defined by load_release_plan
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# == 2 ]] || die 'usage: casks.sh OUTPUT_DIR MANIFEST.json'
output=$1
manifest=$2
load_release_plan "$manifest"
mkdir -p "$output"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-casks.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
jq -e .hammerspoon2 "$manifest" > "$temporary/pin.json"
jq -e .hammerspoon2_artifact "$manifest" > "$temporary/artifact.json"
"$root/scripts/validate-hammerspoon.sh" "$temporary/pin.json" "$temporary/artifact.json"
hs2_version=$(jq -r .version "$temporary/artifact.json")
hs2_sha256=$(jq -r .sha256 "$temporary/artifact.json")
hs2_url=$(jq -r .url "$temporary/artifact.json")
hs2_kind=$(jq -r .kind "$temporary/artifact.json")
asset=$(jq -er .asset "$manifest")
sha256=$(jq -er .sha256 "$manifest")
[[ $asset == "atelier-$version-macos-arm64.tar.gz" && $tag == "v$version" ]] || die 'manifest asset and tag must follow the version'
if [[ $channel == dev ]]; then
  token='atelier@dev'; other=atelier
  hs2_token='hammerspoon2@dev'; hs2_other=hammerspoon2
  note='This cask follows the newest dev release; each dev release replaces the previous one.'
else
  token=atelier; other='atelier@dev'
  hs2_token=hammerspoon2; hs2_other='hammerspoon2@dev'
  note='Stable releases keep their versioned downloads.'
fi
cat > "$output/$hs2_token.rb" <<CASK
cask "$hs2_token" do
  version "$hs2_version"
  sha256 "$hs2_sha256"

  url "$hs2_url"
  name "Hammerspoon 2"
  desc "Hammerspoon 2 tested with Atelier ($hs2_kind)"
  homepage "https://github.com/cmsj/Hammerspoon2"

  conflicts_with cask: "jeremytondo/atelier/$hs2_other"
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Hammerspoon 2.app"

  uninstall quit: "net.tenshu.Hammerspoon-2"

  zap trash: "~/Library/Preferences/net.tenshu.Hammerspoon-2.plist"
end
CASK
echo "$output/$hs2_token.rb"
cat > "$output/$token.rb" <<CASK
cask "$token" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/$repository/releases/download/v#{version}/atelier-#{version}-macos-arm64.tar.gz"
  name "Atelier"
  desc "Customizable workspace on Hammerspoon 2: Desktops, windows, and Quick Apps"
  homepage "https://github.com/$repository"

  conflicts_with cask: "jeremytondo/atelier/$other"
  depends_on cask: "jeremytondo/atelier/$hs2_token"
  depends_on formula: "jq"
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
