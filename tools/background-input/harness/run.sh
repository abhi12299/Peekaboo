#!/bin/zsh
# Runs one benchmark task with one agent. Usage: run.sh <agent: codex|peekaboo|fork> <task: native|browser>
B=${0:A:h}; AGENT=$1; TASK=$2; X=${X:-847}; Y=${Y:-39}; RUN="$AGENT-$TASK"; D="$B/runs/$RUN"; rm -rf "$D"; mkdir -p "$D"
CODEX=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
printf 'Result: ' > "$D/result.txt"
BG="I am using this Mac while you work, so avoid taking over my mouse, keyboard focus or frontmost app wherever you can."
if [[ $TASK == native ]]; then
P="$BG Using the macOS Calculator app, compute $X x $Y by pressing the app's buttons. Then open the file $D/result.txt in TextEdit, type the result right after the existing text 'Result: ', save the file with the keyboard shortcut, and close that TextEdit window. Quit Calculator at the end. Do every step through the GUI: do not use a shell, scripts or direct file writes. Reply with the number Calculator displayed."
else
P="$BG In Google Chrome, open a new tab at http://127.0.0.1:8765/ and do not touch, close or navigate any of my existing tabs. On that page: 1) enter the full name 'Ada Lovelace' and the email 'ada@example.com'; 2) choose the 'Team' plan; 3) add two tags, 'alpha' and 'beta', using the Tag field and the 'Add tag' button; 4) open the advanced options and choose High priority; 5) click the green circle on the canvas; 6) tick the agree checkbox and press Submit. Then save a PNG screenshot of the page showing the confirmation to $D/confirmation.png, and close only the tab you opened. Use only GUI or browser-control tools: no shell, curl or direct HTTP requests. Reply with the confirmation code shown on the page."
fi
osascript -e 'tell application "Calculator" to quit' >/dev/null 2>&1
echo "$RUN" > "$B/current_run"; echo "$P" > "$D/prompt.txt"
"$B/sampler" "$D/sampler.jsonl" & SP=$!
START=$(date +%s)
cd "$D"
if [[ $AGENT == codex ]]; then
  perl -e 'alarm shift; exec @ARGV' 1200 "$CODEX" exec ${CODEX_MODEL:+-m} ${CODEX_MODEL:+$CODEX_MODEL} --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C "$D" --json "$P" > "$D/transcript.jsonl" 2> "$D/stderr.log" < /dev/null
else
  perl -e 'alarm shift; exec @ARGV' 1200 claude -p "$P" --model claude-opus-5-5 --mcp-config "$B/$( [[ $AGENT == fork ]] && echo pb-fork-mcp.json || echo pb-mcp.json )" --strict-mcp-config --tools "" --allowedTools "mcp__peekaboo" --disallowedTools "mcp__peekaboo__agent" "mcp__peekaboo__analyze" --output-format stream-json --verbose --no-session-persistence > "$D/transcript.jsonl" 2> "$D/stderr.log" < /dev/null
fi
echo "exit=$? secs=$(( $(date +%s) - START )) expected=$(( X * Y ))" > "$D/timing.txt"
# crash reports written during the run (e.g. Maestro simulator crash dialogs that can take the front)
find ~/Library/Logs/DiagnosticReports -maxdepth 1 -newer "$D/prompt.txt" -name "*.ips" > "$D/crashes.txt" 2>/dev/null
kill $SP; echo none > "$B/current_run"
