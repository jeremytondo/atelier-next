# Atelier for macOS

Atelier is a standalone menu-bar app for native Desktops, window Groups, and Quick Apps. This first local alpha targets Apple silicon on macOS 26. It has no Hammerspoon, Node, Python, or repository dependency at runtime.

## Install and start

Drag `Atelier.app` into `/Applications` and open it. Enable **Atelier** in **System Settings → Privacy & Security → Accessibility**, then press **Resume**. Choose **Open Configuration…** from the menu-bar icon to edit `~/.config/atelier/config.toml`. Saving does not apply changes: use **Reload Configuration** or **Control–Option–Command–R**. All bindings, Quick Apps, feature switches, and launch at login are configured in TOML. See the [configuration reference](Resources/Configuration.md) for syntax, includes, and migration. The reference is also bundled in the app.

GitHub release builds use Developer ID signing and Apple notarization. Local builds use an Apple Development signature when available and are not notarized. Keep the bundle and signing identities consistent when producing updates. Accessibility access survived the local replacement test, but the first switch from a local build to a release may require granting it again.

## Use

| Shortcut | Action |
| --- | --- |
| Control–Option–Command–R | Reload configuration (also available while paused) |
| Option–1…9 / 0 | Switch to Desktop 1…10 on the focused window's display; pointer fallback |
| Option–` | Create and enter a Desktop |
| Control–Option–Left / Right | Reorder the current Desktop |
| Control–Option–Delete | Delete the current Desktop; refuse the final Desktop |
| Command–Option–G | Create or repair a Group on the current Desktop |
| Hold Command–Option | Show the Group's ordered window list |
| Command–Option–1…9 / 0 | Select Group member 1…10 |
| Command–Option–[ / ] | Cycle Group members |

Groups track eligible windows as they open, close, hide, or minimize. Focused members use macOS's native Fill. An unsupported Fill is reported rather than silently applying different geometry. The overlay passes clicks through and updates its highlight as focus changes.

Groups stay in memory while paused, and reset when Atelier quits. Preferences and Quick App definitions persist across relaunches. Fullscreen Spaces are excluded from Desktop numbering. Sending windows between Spaces and fullscreen overlays are outside this alpha.

## Quick Apps

Add a named entry to `config.toml` (or an explicitly included `quickapps.toml`), then reload:

```toml
[quickapps.calculator]
app = "Calculator"
shortcut = "cmd-shift-c"
# size = [900, 650]
```

Press the shortcut to launch/reopen, unhide, center, and focus an app on the current display. Press it while that app is frontmost to hide the app and restore the previous exact window if it still exists on the same active Desktop. An unfocused visible app is brought forward. Minimized windows are restored. Quick Apps are excluded from Groups and Fill.

Sizes are clamped to the usable display, and apps may enforce their own minimum size. Hiding affects the entire app. All Desktops assignment is automatic and verified; its Dock fallback can persist after removing the Quick App. To undo it, use **Dock → Options → Assign To → None**. This is a normal foreground app window, without an always-on-top guarantee.

A rejected reload leaves the running configuration active and reports the problem through **View Issue…**. TOML, types, unknown options, conflicts, and enabled app availability are checked before applying a reload. At launch, unavailable Quick Apps are reported while other valid features can start. macOS does not expose every shortcut another application may intercept.

When TOML does not yet exist, Atelier migrates the earlier app's `settings.json`, or otherwise imports literal Quick Apps from `~/.config/hammerspoon2/quickapps.js`. Source files are preserved and never executed. Once TOML exists, the legacy files are no longer read. Unrelated Hammerspoon configuration stays with Hammerspoon; the standalone app has no Hammerspoon runtime dependency.

## Pause, recover, and diagnose

**Pause** releases window-operation shortcuts, keeps the configuration reload shortcut, hides the overlay, stops observers, and stops the bundled engine. **Resume** starts a fresh engine and refreshes actual Desktop state. An engine crash or timeout pauses operations and reports that an interrupted mutation may already have completed. Inspect the Desktop before resuming; mutations are never replayed automatically.

Atelier releases temporary native shortcut enables on normal shutdown. A small recovery journal handles interrupted changes on the next launch when the boot, key assignment, and persisted preference still match. A forced kill cannot perform immediate cleanup. Sleep pauses the runtime and wake resumes it if it had been running. OS updates can change the private Desktop/AX mechanisms; a startup failure remains visible in Status.

Use **Export Diagnostics** when reporting a problem. Exports include versions, permission state, recent errors/timings, and Desktop/Group state. Window titles are omitted. No diagnostics are uploaded automatically.

Local files:

- `~/.config/atelier/config.toml`: user-owned configuration; optional explicit includes.
- `~/Library/Application Support/Atelier/settings.json`: preserved legacy preferences for rollback; ignored once TOML exists.
- `~/Library/Application Support/Atelier/status.json`: recent state and diagnostics without window titles.
- `~/Library/Logs/Atelier/`: bounded rotating event logs.

## Build and update

Install Xcode and mise on the build machine. From the repository root:

```sh
mise install
mise run check
mise run dev
```

Quit the running app before replacing it. `mise run build` produces `dist/Atelier.app` and a versioned local ZIP; `mise run install` also installs it, and `mise run dev` launches it. Previous installed builds are backed up under `dist/Atelier-previous.*/Atelier.app`. The shell packaging script builds the executables, creates the icon, bundles the helper, signs with Hardened Runtime, and verifies signatures. `--identity` or `ATELIER_SIGN_IDENTITY` selects a signing identity; local builds default to Apple Development, then ad-hoc. `--build-number` sets a reproducible local build label.

Both release channels are manual. `mise run release:dev` publishes the rolling **dev** prerelease from remote `main`; `mise run release:patch`, `release:minor`, or `release:major` publishes a permanent semantic version. Pushes to `main` run checks only. Each GitHub release includes a notarized `Atelier-macos-arm64.zip`, build manifest, and checksums. Download the ZIP, quit Atelier, and replace the app in `/Applications`. Both channels share the app identity and configuration. See [release setup and downloads](../docs/releases.md). Automatic in-app updates are not yet implemented.

To roll back, quit Atelier and replace `/Applications/Atelier.app` with a previous local bundle. The earlier Settings-based build reads the preserved legacy JSON, so new TOML changes will not carry back. For removal, set `launch-at-login = false`, reload, quit Atelier, and remove the application. Configuration/logs can be removed separately; undo any persistent Quick App Dock assignments explicitly.

To return to the old prototype, quit Atelier, run `python3 Prototypes/Hammerspoon2/setup.py install`, and reload HS2. Keep only one version active. The app installation handoff backed up the original HS2 config before removing only Atelier's marked loader.

## Development and validation

`Sources/Atelier` owns the native interface, shortcuts, Group coordination, AX focus/observation, and asynchronous Fill verification. `AtelierCore` contains testable models/configuration and lifecycle rules. TOML parsing uses the pinned Swift TOML 2.0.0 package with bundled toml++; third-party notices ship in Resources. `AtelierEngine` contains the extracted Space and Quick App mechanisms, hosted by `atelier-engine` through a versioned JSON-lines protocol. `NativeMenuDispatch`, `QuickAppSupport`, and `SpaceControlCore` are production copies extracted from the earlier experiments; the prototypes remain a frozen runnable reference. The private WindowManagement transaction experiments are not linked into the app.

`atelier-tools` is a build/test utility for the icon, disposable fixture windows, and synthetic shortcut checks. It is not included in the installed app. Optional `--diagnostic-control` enables a private local fixed-command test transport; ordinary launches do not run it:

```sh
xcodebuildmcp macos launch --app-path /Applications/Atelier.app --launch-args=--diagnostic-control
mise run app:command '{"command":"status"}'
```

Run live mutation checks only on disposable Desktops and saved test windows. See [local validation](Evidence/local-alpha-2026-09-13.md) for measured results and the checks still needed during daily use.
