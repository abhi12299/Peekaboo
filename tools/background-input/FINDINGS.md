# Peekaboo vs Codex computer use: investigation handoff (2026-10-07)

Goal: bring a fork of Peekaboo (steipete/Peekaboo, MIT) to the level of Codex computer use on macOS, so Claude Code can drive the desktop in the background without a Codex subscription. So far this was investigation only. No fork, no GitHub repo and no code changes exist yet.

Ground rules from Abhishek:
- Research competitors from public sources and black-box behaviour only. Do not disassemble or extract OpenAI binaries.
- Do not save any of this to Claude memory.

## 1. Head-to-head benchmark

Both agents got identical prompts (see `runs/*/prompt.txt`). Codex ran as `codex exec --dangerously-bypass-approvals-and-sandbox` with its bundled computer-use plugin. Peekaboo ran in a headless `claude -p` session with only the Peekaboo MCP server, no built-in tools, and Peekaboo's own `agent` and `analyze` tools removed. A sampler logged the real cursor, the frontmost app and any Codex or Peekaboo overlay windows every 200 ms. A local test site logged every form event server-side as ground truth.

| Run | Outcome | Time | Tool calls |
|---|---|---|---|
| codex-native | Pass. Typed 33033 and saved with Cmd+S. | 166s | 14 |
| peekaboo-native | Fail. MCP refused to cold-launch Calculator. | 30s | 4 |
| peekaboo-native-preopened | Partial. Calculator correct, text typed, Cmd+S refused. | 369s | 89 |
| codex-browser | Pass. All 7 checks, CONF-FFE155, screenshot saved, tab closed. | 88s | 7 |
| peekaboo-browser | Fail. The test page never loaded. | 241s | 40 |

- Neither tool moved the real cursor or changed the frontmost app in any run. The cursor movement in the sampler logs is the user's own.
- In the pre-opened run, `result.txt` on disk contains the result because TextEdit autosaved, not because Peekaboo saved it.
- Confounds: Codex used GPT-6 Astra (high), Peekaboo used Claude Opus 5.5, and each task ran once. Most Peekaboo failures were policy refusals, not model mistakes.
- peekaboo-browser left a separate Chrome window on New Tab, and probably a blank tab in the user's Teams window. The user has been told.

Expected confirmation code for "Ada Lovelace" plus "Team": CONF-FFE155.

## 2. How Codex does it (observed and public sources)

