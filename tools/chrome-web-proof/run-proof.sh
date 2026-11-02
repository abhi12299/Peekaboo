#!/bin/zsh
# Live proof for the Chromium web-content fixes: read a table row below the fold and scroll it into
# view in the background, without Chrome becoming the front app.
#
# Usage: run-proof.sh <chrome-pid> <window-id> <out-dir> <covered|partial> [new-binary] [baseline-binary]
# The Chrome instance should be a throwaway one (own --user-data-dir, see launch-test-chrome.sh) showing
# dashboard.html#regions. "covered" leaves the window where it is (expected: fully behind another window);
# "partial" moves it so its bottom strip is uncovered, so Chrome keeps painting and screenshots are fresh,
# then moves it back. Takes the shared desktop lock for the whole run.
set -u
PID=$1 WIN=$2 OUT=$3 MODE=$4
NEW=${5:-/private/tmp/claude-501/pb-chrome-web-bin/peekaboo}
OLD=${6:-/Users/abhi/Desktop/Work/projects/peekaboo/bin/peekaboo}
HERE=${0:A:h}
BIN=/private/tmp/claude-501/pb-chrome-web-helpers
mkdir -p "$OUT" "$BIN"
for h in reset-page-top move-window window-coverage; do
  [ "$BIN/$h" -nt "$HERE/helpers/$h.swift" ] || swiftc -O -o "$BIN/$h" "$HERE/helpers/$h.swift"
done
LOG="$OUT/proof.log"
: > "$LOG"
log() { print -r -- "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
front_pid() { lsappinfo info -only pid "$(lsappinfo front)" | sed -n 's/.*pid = \([0-9]*\).*/\1/p'; }

until mkdir /tmp/peekaboo-desktop.lock 2>/dev/null; do sleep 15; done
echo "pb-chrome-web $(date)" > /tmp/peekaboo-desktop.lock/owner
SAMPLER=""
ORIG_Y=""
cleanup() {
  [ -n "$SAMPLER" ] && kill "$SAMPLER" 2>/dev/null
  if [ -n "$ORIG_Y" ]; then
    # A window moved mostly below the display may land short of the target on the first move.
    for _ in 1 2 3; do "$BIN/move-window" "$PID" 200 "$ORIG_Y" >/dev/null; sleep 0.5; done
    print -r -- "window restored: $("$BIN/window-coverage" "$WIN" | tail -1)" | tee -a "$LOG"
  fi
  rm -rf /tmp/peekaboo-desktop.lock
}
trap cleanup EXIT INT TERM

# Front-app sampler: one line per 100 ms for the whole run.
( while true; do print -r -- "$(date '+%H:%M:%S') front_pid=$(front_pid)"; sleep 0.1; done ) > "$OUT/front-app-samples.log" &
SAMPLER=$!

# Page back to its initial state (Regions section at the top). A second reset flushes the geometry
# of a covered window, which Chrome only reports after the next accessibility action.
"$BIN/reset-page-top" "$PID" >/dev/null; sleep 0.5; "$BIN/reset-page-top" "$PID" >/dev/null; sleep 0.5
if [ "$MODE" = partial ]; then
  ORIG_Y=93
  "$BIN/move-window" "$PID" 200 850 >/dev/null; sleep 1
  "$BIN/reset-page-top" "$PID" >/dev/null; sleep 0.5
fi
log "mode=$MODE; window coverage: $("$BIN/window-coverage" "$WIN" | tr '\n' ';')"
log "chrome pid=$PID window=$WIN; front app before: pid $(front_pid) ($(ps -o comm= -p "$(front_pid)"))"

log "== baseline ($OLD): see"
"$OLD" see --pid "$PID" --window-id "$WIN" --json --path "$OUT/baseline-see.png" > "$OUT/baseline-see.json" 2>&1
python3 - "$OUT/baseline-see.json" <<'EOF' | tee -a "$LOG"
import json, sys
d = json.load(open(sys.argv[1]))["data"]
els = d["ui_elements"]
hits = [e for e in els if "Quillfield" in (e.get("label") or "") + (e.get("value") or "")]
cells = [e for e in els if e.get("ax_role") == "AXCell"]
print(f"baseline: {len(els)} elements, {len(cells)} cells, cells with text: "
      f"{sum(1 for c in cells if (c.get('label') or '') not in ('', 'cell'))}, 'Quillfield' hits: {len(hits)}")
EOF

log "== new build ($NEW): see"
"$NEW" see --pid "$PID" --window-id "$WIN" --json --path "$OUT/before-scroll.png" > "$OUT/before-scroll-see.json" 2>&1
read SNAP ELEM BEFORE_Y PAGE_BOTTOM <<<"$(python3 - "$OUT/before-scroll-see.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))["data"]
els = d["ui_elements"]
cell = next(e for e in els if e.get("ax_role") == "AXCell" and e.get("label") == "Quillfield")
web = max((e for e in els if e.get("ax_role") == "AXWebArea"), key=lambda e: e["bounds"]["width"] * e["bounds"]["height"])
print(d["snapshot_id"], cell["id"], cell["bounds"]["y"], web["bounds"]["y"] + web["bounds"]["height"])
EOF
)"
python3 - "$OUT/before-scroll-see.json" <<'EOF' | tee -a "$LOG"
import json, sys
els = json.load(open(sys.argv[1]))["data"]["ui_elements"]
cells = [e for e in els if e.get("ax_role") == "AXCell"]
row24 = [c["label"] for c in cells if c["bounds"]["y"] == max(x["bounds"]["y"] for x in cells)]
print(f"new: {len(els)} elements, {len(cells)} cells; last row reads: {' | '.join(row24)}")
EOF
log "new see warnings: $(python3 -c "import json;print(json.load(open('$OUT/before-scroll-see.json'))['data']['observation']['warnings'])")"
log "target $ELEM 'Quillfield' at y=$BEFORE_Y; visible page ends at y=$PAGE_BOTTOM (below the fold: $(( BEFORE_Y > PAGE_BOTTOM )))"

