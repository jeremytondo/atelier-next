# Explicit TOML configuration validation — 2026-09-13

Installed build: `0.1.0 (202609131443)` on Apple silicon, macOS 26.5.2. Same local development signing identity as the earlier alpha. Accessibility remained granted after replacement.

## Automated checks

37 tests passed, covering the existing engine/lifecycle rules plus TOML parsing, unknown keys and types, shortcut conflicts, include precedence and cycles (including symlinks), source diagnostics, stable named Quick Apps, XDG path selection, migration, preservation of source files, and transactional shortcut registration. The last template-only adjustment was followed by 17 passing configuration-filtered tests.

Full test log: `~/Library/Developer/XcodeBuildMCP/workspaces/atelier-next-a3ecb2c13493/logs/swift_package_test_2026-09-13T19-41-28-259Z_pid60247_3e20f0a9.log`.

Configuration test log: `~/Library/Developer/XcodeBuildMCP/workspaces/atelier-next-a3ecb2c13493/logs/swift_package_test_2026-09-13T19-42-59-359Z_pid61065_2649378b.log`.

Release build log: `~/Library/Developer/XcodeBuildMCP/workspaces/atelier-next-a3ecb2c13493/logs/build_spm_2026-09-13T19-43-10-917Z_pid61201_9ddbd687.log`.

## Installed-app checks

- Migrated the earlier JSON into `~/.config/atelier/config.toml`, retaining Calculator's Command–Shift–C shortcut. The original JSON and both Hammerspoon source files matched their pre-update SHA-256 hashes.
- Wrote configuration using an atomic file replacement and waited: running values did not change.
- Used the default global reload shortcut to change its own binding to Control–Option–Command–F18 and disable the overlay. The engine PID remained unchanged.
- Used the new shortcut to attempt invalid TOML, a missing application, and a duplicate shortcut. Each attempt retained the previous configuration and working reload binding. Syntax diagnostics included the file and line; value/runtime diagnostics identified the setting.
- Split Calculator into an included file, explicitly reloaded, and verified both files were loaded and prior configuration errors cleared.
- Reloaded while paused and verified the app stayed paused. Disabled the reload keybinding, then used the actual menu-bar Reload Configuration item through Accessibility automation to restore it.
- Built a disposable fixture with three windows on a temporary Desktop. A configuration reload preserved their process/window identities and ordering, kept the helper PID unchanged, and allowed subsequent Group cycling. Geometry was intentionally excluded from the identity comparison because native Fill updates it asynchronously.
- Used Calculator's actual registered shortcut to summon it, reloaded configuration while it was visible, then used the same shortcut to hide it. The active Desktop stayed unchanged, Calculator remained excluded from the Group, and focus returned to a fixture member.
- Restored the original Desktop IDs `[3, 14]`, order, and active Desktop `3`; removed all test windows, fixture bundles, and temporary includes; restored the migrated config contents.
- The installed executable's read-only `--validate-config` command accepted the migrated file. Nested helper and outer app code signatures verified successfully.

Structured Group-check results: [configuration-live-2026-09-13.json](configuration-live-2026-09-13.json).

## Observations and limits

The low-level CGEvent test helper did not trigger the initial shortcut check; System Events keyboard automation successfully exercised the registered shortcuts. Physical keyboard use remains part of daily testing.

Calculator's old running process initially failed All Desktops membership validation, then exposed zero standard windows even when opened normally. Quitting and reopening Calculator restored its window; subsequent summon/hide and focus-restoration checks passed. No Quick App engine changes were made to mask this condition.

Actual login launch, permission revocation, sleep/wake, multiple displays, and non-US layouts were not re-tested in this configuration update. Launch-at-login registration/approval remains owned by macOS. Invalid config on a fresh launch requires fixing the file, reloading, and resuming; last-good configuration is retained in memory during a running session, not silently loaded from the old JSON after a restart.
