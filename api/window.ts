// `atelier.window` invokes the native window actions of the frontmost app's
// Window menu through `hs.ax`: Fill, Center, the halves, corners, and
// arrangements macOS itself offers. Items are found by the identifiers AppKit
// gives them (`_zoomFill:`), which do not change with the interface language,
// and pressed as menu items so macOS chooses participants and layout. Nothing
// here computes a frame or synthesizes a keystroke.
//
// Shortcut metadata comes from the item's `AXMenuItemCmd*` attributes. The
// modifier mask is public for Command, Shift, Option, Control, and "no
// Command"; bit 16 is Fn, verified against macOS 27's own Fn-Control
// shortcuts. Any other bit makes the shortcut unreadable and it is omitted.
import type {HS} from "./hs.ts";

export const nativeActionNames = [
  "fill",
  "center",
  "left",
  "right",
  "top",
  "bottom",
  "top-left",
  "top-right",
  "bottom-left",
  "bottom-right",
  "left-right",
  "right-left",
  "top-bottom",
  "bottom-top",
  "left-quarters",
  "right-quarters",
  "top-quarters",
  "bottom-quarters",
  "quarters",
] as const;

export type NativeActionName = (typeof nativeActionNames)[number];

/** Apple's label and the AppKit action identifier of each native action. */
export const nativeActions: Record<NativeActionName, {label: string; identifier: string}> = {
  fill: {label: "Fill", identifier: "_zoomFill:"},
  center: {label: "Center", identifier: "_zoomCenter:"},
  left: {label: "Left", identifier: "_zoomLeft:"},
  right: {label: "Right", identifier: "_zoomRight:"},
  top: {label: "Top", identifier: "_zoomTop:"},
  bottom: {label: "Bottom", identifier: "_zoomBottom:"},
  "top-left": {label: "Top Left", identifier: "_zoomTopLeft:"},
  "top-right": {label: "Top Right", identifier: "_zoomTopRight:"},
  "bottom-left": {label: "Bottom Left", identifier: "_zoomBottomLeft:"},
  "bottom-right": {label: "Bottom Right", identifier: "_zoomBottomRight:"},
  "left-right": {label: "Left & Right", identifier: "_zoomLeftAndRight:"},
  "right-left": {label: "Right & Left", identifier: "_zoomRightAndLeft:"},
  "top-bottom": {label: "Top & Bottom", identifier: "_zoomTopAndBottom:"},
  "bottom-top": {label: "Bottom & Top", identifier: "_zoomBottomAndTop:"},
  "left-quarters": {label: "Left & Quarters", identifier: "_zoomLeftThreeUp:"},
  "right-quarters": {label: "Right & Quarters", identifier: "_zoomRightThreeUp:"},
  "top-quarters": {label: "Top & Quarters", identifier: "_zoomTopThreeUp:"},
  "bottom-quarters": {label: "Bottom & Quarters", identifier: "_zoomBottomThreeUp:"},
  quarters: {label: "Quarters", identifier: "_zoomQuarters:"},
};

/** A menu shortcut as HS2 modifier names and a key name. */
export interface NativeShortcut {
  mods: string[];
  key: string;
}

export interface NativeAction {
  name: NativeActionName;
  label: string;
  /** Whether the frontmost app's Window menu lists the action. */
  present: boolean;
  /** Whether macOS enables it for the focused window right now. */
  enabled: boolean;
  /** The menu's own shortcut when its metadata is readable. */
  shortcut: NativeShortcut | null;
}

/** The frontmost app's native actions at one moment. */
export interface WindowMenu {
  /** The frontmost app's name, or null without one. */
  app: string | null;
  pid: number;
  /** The focused window's ID, 0 without one. */
  window: number;
  actions: Record<NativeActionName, NativeAction>;
}

export interface WindowAPI {
  /** Reads the Window menu of the frontmost app; costs a few Accessibility round trips. */
  actions(): WindowMenu;
  /** Presses the action's menu item after confirming the focused window is unchanged. */
  perform(name: NativeActionName): {window: number};
}

const identifiers = new Map(
  nativeActionNames.map((name) => [nativeActions[name].identifier, name] as const),
);
const arrowKeys: Record<number, string> = {123: "left", 124: "right", 125: "down", 126: "up"};
/** How deep the Window menu is walked; the actions sit at most one submenu down. */
const menuDepth = 3;

