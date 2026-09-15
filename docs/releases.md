# Builds and releases

Atelier ships as Homebrew casks in the public tap `jeremytondo/homebrew-atelier`, tapped as `brew tap jeremytondo/atelier`: `hammerspoon2` installs upstream's signed and notarized release ZIP at the pinned tag, `atelier` installs the newest stable release and depends on `hammerspoon2`, and `atelier@dev` installs the newest dev release. Each release is a GitHub release carrying `atelier-<version>-macos-arm64.tar.gz`, `manifest.json`, and `checksums.txt`; the release workflow generates the three cask files from the pin and the manifest and pushes them to the tap. Both channels are manual: `mise run release:dev` or `release:patch|minor|major`, or GitHub's **Run workflow** button. Pushes to `main` run checks only. Build automation is shell, macOS tools, and mise; Xcode is required only on build machines.

The tap only ever references upstream release ZIPs. While `hammerspoon2.json` has `"release": null` because the pin is ahead of the newest upstream release, the workflow still creates the GitHub release but skips the tap; the first published casks wait for the upstream release the pin needs. Development meanwhile uses `mise run hs2:install`.

## Everyday commands

Install Xcode and mise, then run `mise install`. Use `mise tasks` or `scripts/build-package.sh --help` to discover the available commands.

| Command | Result |
| --- | --- |
| `mise run check` | Full gate: TypeScript and Swift tests, lint, release/build/CLI fixtures, and a locally signed package |
| `mise run build` | Local package under `dist/` |
| `mise run dev` | Build and copy the package into the Homebrew prefix; reload Hammerspoon 2 yourself |
| `mise run hs2:build` / `hs2:install` | Dev only: stock Hammerspoon 2 at the pin, optionally replacing the installed app |
| `mise run casks dist/casks` | Preview the generated cask files; add a manifest to preview `atelier` or `atelier@dev` |
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

Create the public repository `jeremytondo/homebrew-atelier` with a `Casks/` directory, and add a repository secret `ATELIER_TAP_TOKEN` (a fine-grained token with contents write access to that repository only) so the publish job can push cask files. The token is used only after the GitHub release exists and is never needed for checks.

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

Dev and stable runs each serialize the entire workflow across all source branches. Dev checks that its commit is still the head of its selected source branch before compilation, before notarization, and immediately before publication; an obsolete build is skipped. Stable dispatches retain their selected commit even if their source branch advances. Publication uses Ubuntu with a separate mise configuration containing only `gh` and `jq`, verifies the package checksums and manifest, creates the release as a draft, publishes it, pushes the casks, and only then deletes the previous dev release.

For local distribution validation, create a plan with `mise run release:plan dev BRANCH > release-plan.json`, set `ATELIER_NOTARY_PROFILE` to an existing notarytool keychain profile (or the three `ATELIER_APP_STORE_CONNECT_*` key-path/ID/issuer variables), then run `mise run release:package release-plan.json --output-dir dist/release`. This packages without uploading. `mise run casks dist/casks dist/release/manifest.json` previews the cask files that publication would push.

## Checks

`mise tasks` lists the focused TypeScript, Swift, lint, and fixture checks; `mise run format` applies the formatters that `mise run lint` enforces. The Check workflow runs the portable half of the gate on Ubuntu and the native half on macOS for every push and pull request; both jobs are required. The native job caches only the compressed unsigned providers output keyed by its exact inputs; releases restore none of it. Build state lives under `.build/`: downloaded upstream source, fetched type declarations, the verified providers output and its receipt, and locks. The scripts under `scripts/` document how those outputs are verified and reused.