- **Virtual mouse.** An ordinary window titled "Software Cursor", owned by the "ChatGPT Computer Use" helper, about 126x126 points. It moved between the target buttons. The real cursor never came within 40 px of it across 281 samples. See `runs/codex-native/sampler.jsonl`.
- **Native apps.** Reads the accessibility tree, clicks by element index, and uses set-value and select-text. Several actions are batched into one JavaScript REPL call.
- **Chrome.** No OS-level input at all. Codex creates a tab through its own Chrome extension and a native messaging host, fills the form with Playwright over CDP, clicks the canvas with raw `Input.dispatchMouseEvent`, and screenshots with `Page.captureScreenshot`. Every page event arrived with `isTrusted: true`.
- **Background input on macOS generally.** See the Cua write-up (https://cua.ai/blog/inside-macos-window-internals). It covers per-process event posting, a SkyLight focus record that makes a window active without raising it, a (-1,-1) primer click for Chromium's user-activation gate, and remote AX observers for occluded Electron windows.
- **Prior art.** An agent-desktop PR used public `CGEventPostToPid`, fields 91/92 and `CGEventSetWindowLocation`, plus SkyLight posting and a focus record (https://github.com/lahfir/agent-desktop/pull/227). The maintainer closed it, preferring accessibility only.

## 3. SkyLight and public APIs (checked locally, macOS 26.6)

- CoreGraphics re-exports its event posting from SkyLight. `CGEventPostToPid` is the same function as `SLEventPostToPid` (`dyld_info -exports`).
- **Public, in SDK headers:** `CGEventPostToPid`, fields 91/92 (window under pointer), `CGEventSetLocation`, `kCGEventTargetUnixProcessID`.
- **Exported, no header:** `CGEventSetWindowLocation`, a re-export of `SLEventSetWindowLocation`.
- **Private only:** `SLPSPostEventRecordTo` and `_SLPSSetFrontProcessWithOptions`, used for the focus-without-raise record.

**Experiment** (`click-experiments/bgclick.swift`). I posted a left click at Calculator's 7 button while the app was in the background, in four variants:
- plain public posting
- adding fields 91/92
- adding window-local location
- adding the primer click

None pressed the button: every before and after capture was byte-identical. None moved the cursor or the frontmost app. The focus-without-raise record was not tested, so whether it fixes AppKit targets is still open.

Caution: an earlier botched run, with wrong coordinates in the gap between button rows, coincided with the Calculator window wandering off-screen. A synthetic mouse-down on the draggable window background may start a drag that follows the real mouse. This is unproven but worth guarding against.

## 4. Peekaboo source map

Read from upstream commit efd65b5. The submodules, including AXorcist, were not checked out. Abbreviations:
- `AK` = `Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit`
- `RT` = `Core/PeekabooCore/Sources/PeekabooAgentRuntime`

**Background clicks**
- Element clicks use AXPress (`AK/Services/UI/ClickService.swift:1447-1456`).
- Coordinate clicks are in `AK/Services/UI/BackgroundInputDriver.swift:1571-1648`. Right, double, middle and triple clicks go to `WindowRoutedPointerDriver` and become real pointer events (`:1607-1618`). A single left-click only hit-tests and presses an accessibility element (`:1622-1647`). Its error text is at `:1546-1554`.

**Routed pointer driver** (`AK/Services/UI/WindowRoutedPointerDriver.swift`)
- Stamps fields 51, 58, 91 and 92 (`:760-772`).
- Looks up `CGEventSetWindowLocation` with dlsym (`:929-935`).
- Gets `SLEventPostToPid` by dlopening SkyLight (`:925-944`).
- Chooses the transport in `WindowRoutedApplicationClassifier.swift:69-76`: SkyLight for Chromium, Electron and Catalyst, public posting for AppKit. These are the same function on 26.6.

**Focus without raising**
- `SLPSPostEventRecordTo` with a hand-built 0xF8 record: `AK/.../BackgroundWindowActivationDriver.swift:13-72`.
- It is used only by the paste preparation path: `BackgroundWindowKeyboardPreparation.swift:30-51`.

**Typing and hotkeys**
- Typing writes the accessibility value first, then falls back to Unicode key events posted per process: `BackgroundInputDriver.swift:330-346,479-519` and `TargetedTypeInputDriver.swift:8-50`.
- Hotkeys use `HotkeyService.swift:113`.
- Verification is in `TypeService.swift:1459-1490`.

**App launch**
- The background-launch refusal is in `ApplicationService+Lifecycle.swift:84-88,276-306`.
- `activates` is passed only when it is true (`:104`).
- Further guards: `AppCommand+Launch.swift:125-135`, `RT/MCP/Tools/AppTool+Lifecycle.swift:12-19`, `RT/MCP/MCPToolContext.swift:1074-1079`.

**MCP policy**
- `--allow-foreground` is defined at `Apps/CLI/.../MCPCommand+Serve.swift:40-44,94`.
- Enforcement is in `RT/MCP/MCPToolExecutionPolicy.swift:173-235`, with the browser activation gate at `:470-491`.

**Cursor overlay**
- `Core/PeekabooVisualizer/.../AnimationOverlayManager.swift:105-119` draws it at screen-saver level.
- It is suppressed for any targeted background input (`UIAutomationService+Operations.swift:344-355`, `docs/visualizer.md:15`).
- It needs Peekaboo.app running and covers the whole screen.

**Browser**
- Uses pinned `chrome-devtools-mcp@1.10.1`, which attaches to the user's Chrome over `--wsEndpoint` (`RT/Browser/BrowserMCPService.swift:1148`).
- Requires Chrome 144 or later, remote debugging enabled at chrome://inspect, and approval for each connection (`docs/browser-mcp.md:62-86`).
- Background mode allows only read-type calls (`RT/Browser/BrowserMCPUserActivationPolicy.swift:21-90`).
- A signed browser handoff receipt exists (`docs/browser-mcp.md:168-174`).

**Capture**
- Occluded windows are captured with `SCContentFilter(desktopIndependentWindow:)`.
- Only one process may own ScreenCaptureKit: the lock is in `ScreenCaptureKitOwnerLease.swift:6-10`, and the contention error is in `RuntimeHostResolver+ScreenCaptureKitOwner.swift:613`.
- Workaround: share `peekaboo daemon start` through `--bridge-socket`.

**Chromium and Electron accessibility**
- No `AXManualAccessibility` or `AXEnhancedUserInterface` anywhere in the repo.
- Web focus retry only (`WebFocusFallback.swift:9-21`).

**Docs versus code**
- `docs/refactor/ui-input-action-first.md:863` lists private APIs as a non-goal, but the code already uses SkyLight.
- `CHANGELOG.md:653-656` describes the background-first safety policy.

**Fork build**
- Swift 6.2 with Xcode 26 and macOS 15+, using `python3 scripts/setup-swift-workspace.py setup` and then `pnpm run build:swift` (`docs/building.md`).
- Signing uses a Developer ID or `SIGN_IDENTITY` (`scripts/build-swift-arm.sh`).
- Bridge peers must belong to team FWJYW4S8P8 or Y5PE65HELJ (`PeekabooBridgeConstants.swift:15`). A fork must change this, or set `PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1` for development only.
- Re-signing means granting the macOS permissions again.

## 5. Gap list, highest impact first

1. **Browser input.** Build a Chrome extension plus a native messaging host for CDP, as Codex does. Allow trusted CDP input in background mode, and drop the need for remote debugging and per-connection approval.
2. **Background cold launch.** Pass `activates=false` to NSWorkspace, remove the refusals, and verify afterwards that the frontmost app is unchanged.
3. **Keyboard shortcuts in background windows.** Cmd+S was refused because "background keystrokes follow the application's own keyboard focus". Reuse the focus-without-raise record from the paste path for `press` and hotkeys.
4. **Observation reliability.** Repeated "AX tree incomplete" on Calculator, TextEdit and Chrome, plus stale-snapshot and ownership-mismatch refusals, cost 89 calls against Codex's 14. Add action batching per call.
5. **Background single left-click.** Route it to `WindowRoutedPointerDriver` when no pressable element exists (`BackgroundInputDriver.swift:1607`). It probably needs the focus record for AppKit; my public-only experiment failed.
6. **Software cursor during background actions.** Per target window, without requiring Peekaboo.app.
7. **Chromium and Electron accessibility trees.** Set `AXManualAccessibility`, plus background hover, long-press and wheel scroll for those apps.
8. **Per-app guidance**, such as Slack, Notion and Spotify tips. This could be a Claude Code skill instead of fork code.
9. **Concurrent capture** for a CLI and an MCP server at the same time, through a shared daemon by default.
10. **Fork logistics:** signing, Bridge team IDs and permission re-grants.

Peekaboo already matches Codex on background typing, element clicks, capture of occluded windows, and leaving the user's cursor alone.

## 6. Files in this folder

- `harness/`
  - `sampler.swift`: cursor, frontmost app and overlay sampler. Compile with `swiftc -O`.
  - `server.py`: test site on 127.0.0.1:8765.
  - `run.sh` and `all.sh`: runners. The paths inside point at the old scratchpad, so update `B` before reuse.
  - `analyze_sampler.py`, and `pb-mcp.json`, the Peekaboo MCP config.
  - `events.jsonl`: server ground truth for every run.
- `runs/<agent>-<task>/`: `prompt.txt`, `transcript.jsonl`, `sampler.jsonl`, `timing.txt`, `result.txt`, and Codex's `confirmation.png`.
- `click-experiments/`
  - `bgclick.swift`: public and SPI click variants.
  - `winlist.swift`, `access.swift` (permission check), `clicktest.py` (click target on :8766, not used yet), and `calc-win.png`.
- Upstream source: `git clone --depth 1 https://github.com/steipete/Peekaboo.git`. The Peekaboo binary used in the tests was `@steipete/peekaboo` 4.8.0 via npx.
