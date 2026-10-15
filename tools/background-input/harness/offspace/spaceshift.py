# Step 23 check: a snapshot taken while the window was visible is used after the screen moved to another Space.
# usage: python3 spaceshift.py [away_space=3]   (switches back to the starting Space at the end)
# Expect: keyboard and accessibility-action steps are not refused as "moved or resized"; a coordinate click still is.
import os, re, subprocess, sys, time
D = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, D)
from mcp import MCP, PB
AWAY = int(sys.argv[1]) if len(sys.argv) > 1 else 3
ENV = dict(os.environ, PEEKABOO_NO_REMOTE="1")
HOME_SPACE = int(re.search(r'→ Space (\d+)', subprocess.run([PB, "space", "list"], env=ENV, capture_output=True, text=True).stdout).group(1))
if HOME_SPACE == AWAY: sys.exit(f"already on Space {AWAY}; pass a different away Space")
def sw(n): subprocess.run([PB, "space", "switch", "--to", str(n), "--foreground"], env=ENV, capture_output=True); time.sleep(5)
def show(label, r, n=320): print(f"{label:30s} {'OK ' if r[0] else 'ERR'} {r[3]:5.1f}s {r[1][:n].replace(chr(10), ' | ')}", flush=True); return r
snap = lambda r: re.search(r'ps1_[0-9a-f]+', r[1]).group(0)

f = os.path.join(D, "spaceshift.txt"); open(f, "w").write("Result: \n")
m = MCP()
r = show("launch+open", m.call("app", {"action": "launch", "name": "TextEdit", "open": f, "waitForWindow": True}))
wid = int(re.search(r"Window (\d+) ", r[1]).group(1))
r = show("see (visible)", m.call("see", {"app_target": "TextEdit", "window_id": wid}), 120)
s = snap(r); ta = re.search(r'(elem_\d+)[^\n]*(?:text area|AXTextArea)', r[1], re.I) or re.search(r'Text selection (elem_\d+)', r[1])
elem = ta.group(1); print("text element", elem)
sw(AWAY); print(f"--- switched to Space {AWAY}; the window stays on Space {HOME_SPACE}")
try:
    show("press cmd+s (keyboard)", m.call("press", {"snapshot": s, "keys": ["cmd+s"], "observe_after": False}))
    show("set_value (AX)", m.call("set_value", {"snapshot": s, "on": elem, "value": "Result: 41\n"}))
    show("select_text (AX)", m.call("select_text", {"snapshot": s, "on": elem, "text": "Result: ", "selection_type": "cursor_after"}))
    show("click at point (expect refusal)", m.call("click", {"snapshot": s, "coords": "300,200", "observe_after": False}))
    show("type (keyboard)", m.call("type", {"snapshot": s, "on": elem, "text": "42", "observe_after": False}))
finally:
    sw(HOME_SPACE); print(f"--- back on Space {HOME_SPACE}")
time.sleep(1); print("file now:", repr(open(f).read()))
m.call("window", {"action": "close", "app": "TextEdit", "window_id": wid}); m.call("app", {"action": "quit", "name": "TextEdit"}); m.close()
