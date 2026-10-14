---
name: computer-use-routing
description: Decide which tool set drives the computer. Use whenever a task needs browser or desktop control, such as clicking, typing, filling forms, uploading files, taking screenshots, or operating an app. Anything inside a Chrome tab goes to the Claude in Chrome extension (mcp__claude-in-chrome__*). Every other app (Finder, TextEdit, Calculator, Slack, Teams desktop, Electron apps, Chrome's own UI, chrome:// pages, native file pickers, JS alert dialogs) goes to the Peekaboo MCP server.
---

# Computer-use routing

Two tool sets are loaded in the same session. Pick one per step by what the target is.

## Route

| Target | Use |
|---|---|
| Content of a Chrome tab (pages, forms, canvas, DOM, console, network) | Claude in Chrome: `mcp__claude-in-chrome__*` |
| Finder, TextEdit, Calculator, Slack, Teams desktop, VS Code, other Electron or native apps | Peekaboo MCP |
| Chrome's own UI (toolbar, menus, profile picker), `chrome://` pages | Peekaboo |
| Native file open/save pickers | Peekaboo, but avoid them (see below) |
| JavaScript `alert`/`confirm`/`prompt` dialogs | Peekaboo. They freeze the extension; dismiss with Peekaboo, then resume with the extension |
| Safari, Firefox, any non-Chrome browser | Peekaboo |

Peekaboo cannot see or act on an inactive Chrome tab, so never use it for tab content. The extension is Chrome only and each site must be allowed in its settings.

Load the extension tools with ToolSearch before first use (see the claude-in-chrome skill). Peekaboo's own `browser` tool should be off; if it appears, do not use it for Chrome.

## Hand-offs go through files

Never pass data by clipboard or by drag between the two. Use the disk:
- A download made in Chrome lands in `~/Downloads`. Open or process it with Peekaboo from there.
- A file made by a native app can be uploaded in Chrome with `file_upload` (10 MB cap per call; paths in the session folders, the project and `~/Downloads` are accepted).

## Chrome rules (extension)

- Batch calls (`browser_batch`) where possible; a full form took 3 batched calls.
- Use `file_upload` for uploads, including hidden file inputs behind a "Choose file" button. It does not open a native picker. It only targets file inputs, so it cannot drop a file onto a bare drop zone.
- `left_click_drag` handles pointer drags, sliders and HTML5 drag and drop.
- Events arrive with `isTrusted: true` and the macOS cursor and frontmost app do not move.

## Peekaboo rules (fork, background input)

Config: the fork server runs as `peekaboo mcp` with `PEEKABOO_NO_REMOTE=1` and `PEEKABOO_DISABLE_TOOLS=browser`. The first stops an official Peekaboo app from doing the input; the second removes the browser tool.

- Do not steal focus. Do not use `--foreground`/foreground consent, the real cursor, or `switch`/`focus` unless the user asks. The user keeps working on the same Mac.
- Start apps with `app launch` (non-activating). A cold launch does not take the front and hands it back if the app grabs it within about 3 s.
- Open documents with `app launch` and `open` (absolute path, array of paths, or `file:` URLs), not the Open panel and not a Finder double-click. It works whether the app is running or not. Missing paths, directories and non-file URLs are refused. With `waitForWindow: true` the result names the document's window ("Window 913 'result.txt' shows it"); pass that `window_id` straight to `see`. Call `window list` only if it says no window was found.
- Prefer element-ID clicks (accessibility press) over coordinates. They need no focus session and are the most reliable.
- Reuse the snapshot: one `see` can drive many consecutive element clicks after a background accessibility-action click (check `_meta.snapshot_reusable_for_element_clicks`). Take a fresh `see` after anything that changes the UI structure, since a reused snapshot clicks whatever is now at the old point.
- Peekaboo retries once by itself, after a short pause, when the window changed just before a press, click or drag ("background window activation target changed before delivery") or during a capture ("target changed during capture"). If the error still comes back, observe once and retry once; no long sleeps.
- After `app launch` with `waitForWindow`, a "window is minimized" note means run `window restore` before `see`.
- Target-check refusals show captured vs now values. "on screen: no" / "not on screen" usually means the window is not on the visible Space; retrying will not help until it is.
- A success with an "unverified" warning means the event was delivered but not confirmed. Do not retry blindly. A true "indeterminate" result is different: observe before acting again.
- `click`, `type`, `press`, `scroll`, `paste` and `drag` that carry a `snapshot` (or `window_id`) append a `see` of that window to their own result when delivery is unverified. Read it instead of calling `see`, `window list`, `dialog list` or `image` again. If it says "Window N is no longer open", the window closed; when it names a dialog or sheet, handle it with `dialog`. Pass `observe_after: false` when you will chain actions and observe once, or `true` to observe a confirmed action too. Several steps in a row still belong in one `batch`.
- After `window close`, read its last line. "No dialog or sheet is open" means the close is done: no `dialog list` or `window list` follow-up. If it names a sheet, answer it with `dialog`; call `dialog list` only when it says it could not check.
- Cmd+W, Cmd+Q, Cmd+H and Cmd+M work in background through `press`, like other hotkeys: they go only to the target window's app and return success with delivery unverified. With a `snapshot`, the appended observation shows the effect: "Window N is no longer open" (answer any save sheet it names with `dialog`), or "its app is no longer running" after Cmd+Q. `window close`, `app quit`, `app hide` and `window minimize` verify their effect, so prefer them when you need a confirmed result.
- Cmd+S and other hotkeys work in background through `press`.
- Drags and right, middle or double clicks by coordinates work in background on native apps.
- `see` retries an incomplete accessibility read once by itself; if `ACCESSIBILITY_INCOMPLETE` still comes back, retry once. `inspect_ui` does not retry by itself. Windows on another Space are readable on the fork build.
- `dialog list` with no dialog open succeeds with `dialog_present=false`; only real failures are errors.
- Clipboard paste still errors when delivery is unconfirmed (it restores your clipboard, so a retry needs a fresh look). Background text paste and `type` return success with an "unverified" warning.
- Never type through the real keyboard path in experiments; it can land in the user's other sessions.

## Do not

- Do not use Peekaboo to click inside a Chrome tab, or the extension for anything outside a tab.
- Do not retry a delivered input just because it was unverified.
- Do not leave windows or menus open or apps running that you started; close them through the tools above.
