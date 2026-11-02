# Chromium web-content proof

Live check for fix/pb-chrome-web: read a table row below the fold in Chrome and scroll it into view in
the background, without Chrome becoming the front app.

- `dashboard.html`: local test page. In-page Overview/Regions tabs (ARIA tablist), a 420 pt spacer and
  a 24-row table. Row R-24 (Quillfield) is below the fold.
- `launch-test-chrome.sh`: starts a throwaway Chrome with its own profile showing the page and hands the
  front app back (Chrome activates itself on launch). Hold the desktop lock while it runs.
- `run-proof.sh <chrome-pid> <window-id> <out-dir> covered|partial`: takes the desktop lock, samples the
  front app every 100 ms, runs the live `bin/peekaboo` as the baseline, then runs see → scroll → see
  with the new build. `covered` leaves the window fully behind another window; `partial` uncovers a
  strip so Chrome keeps painting and the screenshots are fresh.
- `mcp-client.py`: minimal stdio MCP client. Starts `peekaboo mcp serve` and calls tools in one session,
  so the MCP path (policy, snapshot store, see text) is exercised the way an agent uses it.
- `helpers/`: tiny AX/CG tools the script compiles on first use (page reset, window move, coverage).

Outputs go to `proof-*/` (ignored by git): `proof.log`, `front-app-samples.log`, see/scroll JSON,
and screenshots.
