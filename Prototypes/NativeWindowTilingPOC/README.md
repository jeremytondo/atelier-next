# Native window tiling proof of concept

This is a deliberately small ATE-13 experiment for exercising macOS's private
window-management and native tiling paths.

The framework and selectors are resolved at runtime so an OS update produces a readable capability failure instead of a loader crash.

See [FINDINGS.md](FINDINGS.md) for the evidence, conclusions, rejected
approaches, and remaining research questions.

## Run it

From this directory:

```sh
swift run native-window-tiling-poc left
```

Other commands include `right`, `fill`, `top`, `bottom`, `top-left`, `top-right`, `bottom-left`, `bottom-right`, `center`, and `untile`.

To check private API availability without opening a window:

```sh
swift run native-window-tiling-poc --probe
```

To open, tile, print the before/after WindowServer bounds, and exit automatically:

```sh
swift run native-window-tiling-poc left --smoke-test
```

To test the direct private `WindowManagement.framework` transaction across a
process boundary, without menu actions or Accessibility frame changes:

```sh
swift run native-window-tiling-poc left --cross-process-smoke-test
```

This launches a disposable fixture window in a second process, submits a native
transaction using its private WindowManagement identifier, reports its bounds,
and closes the fixture.

To send the standard system tiling shortcut directly to the fixture process,
without discovering or invoking a menu item:

```sh
swift run native-window-tiling-poc left --keyboard-cross-process-smoke-test
```

Synthetic input sent to another process requires Accessibility permission. To
ask macOS to open the permission UI, run once with:

```sh
swift run native-window-tiling-poc left --keyboard-cross-process-smoke-test --request-accessibility
```

Approve the responsible application in Privacy & Security > Accessibility and
rerun the first command. The test reports Accessibility and event-posting
authorization along with before/after WindowServer bounds.

To repeat the stronger control against a standard TextEdit document window:

```sh
swift run native-window-tiling-poc left --standard-app-keyboard-smoke-test
```

The local control case can also bypass the `NSWindow` tiling selector and call a
separately initialized private AppKit coordinator directly:

```sh
swift run native-window-tiling-poc left --coordinator-smoke-test --smoke-test
```

Tested against macOS 26.5.2 (build 25F84) on Apple silicon.
