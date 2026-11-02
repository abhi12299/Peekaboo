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
- Open/Save panels (file pickers): use `dialog` `action: file` with the app or pid, `path` = the folder and `name` = the bare file name. It changes folder through the panel's own controls, saves (or opens the file in an Open panel) and checks the file on disk, all in the background. Never click the Where popup or type a path into "Save As" (a typed "/" becomes part of the name). It can't reach folders inside hidden ones (`/private`, dot-folders); pick a visible folder. To bring up a Save panel, `press` Cmd+S on the document window (exact `window_id`).
- Open a folder in an editor (Cursor, VS Code) with `app launch` + `open: <folder>`. Electron apps activate themselves when the window opens; Peekaboo hands the front back and says so.
- Prefer element IDs from `see` over coordinates. Do several steps in one `batch`.
- Actions that carry a `snapshot` append a fresh look at the window when delivery is unverified. Read it instead of calling `see`/`window list`/`dialog list` again. "Unverified" is not a failure: don't retry blindly.
- "Window N is no longer open" means it closed; if a dialog or sheet is named, answer it with `dialog`. After `window close`, "No dialog or sheet is open" means done.
- Hotkeys (Cmd+S, Cmd+W, Cmd+Q, …) work through `press`. Prefer `window close`/`app quit` when you need a confirmed result.
- A refusal that shows captured vs now bounds: take a fresh `see`. Right after a Space switch, wait a few seconds before acting. Keyboard and accessibility actions work on windows on other Spaces; point clicks may not.
- If a launched app's window is minimized, `window restore` before `see`.
- Close windows and quit apps you opened.
