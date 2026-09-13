# Quick apps with Hammerspoon 2

Research date: September 13, 2026. Documentation and source review only; no live app, shortcut, or Dock assignment changes were made.

Follow-up: the feature is now implemented and Calculator has been tested live. See
the [quick-app setup and validation notes](../Prototypes/Hammerspoon2/README.md#quick-apps).
The rest of this document records the original research and proposal.

**Recommendation:** implement configurable quick apps in the existing HS2 runtime. Use macOS All Desktops assignment for availability on ordinary Desktops, center and focus the selected app window on demand, and hide the app on a second shortcut press. Fullscreen overlays and persistent always-on-top behavior require separate investigation.

## Feasibility and boundaries

The installed HS2 release's bundled `hammerspoon.d.ts` exposes global hotkeys, application launch/activation, `hide()`/`unhide()`, window focus/raise, `centerOnScreen()`, and writable window geometry. This is the API relevant to this project; classic Hammerspoon's Lua examples are not directly compatible with HS2.

Apple documents **Dock → Options → Assign To → All Desktops**, which makes an app available across Desktops. Hiding and unhiding an assigned app is a practical basis for the requested behavior. Assignment affects the application, and a shown app remains present across ordinary Desktops until hidden. It does not mean one window is moved exclusively onto the current Desktop. [Apple's Spaces guide](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac)

Classic Hammerspoon also exposes `hs.spaces.moveWindowToSpace`, but its Spaces module uses private APIs and Accessibility workarounds. It documents restrictions for fullscreen and Split View, and there are historical OS compatibility failures. Atelier currently disables window movement between Spaces. Do not make that route a prerequisite for this prototype. [Spaces API](https://www.hammerspoon.org/docs/hs.spaces.html), [Sequoia issue](https://github.com/Hammerspoon/hammerspoon/issues/3698)

Raising a window puts it in front at that moment. The reviewed window APIs do not provide a general foreign-app always-on-top setting. HS2's own floating canvas overlay does not confer that behavior on another app's window. Treat “floating” in this first experiment as a normal centered window excluded from tiling. [Classic window API](https://www.hammerspoon.org/docs/hs.window.html)

## Existing code and required changes

[Scratchpad](../Prototypes/NativeWindowTilingPOC/SCRATCHPAD.md) already implements one-app toggle, remembered window selection, whole-app hiding, focus restoration, native Center, and automatic All Desktops assignment with a Dock fallback. It is a reusable starting point, not an already integrated HS2 quick-app feature.

Implementation should:

1. Add a registry of bundle IDs, shortcuts, and optional preferred sizes to HS2, with one remembered target and previous focus per app.
2. Capture the current display and Desktop before activating the target. Use the focused window's display, with pointer fallback, consistent with existing Atelier shortcuts.
3. Establish and verify All Desktops assignment before ordinary summon operations. The current scratchpad activates before assignment, which can allow an initial unwanted Space switch; that ordering needs attention.
4. On summon, launch/unhide, resolve the designated window, place it on the captured display, center it, and verify focus and that the original Desktop remains active. Respect app minimum sizes; native Center alone does not establish a compact size.
5. Hide when the target is frontmost; otherwise raise/summon it. Restore previous focus only if the original window still exists on the current Desktop, avoiding a return to a different Space.
6. Exclude quick apps from Group membership and Fill-on-focus. `GroupStore.reconcile()` currently adds eligible windows automatically, and `atelier.js` fills focused members.

The existing scratchpad supports only one manager at a time, skips minimized/fullscreen target windows, and depends on native menu support for placement. A multi-app HS2 implementation needs explicit handling for closed/minimized windows and unavailable placement. Dock fallback assignment persists until changed back to None.

## 1Password and validation

1Password already offers **Quick Access**, opened by **Shift–Command–Space**, with a configurable shortcut in Settings → General. It searches items without opening the full main-window workflow. Test this as the native alternative; use the generic quick-app path if the full 1Password window is desired. Its exact fullscreen and dismissal behavior still needs local validation. [Quick Access](https://support.1password.com/quick-access/), [keyboard shortcuts](https://support.1password.com/keyboard-shortcuts/)

Start live validation with Calculator on two ordinary Desktops, then 1Password. Check repeated toggle, no Space switch, focus restoration, two-display placement, locked/closed/minimized states, rapid presses, and interaction with active Groups. Fullscreen and Split View remain outside the initial supported scope.
