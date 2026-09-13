# Hammerspoon 2 alpha validation — September 13, 2026

The replacement app packages HS2 0.0.12, revision `7a218ddfc3c6c49246bff3e538c9c46e29a59caf`, with Atelier's JavaScript defaults and native gap helpers. The local validated bundle is `0.1.0-local`, build `20260913232358`, targeting Apple silicon and macOS 26.

## Passed locally

- The HS2 host builds through the shared Atelier Xcode scheme and the existing mise entry points. The native helper and configuration migrator build through SwiftPM.
- `mise run check`: HS2 host build, 22 native tests, 12 JavaScript tests, shell/workflow lint, and release behavior tests passed. Packaging-only signing changes were followed by the release checks and another packaged runtime probe.
- The app and all nested executables/services pass strict code-signature verification with Hardened Runtime. HS2's AppleScript service has its own automation entitlement.
- The actual bundled HS2 engine loads Atelier modules, exposes the required hotkey/AX/canvas APIs, runs timers, captures process output, and communicates with a private fixture through the production JSON-lines bridge.
- The runtime probe starts the defaults with all shortcuts disabled, pauses, resumes, and verifies that the fixture helper exits. It also executes `return 2 + 2` through the bundled AppleScript XPC service.
- Bootstrap creates JavaScript configuration in an isolated directory and preserves a subsequently customized file. Native tests verify TOML migration, preservation of source files and user edits, and failure on invalid legacy data.
- JavaScript tests cover configurable/default bindings, conflicts, exact same-app Group selection, deferred Fill, inactive Group membership, PID identity changes, overlay coordinate conversion, malformed/fragmented helper replies, timeout without mutation replay, interrupted startup, and cleanup after partial startup or overlapping actions.

The runtime probe loads no real user configuration and registers no hotkeys. No existing app was replaced or launched, and no user windows or Desktops were mutated during this implementation pass.

## Manual laptop trial

The prior prototype and native alpha provide live workflow evidence, but those results do not certify this new bundle. On the laptop, validate Accessibility onboarding, physical shortcuts, Spaces/Groups/Quick Apps, custom JavaScript and repeated reload, app replacement, sleep/wake, multiple displays, and normal resource usage. Instructions and supported limitations are in the app README. The dev release workflow independently builds the final source and requires notarization, stapling, and Gatekeeper assessment before publication.
