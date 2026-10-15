---
name: computer-use-routing
description: Decide which tool set drives the computer. Use whenever a task needs browser or desktop control (clicking, typing, forms, uploads, screenshots, operating an app). Content inside a Chrome tab goes to the Claude in Chrome extension (mcp__claude-in-chrome__*); every other app (Finder, TextEdit, Slack, Teams, Electron apps, Chrome's own UI, chrome:// pages, native pickers, JS alert dialogs) goes to the Peekaboo MCP server.
---

# Computer-use routing

## Route
- **Inside a Chrome tab** (pages, forms, DOM, console): Claude in Chrome. Load its tools with ToolSearch first. If they are not available in this session, say so; do not drive tabs with Peekaboo.
- **Everything else** (native and Electron apps, Chrome's toolbar/menus, `chrome://` pages, other browsers, JS alert dialogs, file pickers): Peekaboo.
- Hand data between them through files (`~/Downloads`, `file_upload`), never the clipboard.

## Peekaboo (background fork)
It works in the background: the user keeps the cursor, keyboard and front app.
- Never use `--foreground`, `switch`/`focus` or the real cursor unless the user asks.
- Launch with `app launch`; open files with `app launch` + `open` + `waitForWindow: true`, then pass the window ID it names to `see`.
- Open/Save panels (file pickers) are not usable in the background yet: Peekaboo can't read or click them. Avoid them: open existing files with `app launch` + `open`, save them with Cmd+S. For a new file, create it first (e.g. with the shell) and open it, or ask before using the foreground. `dialog list` saying "No dialog" right after Save… is not proof that nothing opened.
- Prefer element IDs from `see` over coordinates. Do several steps in one `batch`.
- Actions that carry a `snapshot` append a fresh look at the window when delivery is unverified. Read it instead of calling `see`/`window list`/`dialog list` again. "Unverified" is not a failure: don't retry blindly.
- "Window N is no longer open" means it closed; if a dialog or sheet is named, answer it with `dialog`. After `window close`, "No dialog or sheet is open" means done.
- Hotkeys (Cmd+S, Cmd+W, Cmd+Q, …) work through `press`. Prefer `window close`/`app quit` when you need a confirmed result.
- A refusal that shows captured vs now bounds: take a fresh `see`. Right after a Space switch, wait a few seconds before acting. Keyboard and accessibility actions work on windows on other Spaces; point clicks may not.
- If a launched app's window is minimized, `window restore` before `see`.
- Close windows and quit apps you opened.
