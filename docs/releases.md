# Builds and releases

Atelier uses ATC's release channels: a rolling `dev` prerelease from `main` and permanent `vMAJOR.MINOR.PATCH` stable releases. Both channels publish only when manually requested through mise or GitHub's **Run workflow** button. Pushes to `main` run checks only. Build automation is shell, macOS tools, and mise; it has no Python dependency. Xcode is required only on build machines. Distributed apps target Apple silicon and macOS 26 or later.

## Install on another Mac

- [Rolling dev ZIP](https://github.com/jeremytondo/atelier-next/releases/download/dev/Atelier-macos-arm64.zip)
- [Latest stable ZIP](https://github.com/jeremytondo/atelier-next/releases/latest/download/Atelier-macos-arm64.zip)
- [Release history and build details](https://github.com/jeremytondo/atelier-next/releases)

These downloads become available after the corresponding first successful release. Unzip, quit Atelier, and move `Atelier.app` into `/Applications`. Grant Accessibility access on the first install. The app and signing identity are shared between channels, so they replace one another and use the same `~/.config/atelier` configuration. Changing from the original Apple Development signature may require a new Accessibility grant once. Only one Atelier instance runs at a time.

To roll back, download an earlier stable release or use the previous bundle saved by `mise run install`. The `dev` assets are replaced on every successful publication; GitHub Actions retains each build's package artifact for 14 days. Configuration compatibility still matters when rolling back. Updates currently use downloaded ZIPs; Sparkle integration is separate work.

## Everyday commands

Install Xcode and mise, then run `mise install`. Use `mise tasks` or `scripts/build-app.sh --help` to discover the available commands.

| Command | Result |
| --- | --- |
| `mise run check` | App tests, shell/workflow lint, release behavior tests |
| `mise run build` | Local signed app and ZIP in `dist/` |
| `mise run install` | Build and install, backing up the previous app |
| `mise run dev` | Build, install, and launch |
| `mise run release:dev` | Dispatch and watch a rolling dev build of remote `main` |
| `mise run release:patch` | Dispatch and watch the next stable patch release |
| `mise run release:minor` | Dispatch and watch the next stable minor release |
| `mise run release:major` | Dispatch and watch the next stable major release |
| `mise run release:plan stable minor` | Preview version metadata without publishing |

Release commands require authenticated `gh` access with permission to run workflows. They always release the remote `main` snapshot selected by GitHub, and never push local changes. The task names and `bump` input follow [ATC's GitHub configuration](https://github.com/jeremytondo/atc/blob/main/mise.toml). ATC also accepts other pushed refs; Atelier currently restricts signing and publication to `main`. PR builds run checks only.

Stable numbering uses the greatest plain `vX.Y.Z` tag, ignoring `dev`, calendar dev versions, and prerelease tags. With no stable tags, the baseline is `v0.0.0`: `release:minor` produces **v0.1.0**, and `release:patch` produces v0.0.1. A release changes the packaged version without editing the source Info.plist. The first workflow must reach `main` before dispatch commands are available.

Dev versions follow ATC's calendar convention, for example `2026.9.13-dev.t163012+abc12345`. Both channels stamp the full version, source commit, channel, and UTC build time into the app and release manifest. `CFBundleVersion` is a numeric UTC timestamp with seconds, continuing the local alpha's timestamp convention. Read the installed version with `/Applications/Atelier.app/Contents/MacOS/Atelier --version`; diagnostic exports also include the version, channel, and commit.

## One-time GitHub setup

In this repository's **Settings → Environments**, create a `release` environment restricted to the `main` branch. Configure these values there, using the same Apple Developer account and credential types as ATC:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64 of the exported Developer ID Application `.p12`, including its private key |
| Secret | `ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| Secret | `ATELIER_APP_STORE_CONNECT_KEY_BASE64` | Base64 of the App Store Connect API `.p8` key used for notarization |
| Variable | `ATELIER_APP_STORE_CONNECT_KEY_ID` | API key ID |
| Variable | `ATELIER_APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |

ATC's encrypted GitHub secrets cannot be read back and copied by `gh`; use the original credential files or configure organization secrets shared with this repository. Do not commit credentials. The workflow imports the certificate into a temporary runner keychain, restores the prior keychain search list, and removes the imported credentials when packaging exits. Local builds continue to use the existing local keychain.

The workflow needs `contents: write` only in its publication job; the package job has read access. Signing secrets are used only on `main`, never in pull-request checks. The repository must allow Actions to publish releases. **Repository-wide release immutability must remain disabled for ATC-style mutable `dev` releases.** Stable releases are protected by the publisher refusing to overwrite any existing stable tag or release. See [GitHub's immutable release behavior](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).

## Pipeline behavior

`.github/workflows/release.yml` has only a manual `workflow_dispatch` trigger with a `bump` choice of `dev`, `patch`, `minor`, or `major`. An optional `request_id` lets the CLI watch the exact run it dispatched. The workflow calls the same mise tasks used locally: check, plan, package, publish. Dev and stable runs each serialize the entire workflow. New queued requests can supersede older queued requests; running publication is not canceled halfway through replacing assets. Immediately before dev publication, the publisher checks that the built commit is still `main`. An obsolete build is skipped; rerun `mise run release:dev` to release the new head. Stable dispatches retain their selected commit even if `main` subsequently advances.

Distribution packaging requires a valid Developer ID Application certificate, secure signing timestamps, accepted notarization, a stapled ticket, and successful Gatekeeper assessment. There is no unsigned fallback for either published channel. The ticket is stapled to the app before producing the final ZIP, following [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The publisher verifies the ZIP and manifest checksums before any release mutation. Stable releases are assembled as drafts, then published as the latest stable version. Dev is always a prerelease and never becomes GitHub's latest stable release. Updating multiple dev assets is not atomic; if a download overlaps publication, retry after the workflow finishes. A failed initial publication can leave a draft: inspect and finish or remove that draft explicitly before rerunning. Stable tags and published stable assets are never force-updated.

For local distribution validation, create a plan with `mise run release:plan dev > release-plan.json`, set `ATELIER_NOTARY_PROFILE` to an existing notarytool keychain profile (or set the three `ATELIER_APP_STORE_CONNECT_*` key-path/ID/issuer variables), then run `mise run release:package release-plan.json --output-dir dist/release`. This packages without uploading to GitHub. `--skip-build` is intended only for local packaging diagnosis; CI always compiles the current checkout.
