"use strict";

const aliases = {command:"cmd", cmd:"cmd", option:"alt", opt:"alt", alt:"alt",
  control:"ctrl", ctrl:"ctrl", shift:"shift", "⌘":"cmd", "⌥":"alt", "⌃":"ctrl", "⇧":"shift"};
const keyAliases = {grave:"`", minus:"-", equal:"=", comma:",", period:".", slash:"/",
  semicolon:";", quote:"'", backslash:"\\", "left-bracket":"[", "right-bracket":"]", enter:"return", esc:"escape"};
function shortcutIdentity(mods, key) {
  return mods.map(m => aliases[m.toLowerCase()] || m).sort().join("+") + ":" + (keyAliases[key] || key).toLowerCase();
}
function parseShortcut(value) {
  if (typeof value !== "string") throw new Error("Quick app shortcut must be a string");
  const parts = value.toLowerCase().split("-");
  const mods = [];
  while (parts.length > 1 && aliases[parts[0]]) mods.push(aliases[parts.shift()]);
  const key = keyAliases[parts.join("-")] || parts.join("-");
  if (!mods.length || new Set(mods).size !== mods.length ||
    !/^([a-z0-9`\-=,./;'\\\[\]]|space|return|tab|escape|delete|forwarddelete|left|right|up|down|home|end|pageup|pagedown|f([1-9]|1[0-9]|20))$/.test(key)) {
    throw new Error("Invalid quick app shortcut: " + value);
  }
  return {mods, key, identity:shortcutIdentity(mods, key)};
}
function normalizeQuickApps(entries = []) {
  if (!Array.isArray(entries)) throw new Error("quickApps must be an array");
  const used = new Set();
  return entries.map(entry => {
    if (!entry || typeof entry.app !== "string" || !entry.app.trim()) throw new Error("Each quick app needs an app name or bundle ID");
    for (const key of Object.keys(entry)) if (!["app","shortcut","size"].includes(key)) throw new Error("Unknown quick app option: " + key);
    const shortcut = parseShortcut(entry.shortcut);
    if (used.has(shortcut.identity)) throw new Error("Duplicate quick app shortcut: " + entry.shortcut);
    used.add(shortcut.identity);
    let size;
    if (entry.size !== undefined) {
      const s = entry.size;
      if (!s || ![s.width, s.height].every(v => typeof v === "number" && Number.isFinite(v) && v > 0) ||
        Object.keys(s).some(k => !["width","height"].includes(k))) throw new Error("Quick app size needs positive width and height: " + entry.app);
      size = {width:s.width, height:s.height};
    }
    return {app:entry.app.trim(), shortcut:entry.shortcut, ...shortcut, ...(size ? {size} : {})};
  });
}

class QuickApps {
  constructor(entries) { this.entries = normalizeQuickApps(entries); this.bundleIDs = new Set(); }
  async resolve(request) {
    const resolved = [], seen = new Set();
    for (const entry of this.entries) {
      const app = await request("quickResolve", {app:entry.app});
      if (seen.has(app.bundleID)) throw new Error("App configured more than once: " + entry.app);
      seen.add(app.bundleID); resolved.push({...entry, ...app});
    }
    this.entries = resolved; this.bundleIDs = seen;
  }
  bind(hotkey, bind, toggle) {
    for (const entry of this.entries) {
      const occupied = hotkey.getHotkeys().some(k => shortcutIdentity(k.mods, k.key) === entry.identity);
      if (occupied || !hotkey.assignable(entry.mods, entry.key)) throw new Error("Quick app shortcut unavailable: " + entry.shortcut);
      bind(entry.mods, entry.key, () => toggle(entry.bundleID));
    }
  }
  toggle(app, request) {
    const entry = this.entries.find(e => e.bundleID === app || e.app === app);
    if (!entry) throw new Error("Quick app is not configured: " + app);
    return request("quickToggle", {app:entry.bundleID, ...(entry.size ? {size:entry.size} : {})});
  }
  status() { return this.entries.map(({app, bundleID, shortcut, size}) => ({app, bundleID, shortcut, ...(size ? {size} : {})})); }
}
module.exports = {QuickApps, normalizeQuickApps, parseShortcut, shortcutIdentity};
