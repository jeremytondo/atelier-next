# Space Control proof of concept (ATE-15)

This long-running prototype adds session-only convenience shortcuts around
native macOS Desktops. It does not write `AppleSymbolicHotKeys`, edit System
Settings, inject code into Dock, or require reduced System Integrity Protection.

## Build and run

From the repository root:

```sh
swift build --package-path Prototypes/NativeWindowTilingPOC
./space-control --probe
./space-control --request-accessibility
./space-control
```

The first command only reads the current WindowServer topology and resolves the
required private symbols. The second asks macOS to show the Accessibility
permission prompt. Approve the responsible launcher (for example, Ghostty),
then run the final command. Keep its terminal open and use Control-C to stop it.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `Option-1` … `Option-9` | Switch to ordinary Desktop 1–9 on the target display |
| `Option-0` | Switch to ordinary Desktop 10 |
| ``Option-` `` | Create one native Desktop and leave Mission Control open |
| `Control-Up` | Open Mission Control using the native macOS shortcut; keyboard Space controls activate automatically |
| `Left` / `Right` or `h` / `l` | While Mission Control is open, activate the previous/next ordinary Desktop |
| `1` … `9` / `0` | While Mission Control is open, activate ordinary Desktop 1–10 directly |
| `Return` / keypad `Enter` | Enter the active Desktop and close Mission Control |
| `Command-Left` / `Command-Right` | While Mission Control is open, reorder the active Desktop |
| `Delete` | While Mission Control is open, delete the active Desktop after moving to its neighbor |

The target display is the display containing the focused window, falling back
to the display under the pointer. Numbering is recomputed on every command from
the current left-to-right order and excludes full-screen app Spaces in this POC.
A number that does not exist is a logged no-op.

If any Option shortcut is already registered by another application, startup
fails and releases every shortcut it registered. Commands are serialized so a
second key press cannot interfere while Mission Control is animating or changing
a Desktop.

## Native behavior and private boundaries

Numbered switching invokes macOS's own `Switch to Desktop N` symbolic action.
When that action is disabled in System Settings, the prototype temporarily
enables it in the live WindowServer, posts its configured key event, and restores
the disabled state after 250 milliseconds. It never persists the change.

Desktop creation has no public API. The prototype opens Mission Control using
its native symbolic action, finds Dock's semantic Accessibility elements
(`mc.display`, `mc.spaces.add`, and `mc.spaces.list`), and lets Mission Control's
entrance finish before pressing Add Desktop. After observing one new ordinary
Space, it verifies the corresponding expanded thumbnail has stabilized and
activates it using the same native direct-switch route as numeric navigation.
Mission Control remains open with the new Desktop carrying the native active
indicator.

The Mission Control presentation is deliberate: it gives the user context for
the new Desktop appearing rather than trying to hide the mechanism. While
Mission Control is open, `Option-N` presses that Desktop's native thumbnail,
verifies it became current, and ensures the overview closes. When Mission
Control is closed, `Option-N` continues using the direct native symbolic action
and never opens the overview. Every wait is bounded, and a missing, changing, or
ambiguous element fails closed.

The prototype does not intercept or replace macOS's Mission Control shortcut.
Whenever Dock exposes Mission Control—whether opened with the default
`Control-Up`, a configured replacement, a trackpad gesture, or the prototype's
create command—the unmodified arrows, `h`/`l`, digits, Return, Command-arrows,
and Delete are registered. Outside the overview they are immediately released
and retain their normal application behavior. A newly opened overview
initializes the selection to the current Desktop; creation activates the
Desktop just added.
The prototype waits for Mission Control's entrance to finish, moves the pointer
to the active display's top edge, and does not enable navigation until the
expanded thumbnail frame has stabilized. It then keeps the pointer off the
thumbnails so delayed Delete buttons do not masquerade as selection. When
Mission Control closes, it restores the pointer's original position unless the
user moved the pointer manually.

Left/Right and `h`/`l` invoke macOS's native previous/next-Space symbolic actions
and verify that the intended ordinary Desktop became active without closing
Mission Control. If a full-screen app Space lies between two ordinary Desktops,
the prototype traverses it on the way but stops on the next ordinary Desktop.
The native active-Space indicator is therefore the only selection indicator.
Plain number keys invoke the corresponding native `Switch to Desktop N` action
once, verify that the requested ordinary Desktop became active, and keep the
expanded overview open. `0` addresses Desktop 10. The Option-number variants
retain their separate select-and-close behavior.
Return presses the active Desktop's native thumbnail, verifies the active Space
did not change, and waits for Mission Control to close.

Because macOS cannot remove the active Desktop, Delete first activates its
nearest ordinary neighbor while keeping Mission Control open, then invokes the
former Desktop thumbnail's semantic `AXRemoveDesktop` action. It still refuses
to remove the final ordinary Desktop. Reorder synthesizes a native mouse drag
between the active thumbnail and its neighbor, then verifies the new ordering.
Both operations currently exclude full-screen app Spaces as direct targets.

`SLSCopyManagedDisplaySpaces` and the symbolic-hotkey functions are undocumented.
The Dock Accessibility identifiers are also undocumented. macOS updates can
break either path, and these APIs are not appropriate for a Mac App Store build
without a different product strategy. The POC was built for manual testing on
macOS 26.5.2 (build 25F84).

## Suggested manual checks

1. Start with two ordinary Desktops. Verify `Option-1` and `Option-2` preserve
   the native switching animation, and `Option-3` logs a no-op.
2. Press ``Option-` ``. Verify Mission Control opens clearly, one Desktop is
   appended, becomes active, and Mission Control stays open. Press Return and
   verify the overview closes into that new Desktop.
3. Close Mission Control, then reopen it with the native `Control-Up` shortcut
   without creating a Desktop. Verify the collapsed Spaces bar expands to show
   thumbnails and the current Desktop has macOS's native active indicator. Press
   Left/Right and `h`/`l`, and verify the active Space and its indicator move
   while Mission Control remains open. Press `1`, `2`, and another existing Desktop
   number and verify each activates directly without collapsing the overview.
   Use Command-Left or Command-Right and verify the active Desktop moves exactly
   one position. Press Return and verify Mission Control closes into the active
   Desktop. Reopen it, close Mission Control normally, and verify the pointer
   returns to its prior location; repeat after manually moving it and verify the
   prototype leaves it alone.
4. Press Delete and verify the nearest Desktop becomes active before the former
   active Desktop disappears. Verify deleting the final Desktop is rejected.
5. Verify the number shortcuts follow the new order without restarting the
   prototype.
6. With two displays, focus a window on each display and repeat the checks.
   Close/minimize the focused window and verify the pointer display fallback.
7. Add a full-screen app Space and verify it does not consume a Desktop number.
8. Stop the process, verify the shortcuts are released, and verify the
   Mission Control shortcuts in System Settings retain their prior state.

For long-running testing, follow the same safety procedure documented for the
ATE-14 prototype: launch interactively, stop with Control-C, and verify the
process exited rather than leaving a timed runner behind.
