# Local alpha validation — September 13, 2026

Built and installed the standalone Atelier app in `/Applications` on Apple silicon running macOS 26.5.2 (25F84). The user granted Accessibility access to Atelier. The app and its bundled child engine both reported trusted access in that installed launch context. These are local alpha checks, followed by the user's normal daily-use trial.

Final installed version: **0.1.0, build 202609131403**. Final status was Running with no error and only the original Calculator Quick App. The ZIP is `dist/Atelier-0.1.0-202609131403-local.zip` (726,978 bytes). A final process sample showed roughly 66 MiB RSS / 0.4% CPU for the app and 30 MiB / 0.1% for its one child engine; this is a point-in-time sample, not a prolonged resource test. Neither process had an open file from the repository.

## Passed

- **Build/package:** SwiftPM debug/release builds; 20 automated tests; nested and outer code-signature verification with Hardened Runtime. The app bundle contains its own engine and icon. No prototype scripts or build tools are included in the runtime bundle.
- **Installation/update:** launched from the installed bundle; replaced it with a newer build under the same development signing identity. Accessibility remained granted and preferences were unchanged. The final app was launched normally, without the optional diagnostic command transport.
- **Groups:** created a Group on a disposable Desktop with three native fixture windows; selected exact members; native Fill reached the usable display; minimized members disappeared and rejoined when restored. The held-modifier overlay showed order, duplicate-app titles, and the correct focus highlight, then hid on release.
- **Focus comparison:** twelve selections in each implementation on the same three prefilled fixture windows. Native median focus **7.02 ms**, median complete selection **16.09 ms**. HS2 median focus **15 ms**, median complete selection **28 ms**. This is a small same-app fixture comparison, not a general performance guarantee. Raw samples are in [measurements](measurements-2026-09-13.json).
- **Spaces:** created and entered two disposable Desktops; reordered the populated one left and right while preserving its Space ID; removed the empty test Desktop; then deleted the populated test Desktop and verified all three fixture windows survived on the remaining Desktop. Both original Desktop IDs and their original order were restored. Option–1/2 switching was also exercised using synthetic keyboard events and verified against actual current Space IDs.
- **Calculator Quick App:** imported the existing Command–Shift–C shortcut; summoned without changing the active Desktop; hid on the next toggle and restored the previous exact fixture window. The registered shortcut was exercised with synthetic keyboard events. Calculator remained excluded from the Group, and summon/hide worked on a second ordinary Desktop.
- **Resizable Quick App:** used a disposable app selected by absolute `.app` path. Verified an actual **700 × 500** AX frame centered at **(385, 226)** on the test display. Restored its selected window after all three app windows were verified minimized; relaunched after quitting the app; exercised Control–Option–J; verified all of its windows stayed out of Groups.
- **Quick App errors:** a missing app and duplicate app identity each produced an entry-specific error while Atelier and the valid Quick Apps kept running. These entries were removed after the test.
- **Shortcut recorder:** recorded the existing Calculator shortcut through the native Settings control; the app paused while recording, retained the expected shortcut, and resumed successfully.
- **Recovery:** forced the owned engine to exit and verified Atelier entered its failure state with an unknown-outcome message. Resumed successfully, then completed eight pause/resume cycles without leftover child processes. Automated tests cover fragmented replies, timeout, malformed output, unexpected exit, and a cancelled startup not stopping its replacement session.
- **Cleanup:** closed only the disposable fixture apps, removed both test Desktops, restored the user's Quick App list, and returned to original Desktop 14. Atelier's prototype loader remains disabled; unrelated HS2 configuration is preserved. The original loader was backed up as `~/.config/hammerspoon2/init.js.before-atelier-app-20260913133950`.

## Defect found and fixed

Initially, a Quick App selected by path could resolve at startup but fail on toggle because the request discarded the path and sent only a bundle ID that Launch Services had not indexed. Toggles now retain the configured app reference and separately validate the expected bundle ID before acting. The unregistered disposable app then launched, centered, minimized/restored, and relaunched successfully.

## Still needs daily-use coverage

Real physical rapid shortcut sequences; additional applications including 1Password; multi-display placement/reconnect; non-US keyboard layouts; sleep/wake and actual login launch; permission revocation; Dock restart; and a prolonged CPU/memory soak. The temporary-shortcut recovery decision is unit-tested, but a forced kill during the short native shortcut-enable interval was not exercised live. macOS 27 and Intel have not been validated.

Groups remain session-only. Persistent workspace restoration, window movement between Spaces, fullscreen overlays, and external notarized distribution are outside this alpha.

## Captured interface

[Group overlay](group-overlay.png) and [Quick App Settings](quick-app-settings.png). The Settings capture shows the onboarding permission state before access was granted; the installed app subsequently entered Running.
