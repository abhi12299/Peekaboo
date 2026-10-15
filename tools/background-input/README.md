# Background-input tooling

Support files for the `background-input` branch: the work that lets Peekaboo drive native macOS apps in the background (no cursor, keyboard focus or front-app takeover), benchmarked against Codex computer use.

- `TDD-BRIEF.md`: the brief every implementation step followed (test-first, 2-core build limit, never send input to the real desktop from tests).
- `FINDINGS.md`: what the experiments found about background input on macOS 26 (window-tagged events, the focus-record recipe).
- `click-experiments/`: the probes behind those findings, with their logs.
- `harness/`: the benchmark. `run.sh <codex|fork> native` runs one task (Calculator sum, then write the result into TextEdit and save); `fair.sh [prefix]` alternates Codex and the fork on separate sums (`CODEX_MODEL` picks the Codex model); `quiet.sh [prefix]` runs the fork alone; `summarize.py runs/<dir>...` prints one line per run; `offspace/` checks window management on another Space; `hotkeys.py` checks background Cmd+W and Cmd+Q on TextEdit and Calculator.
- `bin/refresh-peekaboo.sh`: copies the CLI build to `bin/peekaboo` and signs it (set your own signing identity).
- `skills/computer-use-routing/SKILL.md`: the Claude Code skill that routes desktop work to this server and explains its results.
- `mcp.example.json`: the MCP server entry (`PEEKABOO_NO_REMOTE=1`, browser tool disabled).

Paths in the scripts point at the original checkout; adjust them to yours.
