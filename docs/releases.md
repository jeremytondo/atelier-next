# Builds and releases

Atelier uses ATC's release channels: a rolling `dev` prerelease and permanent `vMAJOR.MINOR.PATCH` stable releases. Both channels can release a pushed repository branch and publish only when manually requested through mise or GitHub's **Run workflow** button. Pushes to `main` run checks only. Build automation is shell, macOS tools, and mise; it has no Python dependency. Xcode is required only on build machines. Distributed apps target Apple silicon and macOS 27 or later.

## Install on another Mac

- [Rolling dev ZIP](https://github.com/jeremytondo/atelier-next/releases/download/dev/Atelier-macos-arm64.zip)
- [Latest stable ZIP](https://github.com/jeremytondo/atelier-next/releases/latest/download/Atelier-macos-arm64.zip)
- [Release history and build details](https://github.com/jeremytondo/atelier-next/releases)

These downloads become available after the corresponding first successful release. Unzip, quit Atelier, and move `Atelier.app` into `/Applications`. Grant Accessibility access on the first install. The app and signing identity are shared between channels, so they replace one another and use the same `~/.config/atelier/init.js` configuration. Changing from the original Apple Development signature may require a new Accessibility grant once. Only one Atelier instance runs at a time.

To roll back, download an earlier stable release or use the previous bundle saved by `mise run install`. The `dev` assets are replaced on every successful publication; GitHub Actions retains each build's package artifact for 14 days. Configuration compatibility still matters when rolling back. Updates use downloaded ZIPs. The bundled HS2 host omits its upstream updater; all versions are built and published by Atelier.

## Everyday commands

Install Xcode and mise, then run `mise install`. Use `mise tasks` or `scripts/build-app.sh --help` to discover the available commands.

| Command | Result |
| --- | --- |
| `mise run check` | Full gate, including verified native builds and an isolated ad-hoc bundle probe |
| `mise run build` | Local signed app and ZIP in `dist/` |
| `mise run install` | Build and install without a ZIP, backing up the previous app |
| `mise run dev` | Build, install, and launch without a ZIP |
| `mise run release:dev` | Dispatch a rolling dev build of remote `main` and return its link |
| `mise run release:dev BRANCH` | Dispatch a rolling dev build of the selected remote branch |
| `mise run release:patch` | Dispatch the next stable patch release and return its link |
| `mise run release:minor` | Dispatch the next stable minor release and return its link |
| `mise run release:major` | Dispatch the next stable major release and return its link |
| `mise run release:plan stable minor` | Preview version metadata without publishing |

Release commands require authenticated `gh` access with permission to run workflows. Each task verifies the remote branch exists, calls `gh workflow run`, prints the run URL when GitHub returns it, and exits without waiting for the build. Its success means the request was accepted; follow the link for the release result. To watch explicitly, use `gh run watch RUN_ID --exit-status`. Runs are also listed on the repository's [Actions page](https://github.com/jeremytondo/atelier-next/actions/workflows/release.yml).

All four release commands accept an optional branch name, defaulting to `main`; for example, `mise run release:dev ate-37-build-workflows`. They release the remote branch snapshot selected by GitHub and never push local changes or merge the branch. The task names and `bump` input follow [ATC's GitHub configuration](https://github.com/jeremytondo/atc/blob/main/mise.toml). In GitHub's **Run workflow** menu, select the source branch. Tags are rejected. Automatic PR builds run checks only; signing requires a manual release dispatch from a repository branch containing this workflow.

There is one rolling `dev` release shared by all branches. A successful branch dev release replaces its assets and advances the `dev` tag to that branch's selected commit. The release manifest's `source_ref` and the release notes identify the source branch. Stable releases keep their existing permanent versioned tags and downloads.

Stable numbering uses the greatest plain `vX.Y.Z` tag, ignoring `dev`, calendar dev versions, and prerelease tags. With no stable tags, the baseline is `v0.0.0`: `release:minor` produces **v0.1.0**, and `release:patch` produces v0.0.1. A release changes the packaged version without editing the source Info.plist. The first workflow must reach `main` before dispatch commands are available.

Dev versions follow ATC's calendar convention, for example `2026.9.13-dev.t163012+abc12345`. Both channels stamp the full version, source commit, channel, and UTC build time into the app and release manifest. `CFBundleVersion` is a numeric UTC timestamp with seconds, continuing the local alpha's timestamp convention. Read the installed version with `/Applications/Atelier.app/Contents/MacOS/Atelier --version`; diagnostic exports also include the version, channel, and commit.

## One-time GitHub setup

In this repository's **Settings → Environments**, create a `release` environment with **Selected branches and tags** and a branch rule of `**/*`. This matches repository branches including names with slashes; do not add a tag rule. Only manually dispatch code you trust to use the signing credentials. Configure these values there, using the same Apple Developer account and credential types as ATC:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64 of the exported Developer ID Application `.p12`, including its private key |
| Secret | `ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| Secret | `ATELIER_APP_STORE_CONNECT_KEY_BASE64` | Base64 of the App Store Connect API `.p8` key used for notarization |
| Variable | `ATELIER_APP_STORE_CONNECT_KEY_ID` | API key ID |
| Variable | `ATELIER_APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |

ATC's encrypted GitHub secrets cannot be read back and copied by `gh`; use the original credential files or configure organization secrets shared with this repository. Do not commit credentials. The workflow imports the certificate into a temporary runner keychain, restores the prior keychain search list, and removes the imported credentials when packaging exits. Local builds continue to use the existing local keychain.

### Prepare and upload credentials

Use the existing Developer ID Application identity and a dedicated App Store Connect team API key for Atelier. The certificate signs the app; the API key authenticates notarization submissions. Both release channels use the same credentials.

1. In **Keychain Access → My Certificates**, select the existing **Developer ID Application** identity, including its associated private key, and export that identity as a password-protected `.p12`. Save it outside the repository. A downloaded `.cer` alone does not contain the private key needed for signing. This follows [GitHub's macOS signing setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
2. In **App Store Connect → Users and Access → Integrations → App Store Connect API**, create a **team API key** named `Atelier Releases`. Record its key ID and issuer ID, and download the `.p8` private key. Store the original in your password manager or secure credential storage; Apple only allows it to be downloaded once. The dedicated key can be revoked independently of ATC. See [Apple's API key instructions](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) and [notarization authentication](https://developer.apple.com/documentation/notaryapi/submitting-software-for-notarization-over-the-web).
3. Base64-encode the two files into private temporary files outside the checkout. Base64 is an encoding, not encryption; treat these copies as credentials too. Replace the example paths below with your files.

```sh
umask 077
base64 -i /private/path/DeveloperID.p12 -o /private/path/DeveloperID.p12.base64
base64 -i /private/path/AuthKey_KEYID.p8 -o /private/path/AuthKey_KEYID.p8.base64
```

4. Upload the encoded files directly to GitHub. The password command prompts for the `.p12` export password, keeping it out of shell history. Replace the example key and issuer IDs with those recorded in App Store Connect.

```sh
gh secret set ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64 --repo jeremytondo/atelier-next --env release < /private/path/DeveloperID.p12.base64
gh secret set ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD --repo jeremytondo/atelier-next --env release
gh secret set ATELIER_APP_STORE_CONNECT_KEY_BASE64 --repo jeremytondo/atelier-next --env release < /private/path/AuthKey_KEYID.p8.base64
gh variable set ATELIER_APP_STORE_CONNECT_KEY_ID --repo jeremytondo/atelier-next --env release --body YOUR_KEY_ID
gh variable set ATELIER_APP_STORE_CONNECT_ISSUER_ID --repo jeremytondo/atelier-next --env release --body YOUR_ISSUER_ID
```

5. Delete the temporary base64 copies, retain the originals securely, and run `mise run release:dev`. Follow the returned link to confirm signing, notarization, and publication succeed. Credentials never need to be pasted into chat or checked into source control.

The workflow needs `contents: write` only in its publication job; the package job has read access. Signing secrets are used only by manual branch releases, never in pull-request checks. The repository must allow Actions to publish releases. **Repository-wide release immutability must remain disabled for ATC-style mutable `dev` releases.** Stable releases are protected by the publisher refusing to overwrite any existing stable tag or release. See [GitHub's immutable release behavior](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).

## Pipeline behavior

`.github/workflows/release.yml` has only a manual `workflow_dispatch` trigger with a `bump` choice of `dev`, `patch`, `minor`, or `major`. It plans the selected commit, checks credentials and the Developer ID identity before expensive work, then runs the full gate through `release:verify-package` and packages the native outputs that gate verified.

Dev and stable runs each serialize the entire workflow across all source branches. New queued requests can supersede older queued requests; running publication is not canceled halfway through replacing assets. Dev checks that its commit is still the head of its selected source branch before compilation, before notarization, and immediately before publication. An obsolete build is skipped; rerun `mise run release:dev BRANCH` to release that branch's new head. An unavailable or deleted source branch fails without publishing. Stable dispatches retain their selected commit even if their source branch subsequently advances. Publication uses Ubuntu with a separate mise configuration containing only `gh` and `jq`.

Distribution packaging requires a valid Developer ID Application certificate, secure signing timestamps, accepted notarization, a stapled ticket, and successful Gatekeeper assessment. There is no unsigned fallback for either published channel. The ticket is stapled to the app before producing the final ZIP, following [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The publisher verifies the ZIP and manifest checksums before any release mutation. Stable releases are assembled as drafts, then published as the latest stable version. Dev is always a prerelease and never becomes GitHub's latest stable release. Updating multiple dev assets is not atomic; if a download overlaps publication, retry after the workflow finishes. A failed initial publication can leave a draft: inspect and finish or remove that draft explicitly before rerunning. Stable tags and published stable assets are never force-updated.

For local distribution validation, create a plan with `mise run release:plan dev BRANCH > release-plan.json`, set `ATELIER_NOTARY_PROFILE` to an existing notarytool keychain profile (or set the three `ATELIER_APP_STORE_CONNECT_*` key-path/ID/issuer variables), then run `mise run release:package release-plan.json --output-dir dist/release`. Plans describe the current checkout's commit; the optional branch records its intended remote source, defaulting to the Actions dispatch ref or `main` outside Actions. This packages without uploading to GitHub. See `scripts/build-app.sh --help` for `--skip-build`, which CI uses to package the outputs its own gate verified; release jobs never restore executable caches from other workflow runs.

## Checks

Use `mise tasks` to discover focused JavaScript, native, lint, release-fixture, build-fixture, and bundle checks; `mise run format` applies the formatters that `mise run lint` enforces. JavaScript tests run independently of native compilation. The full `check` task always retains Debug tests, Release helpers, and bundle validation.

Build state lives under `.build/` (prepared HS2 source, verified native outputs, and locks), separate from Xcode DerivedData and SwiftPM's `App/.build`. The scripts under `scripts/` document how those outputs are verified and reused.

The Check workflow runs the portable half of the gate on Ubuntu and the native half on macOS for every push and pull request. Both jobs are required. The native job caches only compressed unsigned host and helper outputs keyed by their exact inputs; GitHub isolates pull-request caches from `main`, releases restore none of them, and a damaged cache entry can be deleted through GitHub.

## Hammerspoon 2 dependency

The app is built from the HS2 revision pinned in `App/Hammerspoon/upstream.json`; [the integration guide](../App/Hammerspoon/README.md) covers source reconstruction, the upgrade gate, and the real-engine probe that packaging runs before notarization. XcodeBuildMCP builds the host's Atelier scheme; SwiftPM builds the native helper and build tools. Release manifests record both Atelier's commit and the HS2 revision.
