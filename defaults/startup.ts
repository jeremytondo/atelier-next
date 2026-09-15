// Persistent startup feedback uses HS2 UI, independent of notification permission.
// The status item survives stop so users can resume; HS2 destroys it on reload.
import type {HS} from "../api/hs.ts";

export class Startup {
  private readonly hs: HS;
  private menu: HSMenuBarItem | null = null;
  private dialog: HSUIDialog | null = null;
  private prompted = false;

  constructor(hs: HS) {
    this.hs = hs;
  }

  settings(): void {
    // Use the same pane URL as upstream's PermissionsManager, with a general
    // Settings fallback if macOS refuses the deep link.
    const hs = this.hs;
    if (!hs.permissions.checkAccessibility()) {
      try {
        hs.permissions.requestAccessibility();
      } catch (error) {
        console.error("Atelier: Could not request Accessibility: " + String(error));
      }
    }
    if (
      !hs.urlevent.openURL(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
      ) &&
      !hs.urlevent.openURL("x-apple.systempreferences:com.apple.preference.security")
    ) {
      hs.openConsole();
      console.error(
        "Atelier: Open System Settings > Privacy & Security and enable Hammerspoon 2 under Accessibility / Device Control and Data Access.",
      );
    }
  }

  update(state: string, error: string | null, retry: () => void): void {
    this.menu ??= this.hs.menubar.create();
    const menu = this.menu;
    menu.title = state === "Running" ? "Atelier" : "Atelier: " + state;
    menu.setTooltip(error ?? "Atelier: " + state);
    menu.setMenu([
      {title: state, disabled: true},
      ...(error ? [{title: error, disabled: true}] : []),
      {title: "-"},
      {title: "Open Accessibility Settings…", fn: () => this.settings()},
      {title: "Reload Config", fn: () => this.hs.reload()},
      {
        title: "Retry Startup",
        disabled:
          state === "Running" || state === "Starting" || state === "Waiting for Accessibility",
        fn: retry,
      },
      {title: "Open Console", fn: () => this.hs.openConsole()},
    ]);
    if (state !== "Waiting for Accessibility") this.close();
  }

  permission(): void {
    if (this.prompted) return;
    this.prompted = true;
    this.dialog = this.hs.ui
      .dialog("Atelier needs Accessibility access")
      .informativeText(
        "Enable Hammerspoon 2 in System Settings > Privacy & Security > Accessibility (Device Control and Data Access on macOS 27). Atelier will start automatically when access is available. If it is already enabled but Atelier is still waiting, quit and reopen Hammerspoon 2.",
      )
      .buttons(["Open Settings", "Later"])
      .onButton((index) => {
        if (index === 0) {
          this.settings();
        }
      })
      .show();
  }

  close(): void {
    this.dialog?.close();
    this.dialog = null;
  }
}
