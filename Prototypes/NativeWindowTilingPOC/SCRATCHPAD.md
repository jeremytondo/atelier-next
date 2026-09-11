# Scratchpad prototype (ATE-16)

This prototype turns one existing macOS application into a simple scratchpad. A
configurable global shortcut launches or raises the application, assigns it to
All Desktops, places its selected window with a native macOS Window menu action,
and hides the application on the next press. After hiding, it restores the
previously focused application and window when they are still available. The
manager's state is session-only; its Dock assignment fallback is persistent.

## Set up and run

Build from the repository root:

```sh
swift build --package-path Prototypes/NativeWindowTilingPOC
```

Start a scratchpad by app name, bundle identifier, or application path:

```sh
./scratchpad --app Calculator --placement right
./scratchpad --app com.apple.Terminal --placement top-left --shortcut ctrl-option-t
```

The default shortcut is `Control-Option-Command-S`. It avoids macOS's standard
`Command-Option-Space` Finder search binding while remaining easy to associate
with “scratchpad.” The default placement is `fill`. Available placements are
`left`, `right`, `top`, `bottom`, `top-left`, `top-right`, `bottom-left`,
`bottom-right`, `fill`, and `center`. Supported shortcut keys are letters,
digits, Space, Return, Tab, and common ANSI punctuation names shown by
`./scratchpad --help`.

All Desktops assignment is automatic. The prototype first asks the live
WindowServer session to assign the target process, then verifies the selected
window appears on multiple Spaces. If that private runtime operation is missing
or ineffective, it opens the target's native Dock menu through Accessibility,
chooses **Options → Assign To → All Desktops**, and verifies again. The fallback
uses Dock's localized menu resources and persists in the same way as a manual
selection. Its menu may appear briefly.

To compare against a manual Dock assignment or isolate assignment problems, add
`--manual-space-assignment`. This disables both automatic routes while retaining
show, hide, placement, and focus restoration.

Before granting Accessibility access, validate app discovery and argument
parsing without launching anything:

```sh
./scratchpad --app Calculator --placement right --probe
```

Running the manager requires Accessibility permission for the responsible
launcher, such as Ghostty. Ask macOS to show the prompt once with:

```sh
./scratchpad --app Calculator --placement right --request-accessibility
```

Approve that launcher in System Settings → Privacy & Security → Accessibility,
then rerun the normal command. Keep its terminal open and use Control-C to stop.
Only one Scratchpad prototype can run at a time. `--probe` also reports whether
the private assignment and membership-verification symbols are available on the
current macOS build.

## Toggle behavior

When the shortcut is pressed:

1. If the target is not frontmost, remember the current app and exact focused
   window, launch or unhide the target, focus a standard window, ensure its All
   Desktops membership, and invoke the configured native placement.
2. If the target is already frontmost, hide the entire target application and
   return focus to the remembered window when it still exists.
3. If native placement is unavailable for the selected window, leave the app
   visible and report the failure. No Accessibility frame fallback is used.

The chosen target window is remembered during the session. If it closes, the
prototype selects the focused standard window or the first standard window the
app exposes. Dialogs, sheets, minimized windows, and fullscreen windows are not
selected.

## Boundaries to evaluate

- Hiding applies to the whole application, so this first version is best with a
  dedicated single-window app or a terminal app used only for the scratchpad.
- “All Desktops” means the app participates in every ordinary Desktop while it
  is shown. It is the most native approximation of summoning an existing app in
  the current Desktop, but it differs from moving one designated window between
  Spaces.
- The primary assignment function and membership query are undocumented
  SkyLight interfaces resolved at runtime. The Dock fallback uses public
  Accessibility actions against an undocumented system-app hierarchy. Either
  route can change in a macOS update, so failure is reported explicitly.
- The Dock fallback changes the persistent app assignment. Disable automatic
  assignment and choose **Dock → Options → Assign To → None** to remove it.
- Some apps do not expose Apple's semantic Window menu identifiers or do not
  enable every placement. Those apps still show, but placement reports as
  unavailable.
- The prototype reapplies placement every time it is shown. That gives a stable
  default position even after manual movement.
- Fullscreen and Split View Spaces are outside this first slice.

Suggested manual validation: try Calculator on two ordinary Desktops, then try
a terminal app with one window. Verify first launch, repeated hide/show, focus
restoration, placement after manual resizing, and behavior after closing the
remembered target or previous window.