log "== baseline ($OLD): scroll down on $ELEM (expect the old refusal)"
"$OLD" see --pid "$PID" --window-id "$WIN" --json --path "$OUT/baseline-see2.png" > "$OUT/baseline-see2.json" 2>&1
OLD_SNAP=$(python3 -c "import json;print(json.load(open('$OUT/baseline-see2.json'))['data']['snapshot_id'])")
OLD_ROW=$(python3 -c "
import json
els=json.load(open('$OUT/baseline-see2.json'))['data']['ui_elements']
rows=[e for e in els if e.get('ax_role')=='AXRow']
print(max(rows,key=lambda e:e['bounds']['y'])['id'] if rows else '')")
if [ -n "$OLD_ROW" ]; then
  "$OLD" scroll --direction down --amount 3 --on "$OLD_ROW" --snapshot "$OLD_SNAP" --pid "$PID" --window-id "$WIN" --json \
    > "$OUT/baseline-scroll.json" 2>&1
  log "baseline scroll on last row $OLD_ROW: $(python3 -c "
import json
d=json.load(open('$OUT/baseline-scroll.json'))
e=d.get('error') or {}
print(d.get('success'), (e.get('message') or '')[:160])")"
fi

log "== new build: scroll down on $ELEM"
"$NEW" scroll --direction down --amount 3 --on "$ELEM" --snapshot "$SNAP" --pid "$PID" --window-id "$WIN" --json \
  > "$OUT/scroll.json" 2>&1
log "scroll result: $(python3 -c "
import json
d=json.load(open('$OUT/scroll.json'))
data=d.get('data') or {}
print('success=%s' % d.get('success'), json.dumps({k: data.get(k) for k in ('action_name','path','outcome','delivery')})[:400], (d.get('error') or {}).get('message',''))")"

log "== new build: see after scroll"
"$NEW" see --pid "$PID" --window-id "$WIN" --json --path "$OUT/after-scroll.png" > "$OUT/after-scroll-see.json" 2>&1
python3 - "$OUT/after-scroll-see.json" "$PAGE_BOTTOM" <<'EOF' | tee -a "$LOG"
import json, sys
els = json.load(open(sys.argv[1]))["data"]["ui_elements"]
page_bottom = float(sys.argv[2])
cell = next(e for e in els if e.get("ax_role") == "AXCell" and e.get("label") == "Quillfield")
y = cell["bounds"]["y"]
print(f"after: 'Quillfield' at y={y}; inside visible page: {y + cell['bounds']['height'] <= page_bottom}")
EOF

kill "$SAMPLER"; SAMPLER=""
log "front app after: pid $(front_pid) ($(ps -o comm= -p "$(front_pid)"))"
TOTAL=$(wc -l < "$OUT/front-app-samples.log" | tr -d ' ')
CHROME=$(grep -c "front_pid=$PID\$" "$OUT/front-app-samples.log")
log "front-app samples: $TOTAL taken, $CHROME with the test Chrome (pid $PID) in front"
log "distinct front pids: $(sed 's/.*front_pid=//' "$OUT/front-app-samples.log" | sort | uniq -c | tr '\n' ' ')"
