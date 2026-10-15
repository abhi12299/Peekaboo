# Real-app check for background Cmd+W (TextEdit document) and Cmd+Q (fresh Calculator) through the fork's MCP server.
# Usage: python3 hotkeys.py   (prints each step; the front app must be unchanged at the end)
import os, re, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "offspace"))
from mcp import MCP

def front():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    return subprocess.run(["lsappinfo", "info", "-only", "name", asn], capture_output=True, text=True).stdout.strip().splitlines()[0]

def running(name): return subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0
def show(label, r): print(f"{label}: ok={r[0]} {r[3]:.1f}s :: {r[1][:220]}")
def snapshot(r): return r[1].split("Snapshot ID: ")[1].split()[0]

doc = os.path.join(tempfile.gettempdir(), "peekaboo-cmdw-test.txt")
open(doc, "w").write("step 22 check\n")
m = MCP(); f0 = front(); print("front before:", f0)

r = m.call("app", {"action": "launch", "name": "TextEdit", "open": doc, "waitForWindow": True}); show("launch TextEdit", r)
wid = int(re.search(r"Window (\d+) ", r[1]).group(1))
r = m.call("see", {"app_target": "TextEdit", "window_id": wid}); show("see TextEdit", r)
r = m.call("press", {"snapshot": snapshot(r), "keys": ["cmd+w"]}); show("press cmd+w", r)
time.sleep(1); print("document window still listed:", "peekaboo-cmdw-test" in m.call("window", {"action": "list", "app": "TextEdit"})[1])

if running("Calculator"): m.call("app", {"action": "quit", "name": "Calculator"}); time.sleep(1)
r = m.call("app", {"action": "launch", "name": "Calculator", "waitForWindow": True}); show("launch Calculator", r)
r = m.call("see", {"app_target": "Calculator"}); show("see Calculator", r)
r = m.call("press", {"snapshot": snapshot(r), "keys": ["cmd+q"]}); show("press cmd+q", r)
time.sleep(1.5); print("Calculator running after cmd+q:", running("Calculator"))

print("front after:", front(), "| unchanged:", front() == f0)
m.call("app", {"action": "quit", "name": "TextEdit"}); m.close(); os.remove(doc)
