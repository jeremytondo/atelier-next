# Hammerspoon 2 integration

`upstream.json` pins the HS2 release, commit, and archive checksum. The build downloads that archive into `.build/downloads`, verifies it, and recreates `.build/hammerspoon2` with `atelier.patch`, `AtelierHost.swift`, and the shared Atelier scheme. Reference checkouts and prototypes never participate.

The patch preserves HS2's app and scripting architecture. It supplies Atelier's identity and configuration path, adds bootstrap/status/menu hooks, checks configuration exceptions, stops the previous defaults before resetting the JS context, and removes Sparkle's updater integration. Both menu and keyboard reloads go through HS2's existing manager. The host retains the old JS context briefly during helper shutdown so the next context cannot race the Space-operation lock. Upstream's dependency lockfile is used with automatic package resolution disabled.

Update the pin and checksum deliberately, rebase the patch with no fuzzy matches, and run `mise run check` plus a packaged build. Confirm API behavior and laptop workflows before releasing the new dependency. The pinned API's AX setter spelling, modifier-event observation, canvas coordinates, and exact-focus behavior are recorded beside their JavaScript adapters.

The native Quick App transaction remains a gap adapter: HS2 0.0.12 exposes only an activating launch and lacks All Desktops assignment. Atelier must launch/reopen without activation and establish membership before focusing, while verifying that the originating Desktop remains active. The existing verified native transaction supplies that operation. General Group focus and native Fill use HS2 AX APIs; no parallel native Group/window controller ships.

Release signing preserves the complete built bundle, signs its CLI and native helpers, and signs the outer app with the capabilities needed by HS2. The AppleScript XPC service remains bundled. Upstream and dependency licenses are included in app resources. `--self-test` requires an explicit private configuration directory and probes actual HS2 timers, processes, module loading, and defaults pause/resume against a nonmutating fixture.