interface Scan {
  app: string | null;
  pid: number;
  window: number;
  items: Map<NativeActionName, HSAXElement>;
}

function readShortcut(item: HSAXElement): NativeShortcut | null {
  const mask: unknown = item.attributeValue("AXMenuItemCmdModifiers");
  if (typeof mask !== "number" || !Number.isInteger(mask) || mask < 0 || mask > 31) return null;
  const char: unknown = item.attributeValue("AXMenuItemCmdChar"),
    virtualKey: unknown = item.attributeValue("AXMenuItemCmdVirtualKey");
  const key =
    typeof char === "string" && /^[!-~]$/.test(char)
      ? char.toLowerCase()
      : typeof virtualKey === "number"
        ? arrowKeys[virtualKey]
        : undefined;
  if (!key) return null;
  const mods: string[] = [];
  if (mask & 16) mods.push("fn");
  if (mask & 4) mods.push("ctrl");
  if (mask & 2) mods.push("alt");
  if (mask & 1) mods.push("shift");
  if (!(mask & 8)) mods.push("cmd");
  return {mods, key};
}

/** Collects the native items under a menu; separators and unrelated items are skipped. */
function collect(menu: HSAXElement, depth: number, items: Scan["items"]): void {
  for (const item of menu.children()) {
    const identifier: unknown = item.attributeValue("AXIdentifier"),
      name = typeof identifier === "string" ? identifiers.get(identifier) : undefined;
    if (name) {
      if (!items.has(name)) items.set(name, item);
      continue;
    }
    if (depth <= 1 || identifier || !item.title) continue;
    const submenu = item.children()[0];
    if (submenu) collect(submenu, depth - 1, items);
  }
}

function scan(hs: HS): Scan {
  const app = hs.application.frontmost(),
    focused = hs.window.focusedWindow();
  const result: Scan = {
    app: app?.title ?? null,
    pid: app?.pid ?? 0,
    window: focused?.id ?? 0,
    items: new Map(),
  };
  if (!app) return result;
  const element = hs.ax.applicationElement(app);
  const bar: unknown = element?.attributeValue("AXMenuBar");
  if (!bar || typeof bar !== "object") return result;
  // The Window menu is whichever top-level menu lists Fill; the English title
  // is only a shortcut to trying it first.
  const menus = (bar as HSAXElement).children(),
    ordered = [
      ...menus.filter((m) => m.title === "Window"),
      ...menus.filter((m) => m.title !== "Window"),
    ];
  for (const menu of ordered) {
    const list = menu.children()[0];
    if (!list) continue;
    collect(list, menuDepth, result.items);
    if (result.items.size) break;
  }
  return result;
}

export function createWindow(hs: HS): WindowAPI {
  return {
    actions() {
      const found = scan(hs);
      const actions = {} as Record<NativeActionName, NativeAction>;
      for (const name of nativeActionNames) {
        const item = found.items.get(name);
        actions[name] = {
          name,
          label: nativeActions[name].label,
          present: !!item,
          enabled: item?.isEnabled ?? false,
          shortcut: item ? readShortcut(item) : null,
        };
      }
      return {app: found.app, pid: found.pid, window: found.window, actions};
    },
    perform(name) {
      const label = nativeActions[name]?.label;
      if (!label) throw new Error("Unknown window action: " + String(name));
      const found = scan(hs),
        item = found.items.get(name);
      if (!found.app) throw new Error("No application is frontmost");
      if (!item) throw new Error(label + " is not in the Window menu of " + found.app);
      if (!item.isEnabled) throw new Error(label + " is unavailable for the focused window");
      // The menu was read for one window of the frontmost app; no other window
      // may receive its action, and no window at all is not a target.
      const focused = hs.window.focusedWindow();
      if (found.window <= 0 || !focused || focused.pid !== found.pid)
        throw new Error("No focused window in " + found.app + "; " + label + " was not applied");
      if (focused.id !== found.window)
        throw new Error("The focused window changed; " + label + " was not applied");
      if (!item.performAction("AXPress")) throw new Error(found.app + " refused " + label);
      return {window: found.window};
    },
  };
}
