#!/usr/bin/env python3
"""Send a fixed JSON command to the loaded HS2 prototype and await its result."""
import fcntl
import json
from pathlib import Path
import sys
import time
import uuid

root = Path(__file__).resolve().parent / ".runtime"
if not root.is_dir():
    raise SystemExit("Run setup.py install and reload Hammerspoon 2 first")
request = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {"command": "probe"}
request["id"] = str(uuid.uuid4())
with (root / "client.lock").open("w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    temp = root / "request.tmp"
    temp.write_text(json.dumps(request))
    temp.replace(root / "request.json")
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        try:
            response = json.loads((root / "response.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            response = {}
        if response.get("id") == request["id"]:
            print(json.dumps(response, indent=2))
            raise SystemExit(0 if response.get("ok") else 1)
        time.sleep(0.1)
raise SystemExit("No response. Reload HS2 and check its Console. Do not blindly retry a mutation.")
