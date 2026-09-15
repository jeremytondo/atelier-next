// Accessibility setup dialog and System Settings navigation. Startup owns the
// dialog and closes it when access is granted or the session stops.
import type {HS} from "../api/hs.ts";

export class Startup {
  private readonly hs: HS;
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
