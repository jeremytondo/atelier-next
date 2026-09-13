#!/usr/bin/env python3
"""Add/remove the prototype loader without replacing the user's HS2 config."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["install", "uninstall"])
args = parser.parse_args()
root = Path(__file__).resolve().parent
config = Path.home() / ".config/hammerspoon2/init.js"
begin = "// BEGIN ATELIER HS2 PROTOTYPE"
end = "// END ATELIER HS2 PROTOTYPE"
config.parent.mkdir(parents=True, exist_ok=True)
original = config.read_text() if config.exists() else ""
text = original
if begin in text:
    start = text.index(begin)
    finish = text.index(end, start) + len(end)
    text = text[:start] + text[finish:]
if args.action == "install":
    runtime = root / ".runtime"
    runtime.mkdir(mode=0o700, exist_ok=True)
    helper = root.parent / "NativeWindowTilingPOC/.build/debug/space-control-prototype"
    if not helper.is_file():
        raise SystemExit("Build the native package before installing the loader")
    backup = config.with_name("init.js.before-atelier")
    if not backup.exists():
        backup.write_text(original)
    quickapps = config.parent / "quickapps.js"
    if not quickapps.exists():
        quickapps.write_text((root / "quickapps.example.js").read_text())
    text = text.rstrip() + "\n\n" + begin + "\n" + "\n".join([
        f"globalThis.atelier = require({json.dumps(str(root / 'atelier.js'))})({{",
        f"  helper: {json.dumps(str(helper))},",
        '  fill: "native-js",',
        f"  quickApps: require({json.dumps(str(quickapps))})",
        "});",
        "atelier.start().catch(error => console.error(String(error)));",
        f"globalThis.atelierControl = require({json.dumps(str(root / 'control.js'))})(atelier, {json.dumps(str(runtime))});",
    ]) + "\n" + end + "\n"
config.write_text(text)
print(f"{args.action}: {config}; reload Hammerspoon 2 to apply")
