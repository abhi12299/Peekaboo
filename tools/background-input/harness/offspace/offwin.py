# Window and dialog tools on the current Space (same) or from another Space (off).
# usage: python3 offwin.py <same|off> [away_space=3]  (home = the Space active when it starts; it switches back there)
# off: opens a scratch TextEdit window on the home Space, switches the screen to the away Space, runs the ops, switches back.
import sys, re, time, subprocess, os
D = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, D)
from mcp import MCP, PB
phase = sys.argv[1]; AWAY = int(sys.argv[2]) if len(sys.argv) > 2 else 3
HOME_SPACE = int(re.search(r'→ Space (\d+)', subprocess.run([PB, "space", "list"], env=dict(os.environ, PEEKABOO_NO_REMOTE="1"), capture_output=True, text=True).stdout).group(1))
if HOME_SPACE == AWAY: sys.exit(f"already on Space {AWAY}; pass a different away Space")
def sw(n): subprocess.run([PB, "space", "switch", "--to", str(n), "--foreground"], env=dict(os.environ, PEEKABOO_NO_REMOTE="1"), capture_output=True); time.sleep(2)
def front(): return subprocess.run(["lsappinfo", "info", "-only", "name", subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()], capture_output=True, text=True).stdout.split("\n")[0]
m = MCP(); res = []
def show(label, r, n=300):
    print(f"{label:28s} {'OK ' if r[0] else 'ERR'} {r[3]:5.1f}s {r[1][:n].replace(chr(10), ' | ')}", flush=True); res.append((label, r[0])); return r
def wins(): return m.call("window", {"action": "list", "app": "TextEdit"})[1]
def wid_for(title):
    mm = re.search(r'"' + re.escape(title) + r'" \[ID: (\d+)[^\]]*Bounds: ([^,]+), ([^ ]+) (\d+)×(\d+)', wins())
    return (int(mm.group(1)), mm.group(2, 3, 4, 5)) if mm else (None, None)
f = os.path.join(D, f"{phase}.txt"); open(f, "w").write("off-Space test\n")
print("front before:", front())
show("launch+open", m.call("app", {"action": "launch", "name": "TextEdit", "open": f, "waitForWindow": True}))
time.sleep(1); wid, b = wid_for(f"{phase}.txt"); print("wid", wid, "bounds", b)
if phase == "off": sw(AWAY); print(f"--- switched to Space {AWAY}; TextEdit window stays on Space {HOME_SPACE}")
W = lambda **a: m.call("window", dict(a, app="TextEdit", window_id=wid))
show("window move", W(action="move", x=200, y=120))
show("window resize", W(action="resize", width=640, height=420))
show("window set-bounds", W(action="set-bounds", x=240, y=140, width=600, height=400))
print("   bounds now", wid_for(f"{phase}.txt")[1])
show("window minimize", W(action="minimize"))
show("window restore", W(action="restore"))
r = show("see (right after restore)", m.call("see", {"app_target": "TextEdit", "window_id": wid}))
sid = re.search(r'ps1_[0-9a-f]+', r[1]).group(0) if r[0] else None
if sid:
    show("press cmd+n", m.call("press", {"keys": ["cmd+n"], "snapshot": sid})); time.sleep(1.5)
    uid, _ = wid_for("Untitled"); print("untitled wid", uid)
    if uid:
        r = show("see untitled", m.call("see", {"app_target": "TextEdit", "window_id": uid}), 120)
        s2 = re.search(r'ps1_[0-9a-f]+', r[1]).group(0); ta = re.search(r'(elem_\d+)[^|]*?(?:text area|AXTextArea|textarea)', r[1], re.I) or re.search(r'(elem_\d+)', r[1])
        show("type", m.call("type", {"snapshot": s2, "on": ta.group(1), "text": "scratch"}))
        r = show("see untitled 2", m.call("see", {"app_target": "TextEdit", "window_id": uid}), 80); s3 = re.search(r'ps1_[0-9a-f]+', r[1]).group(0)
        show("press cmd+s", m.call("press", {"keys": ["cmd+s"], "snapshot": s3})); time.sleep(1.5)
        show("dialog list (save sheet)", m.call("dialog", {"action": "list", "app": "TextEdit", "window_id": uid}), 200)
        show("dialog dismiss", m.call("dialog", {"action": "dismiss", "app": "TextEdit", "window_id": uid}))
        r = m.call("window", {"action": "close", "app": "TextEdit", "window_id": uid}); time.sleep(1.5)
        print(f"{'window close untitled':28s} (expect sheet message) {r[1][:300]}"); res.append(("close untitled names the sheet", "sheet" in r[1].lower()))
        show("dialog click Delete", m.call("dialog", {"action": "click", "app": "TextEdit", "window_id": uid, "button": "Delete"}))
show("window close file", W(action="close"))
time.sleep(1); print("   TextEdit windows left:", re.findall(r'"([^"]+)" \[ID', wins()))
print("front after:", front())
if phase == "off": sw(HOME_SPACE); print(f"--- back on Space {HOME_SPACE}")
m.call("app", {"action": "quit", "name": "TextEdit"})
m.close(); print("SUMMARY", phase, sum(bool(ok) for _, ok in res), "/", len(res), "ok; failed:", [l for l, ok in res if not ok])
