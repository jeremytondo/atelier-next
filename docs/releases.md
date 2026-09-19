# Installing and releasing

Atelier is installed with Homebrew from the shared tap [jeremytondo/homebrew-tap](https://github.com/jeremytondo/homebrew-tap), which holds other tools besides. There are two channels. Both need macOS 27 on Apple silicon, install `Atelier.app` with the `atelier` command inside it, and link the command onto your path. Neither involves Hammerspoon.

| Channel | Cask | What it follows |
| --- | --- | --- |
| Stable | `atelier` | Versioned releases, which keep their downloads for good |
| Development | `atelier@dev` | The newest development build; each one replaces the last |

## Install, update, and switch

Install by full name the first time, which also adds the tap:

```sh
brew install --cask jeremytondo/tap/atelier        # or jeremytondo/tap/atelier@dev
```

After that the short names do: `brew upgrade --cask atelier`, `brew uninstall --cask atelier@dev`. After installing or upgrading, run `atelier doctor`; it checks that the command, the installed app, and the running app are the same build. The app keeps macOS's quarantine protection for its first launch. The cask removes quarantine only from the command inside it, because launching that nested executable directly does not reliably surface the app's first-launch confirmation.

The two channels are the same app in the same place, so only one is installed at a time, and they share its settings, its window lists, its Accessibility permission, and its place in Login Items. To switch, uninstall one and install the other:

```sh
brew uninstall --cask atelier
brew install --cask jeremytondo/tap/atelier@dev
```

Installing, upgrading, switching, and uninstalling all leave `~/.config/atelier/` and the window lists alone. `brew uninstall --zap` removes the window lists and the record of the first launch, and never the configuration.

On an upgrade Homebrew quits a running Atelier, which finishes any command in progress first, and opens the new one afterwards; an Atelier that was closed stays closed. Homebrew's quit needs permission to control Atelier, and says so when it lacks it. The old app then keeps running beside the new command: `atelier doctor` reports the older build still running, and `atelier restart` replaces it with the installed one. The cask cannot do that for you, since Homebrew runs a cask's steps without the network, which counts Atelier's socket.

## Coming from the Hammerspoon version

The tap used to be called `jeremytondo/homebrew-atelier`, and `atelier@dev` used to be the Hammerspoon version. GitHub redirects the old name, but an installation made under it should be moved by hand. These steps have not yet been tried against a published native build:

```sh
brew uninstall --cask atelier@dev          # the Hammerspoon version; your files stay
brew untap jeremytondo/atelier
brew install --cask jeremytondo/tap/atelier@dev
```

`hammerspoon2@dev` is left installed until you remove it yourself. If `/Applications/Atelier.app` is a copy you put there by hand, Homebrew will not replace it: move it to the Trash first. The native app reads `~/.config/atelier/config-next.toml`; the Hammerspoon version's files are not read and not touched.

## Releasing

A release is started by hand and never by a push:

```sh
mise run release dev            # the development build of main
mise run release minor          # the next stable minor version; also patch, major
mise run release dev my-branch  # a branch other than main

# The established names remain available too:
mise run release:dev
mise run release:minor
```

It releases the branch as it is on GitHub; nothing local is pushed. `.github/workflows/release.yml` and the scripts it runs, each with its own header, are the reference for how. What they promise:

- The app, the command inside it, and the release's metadata name the same build, or nothing is produced. A development build's number is the UTC time, so it always advances, which is how Homebrew sees an upgrade.
- The tap changes only after the published download has been fetched back and its checksum matches, and only that channel's cask changes. A failure before then takes back what the run put on GitHub, so what people can install is as it was; stable is the fallback for a bad development build.
- Stable releases are never overwritten. The development channel is one GitHub prerelease, tagged `dev`, holding the newest build alone.
- Release titles are `Atelier Dev 0.0.1-dev.20260918214704` for development builds and `Atelier 0.0.1` for stable versions. Each release includes Homebrew install and upgrade instructions and a list of the PRs included since the latest stable version in its history. Until the first stable release, the list covers the full history. Rolling Dev notes therefore keep all changes awaiting a stable release.

`scripts/publish.sh … --dry-run` changes nothing and says what a real run would do; it cannot tell whether the tap's token works. `mise run package` makes the signed app locally without notarizing, for looking at, and the publisher refuses it.

The first native development release transitions the rolling `dev` release left by the Hammerspoon version. Its three known assets stay in place until the native download is verified and the tap points at it, then the publisher removes them. An unrecognized asset still stops publication rather than being deleted. The Hammerspoon version's other releases are what its casks download from; remove them once nothing installed needs them.

The casks are what require macOS 27. The app's own deployment target stays 26.0, the newest that the Xcode on GitHub's `macos-26` runners can build for.

## One-time GitHub setup

The `release` environment of this repository holds `ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64` and `ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD` (the exported Developer ID Application identity with its private key), `ATELIER_APP_STORE_CONNECT_KEY_BASE64` (the App Store Connect API key used for notarization), and the variables `ATELIER_APP_STORE_CONNECT_KEY_ID` and `ATELIER_APP_STORE_CONNECT_ISSUER_ID`. The repository secret `ATELIER_TAP_TOKEN` is a fine-grained token that may write the contents of the tap and nothing else. Only the job that signs sees the signing credentials, and only the job that publishes may write releases.
