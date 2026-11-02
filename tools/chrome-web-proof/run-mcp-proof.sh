#!/bin/zsh
# MCP path of the live proof: one `peekaboo mcp serve` session runs see -> scroll (on the Quillfield cell) -> see.
# Usage: run-mcp-proof.sh <chrome-pid> <window-id> <out-dir> [new-binary]. Takes the desktop lock.
set -u
PID=$1 WIN=$2 OUT=$3
B=${4:-/private/tmp/claude-501/pb-chrome-web-bin/peekaboo}
HERE=${0:A:h}
H=/private/tmp/claude-501/pb-chrome-web-helpers
mkdir -p "$OUT" "$H"
for h in reset-page-top window-coverage; do
  [ "$H/$h" -nt "$HERE/helpers/$h.swift" ] || swiftc -O -o "$H/$h" "$HERE/helpers/$h.swift"
done
front() { lsappinfo info -only pid "$(lsappinfo front)" | sed -n 's/.*pid = \([0-9]*\).*/\1/p'; }
until mkdir /tmp/peekaboo-desktop.lock 2>/dev/null; do sleep 15; done
echo "pb-chrome-web mcp proof $(date)" > /tmp/peekaboo-desktop.lock/owner
( while true; do echo "$(date '+%H:%M:%S') front_pid=$(front)"; sleep 0.1; done ) > "$OUT/front-app-samples.log" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null; rm -rf /tmp/peekaboo-desktop.lock' EXIT
"$H/reset-page-top" "$PID" >/dev/null; sleep 0.5; "$H/reset-page-top" "$PID" >/dev/null; sleep 0.5
echo "coverage: $("$H/window-coverage" "$WIN" | head -1); front before: $(front)" | tee "$OUT/mcp.log"
python3 -I "$HERE/mcp-client.py" "$B" call "[{\"name\":\"see\",\"arguments\":{\"app_target\":\"PID:$PID\"}},{\"name\":\"scroll\",\"arguments\":{\"on\":\"\$text:(elem_\\\\d+) - \\\"Quillfield\\\"\",\"snapshot\":\"\$text:Snapshot ID: (\\\\S+)\",\"direction\":\"down\",\"amount\":3}},{\"name\":\"see\",\"arguments\":{\"app_target\":\"PID:$PID\"}}]" > "$OUT/mcp-session.json" 2>&1
kill $SAMPLER
python3 - "$OUT/mcp-session.json" <<'PY' | tee -a "$OUT/mcp.log"
import json, sys
raw = open(sys.argv[1]).read()
objs, depth, start = [], 0, None
for i, ch in enumerate(raw):
    if ch == '{':
        if depth == 0: start = i
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0: objs.append(json.loads(raw[start:i + 1]))
see1, scroll, see2 = objs
rows = lambda t: [l.strip() for l in t.splitlines() if "Quillfield" in l or "R-24" in l]
print("see #1 rows:", rows(see1["text"]))
print("see #1 warning:", [l.strip() for l in see1["text"].splitlines() if "Screenshot may be stale" in l])
print("scroll args:", scroll["arguments"])
print("scroll isError:", scroll["isError"], "| text:", scroll["text"].replace("\n", " ")[:300])
print("see #2 rows:", rows(see2["text"]))
PY
echo "front samples: $(wc -l < "$OUT/front-app-samples.log" | tr -d ' '), with test Chrome front: $(grep -c "front_pid=$PID\$" "$OUT/front-app-samples.log"); distinct: $(sed 's/.*front_pid=//' "$OUT/front-app-samples.log" | sort | uniq -c | tr '\n' ' ')" | tee -a "$OUT/mcp.log"
