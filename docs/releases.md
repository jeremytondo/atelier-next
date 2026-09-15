# Builds and releases

Atelier publishes to [jeremytondo/homebrew-atelier](https://github.com/jeremytondo/homebrew-atelier), tapped as `brew tap jeremytondo/atelier`. Stable releases update `atelier` and `hammerspoon2`; rolling dev releases update `atelier@dev` and `hammerspoon2@dev`. A release updates only its own channel. Each HS2 cask installs either an official upstream ZIP or an Atelier-built, signed, notarized snapshot.

Both channels are manual: `mise run release:dev` or `release:patch|minor|major`, or GitHub's **Run workflow** button. Pushes to `main` run checks only. Each Atelier release carries its package, a manifest recording the exact HS2 download, and checksums. Xcode and mise are needed only for development and builds.

## Install, update, and switch channels

After `brew tap jeremytondo/atelier`, choose one channel:

| Channel | Install | Update both packages |
| --- | --- | --- |
| Stable | `brew install --cask atelier` | `brew upgrade --cask hammerspoon2 atelier` |
| Rolling dev | `brew install --cask atelier@dev` | `brew upgrade --cask hammerspoon2@dev atelier@dev` |

Quit Hammerspoon 2 before updating its app and run `brew update` before upgrading. An upgrade stays on the selected channel. Run `atelier doctor` afterwards to check the installed build and setup.

The channels install to the same locations and cannot coexist. To switch from stable to dev, quit Hammerspoon 2, then run:

```sh
brew uninstall --cask atelier hammerspoon2
brew install --cask atelier@dev
```

For dev to stable, uninstall `atelier@dev hammerspoon2@dev` and install `atelier`. Ordinary uninstall preserves `~/.config/atelier/init.js` and the HS2 settings; do not use `--zap` when switching. Changing between upstream-signed and Atelier-signed HS2 may require granting permissions again; verify this on the target Mac.

## Hammerspoon 2 builds

`hammerspoon2.json` remains the source of truth for source revision, source checksum, expected app build number, and optional upstream release tag/ZIP checksum.

- **Official release:** packaging verifies the tag resolves to the pinned commit, downloads and checks the ZIP, and verifies its app build and signature. It never compiles HS2 or silently falls back to a snapshot.
- **Snapshot:** packaging calculates an identifier from HS2's source, build number, arm64 target, Xcode/SDK, XcodeBuildMCP version, relevant build scripts and entitlements, and signing certificate. It reuses a published matching ZIP after checksum, build, and signature verification. Otherwise it builds unpatched source, signs with Developer ID, notarizes, and staples the app before creating the ZIP.

Snapshots are permanent `hs2-<input-hash>` releases in `atelier-next`. They are excluded from Atelier version selection and rolling-dev cleanup, and never overwritten. Both channels can reuse the same snapshot. Changes to Atelier defaults, API, providers, or version do not rebuild HS2. GitHub errors, incomplete snapshot drafts, and mismatched or corrupt published assets stop the release; inspect the failed snapshot before retrying.

To upgrade HS2, update the pin (including the official release's actual commit, source checksum, and build number when selecting one), run `mise run refs:update` and `mise run check`, then perform the README's manual trial and use the build for a day before publishing. Verify a clean Homebrew install, a dependency upgrade, and both channel switches on a Mac without the source checkout. App launch and real Desktop behavior remain manual checks.

## Everyday commands

Install Xcode and mise, then run `mise install`. Use `mise tasks` or `scripts/build-package.sh --help` to discover the available commands.

| Command | Result |
| --- | --- |
| `mise run check` | Full gate: TypeScript and Swift tests, lint, release/build/CLI fixtures, and a locally signed package |
| `mise run build` | Local package under `dist/` |
| `mise run dev` | Build and copy the package into the Homebrew prefix; reload Hammerspoon 2 yourself |
| `mise run hs2:build` / `hs2:install` | Dev only: stock Hammerspoon 2 at the pin, optionally replacing the installed app |
| `mise run casks dist/release/manifest.json` | Preview the selected channel pair in `dist/casks/` |
| `mise run release:dev` | Dispatch a dev release of remote `main` and return its link |
| `mise run release:dev BRANCH` | Dispatch a dev release of the selected remote branch |
| `mise run release:patch` | Dispatch the next stable patch release and return its link |
| `mise run release:minor` | Dispatch the next stable minor release and return its link |
| `mise run release:major` | Dispatch the next stable major release and return its link |
| `mise run release:plan stable minor` | Preview version metadata without publishing |

Release commands require authenticated `gh` access with permission to run workflows. Each task verifies the remote branch exists, calls `gh workflow run`, prints the run URL when GitHub returns it, and exits without waiting for the build. Follow the link for the release result, or watch with `gh run watch RUN_ID --exit-status`. All four release commands accept an optional branch name, defaulting to `main`. They release the remote branch snapshot selected by GitHub and never push local changes or merge the branch. Tags are rejected as sources.

## Versions

Stable numbering uses the greatest plain `vX.Y.Z` tag: with no stable tags, `release:minor` produces v0.1.0 and `release:patch` produces v0.0.1. A dev release is versioned `X.Y.Z-dev.<build>`, where `X.Y.Z` is the next patch version and the build is the UTC build time with seconds, and is tagged `v<version>` as a prerelease. After it is published and the tap points at it, the previous dev release and its tag are deleted, so exactly one dev release exists at a time; stable releases keep their versioned downloads forever. Both channels record the version, source commit, channel, build time, and the Hammerspoon 2 pin in `manifest.json` and in the installed `version.json`, which `atelier version` and `atelier.status()` report. Local builds are versioned `local.<build>+<commit>`.

## One-time GitHub setup

In this repository's **Settings → Environments**, create a `release` environment with **Selected branches and tags** and a branch rule of `**/*`. Configure these values there, using the same Apple Developer account and credential types as ATC:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64 of the exported Developer ID Application `.p12`, including its private key |
| Secret | `ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| Secret | `ATELIER_APP_STORE_CONNECT_KEY_BASE64` | Base64 of the App Store Connect API `.p8` key used for notarization |
| Variable | `ATELIER_APP_STORE_CONNECT_KEY_ID` | API key ID |
| Variable | `ATELIER_APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |

The public tap `jeremytondo/homebrew-atelier` needs an initialized `main` branch; the publisher creates `Casks/` on the first release of each channel. Add an `atelier-next` repository secret `ATELIER_TAP_TOKEN` (a fine-grained token with contents write access to that repository only) so the publish job can push cask files. The publisher checks that the token is present before creating releases. It is never needed for local checks.

Prepare and upload the signing credentials as follows. Base64 is an encoding, not encryption; treat the copies as credentials and delete them afterwards.

1. In **Keychain Access → My Certificates**, export the **Developer ID Application** identity, including its private key, as a password-protected `.p12`, saved outside the repository.
2. In **App Store Connect → Users and Access → Integrations → App Store Connect API**, create a team API key, record its key ID and issuer ID, and download the `.p8` once.
3. Encode and upload:

```sh
umask 077
base64 -i /private/path/DeveloperID.p12 -o /private/path/DeveloperID.p12.base64
base64 -i /private/path/AuthKey_KEYID.p8 -o /private/path/AuthKey_KEYID.p8.base64
gh secret set ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64 --repo jeremytondo/atelier-next --env release < /private/path/DeveloperID.p12.base64
gh secret set ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD --repo jeremytondo/atelier-next --env release
gh secret set ATELIER_APP_STORE_CONNECT_KEY_BASE64 --repo jeremytondo/atelier-next --env release < /private/path/AuthKey_KEYID.p8.base64
gh variable set ATELIER_APP_STORE_CONNECT_KEY_ID --repo jeremytondo/atelier-next --env release --body YOUR_KEY_ID
gh variable set ATELIER_APP_STORE_CONNECT_ISSUER_ID --repo jeremytondo/atelier-next --env release --body YOUR_ISSUER_ID
gh secret set ATELIER_TAP_TOKEN --repo jeremytondo/atelier-next
```

The workflow imports the certificate into a temporary runner keychain, restores the prior keychain search list, and removes the imported credentials when packaging exits. Signing secrets are used only by manual branch releases, never in pull-request checks. Repository-wide release immutability must stay disabled, because dev releases are deleted when the next one replaces them; stable releases are protected by the publisher refusing to overwrite any existing tag or release.

## Pipeline behavior

`.github/workflows/release.yml` has only a manual `workflow_dispatch` trigger with a `bump` choice of `dev`, `patch`, `minor`, or `major`. It plans the selected commit, checks credentials and the Developer ID identity before expensive work, runs the full gate through `release:verify-package`, and packages the providers binary that gate verified. The binary is signed with Developer ID and a secure timestamp, notarized, and verified; a bare executable cannot carry a stapled ticket, so Gatekeeper checks the notarization online. There is no unsigned fallback for either channel.

Dev and stable runs share one concurrency group, serializing the entire workflow across all source branches so snapshot publication and tap pushes cannot race. Dev checks that its commit is still the head of its selected source branch before compilation, before notarization, and immediately before publication; an obsolete build is skipped. Stable dispatches retain their selected commit even if their source branch advances. Publication uses Ubuntu with a separate mise configuration containing only `gh` and `jq`, verifies both packages and their manifests, publishes any new permanent HS2 snapshot, creates the Atelier release as a draft, publishes it, pushes the selected channel casks, and only then deletes the previous dev release.

For local distribution validation, create a plan with `mise run release:plan dev BRANCH > release-plan.json`, set `ATELIER_NOTARY_PROFILE` to an existing notarytool keychain profile (or the three `ATELIER_APP_STORE_CONNECT_*` key-path/ID/issuer variables), then run `mise run release:package release-plan.json --output-dir dist/release`. This packages without uploading. `mise run casks dist/release/manifest.json` previews the cask files that publication would push.

## Checks

`mise tasks` lists the focused TypeScript, Swift, lint, and fixture checks; `mise run format` applies the formatters that `mise run lint` enforces. The Check workflow runs the portable half of the gate on Ubuntu and the native half on macOS for every push and pull request; both jobs are required. The native job caches only the compressed unsigned providers output keyed by its exact inputs; releases restore none of it. Build state lives under `.build/`: downloaded upstream source, fetched type declarations, the verified providers output and its receipt, and locks. The scripts under `scripts/` document how those outputs are verified and reused.
