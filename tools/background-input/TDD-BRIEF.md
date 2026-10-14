# Peekaboo fork: background-input TDD brief (shared by all implementation agents)

## Repo
- Fork: /Users/abhi/Desktop/Work/projects/peekaboo/Peekaboo, branch `background-input` (from main 159412696). Swift 6.4 toolchain, Xcode 27; manifests are tools-version 6.2.
- Submodules are initialised. `Core/PeekabooCore/Package.resolved` shows as modified from setup: never stage or commit it.
- Abbreviations: AK = Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit, RT = Core/PeekabooCore/Sources/PeekabooAgentRuntime.
- Match the surrounding code style (naming, comment density, swift-testing `@Test`/`#expect` with `@testable import`, closure-injected fakes through internal inits). Check the repo's AGENTS.md / CLAUDE.md / lint config (swiftformat/swiftlint) and keep to them.

## Hard rules
- NEVER send input to the real desktop: no peekaboo click/type/press/drag/app commands, no tests that need RUN_AUTOMATION_ACTIONS / PEEKABOO_RUN_INPUT_AUTOMATION_TESTS / PEEKABOO_INCLUDE_AUTOMATION_TESTS=true. The user is using this Mac. Never post events through the HID tap.
- Strict TDD, vertical slices: write ONE failing test for ONE behaviour through a public (or `@testable` internal) interface, run it and SEE IT FAIL (red), write the minimal code to pass, run it and see it pass (green), then the next behaviour. Never write several tests first. Tests assert observable behaviour (events posted, order, outcomes, refusals), not private structure. Refactor only when green.
- Do not push, do not open PRs. Commit only your step's files when the step is green, with a message like `feat(background-input): <step summary>` and a body explaining what and why, ending with the trailer line:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Test commands (serial only; the parallel run hangs)
**CPU limit (Abhi, 2026-10-08): at most 2 cores. Pass `-j 2` to every `swift build` / `swift test`, and never run two builds at the same time.**
Prefix every test command with:
`PEEKABOO_INCLUDE_AUTOMATION_TESTS=false PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=false RUN_AUTOMATION_ACTIONS=false PEEKABOO_CONFIG_DISABLE_MIGRATION=1`
- AutomationKit (about 2 min build): `swift test --package-path Core/PeekabooAutomationKit --no-parallel --filter '<regex>'`
- PeekabooCore (about 10 min first build): `swift test --package-path Core/PeekabooCore --no-parallel --filter '<regex>'`
- Before committing, rerun the existing suites that cover the code you touched, plus your new ones, and report pass counts.
- Pre-existing failures to ignore (fail on main): `DesktopObservationServiceTests.testGenerationlessRemoteExactObservationStaysReadOnly`, `MenuBarHelperProcessWaitTests` (`items?.isEmpty == true`).

## The proven recipe (macOS 26.6 experiments, see the experiment tool `fr.swift` in ~/Desktop/Work/projects/peekaboo/handoff-computer-use-investigation/click-experiments/)
1. Mouse and key events posted per process (`CGEventPostToPid`) must carry integer field 51 = target window ID. Without it AppKit gets windowNumber 0 and drops pointer events.
2. Background focus session, used for background hotkeys, single left-clicks and drags:
   a. focus record: `SLPSPostEventRecordTo(psn, record)`, a 0xF8-byte record with [0x04]=0xF8, [0x08]=0x0D, window ID little-endian at 0x3C, kind at [0x8A] = 0x01 (focus). Existing builder: `BackgroundWindowActivationDriver` (AK/.../BackgroundWindowActivationDriver.swift), kind hard-coded 0x01 today.
   b. priming click: left mouse down then up at the point 10 pt left of and 10 pt above the window's top-left corner (outside the window), tagged with field 51 = the target window ID, posted to the target PID. It makes the window key without hitting any control. Never prime on the title bar or window background (that can start a window drag).
   c. the real action (key events with field 51; or pointer events through `WindowRoutedPointerDriver`).
   d. undo record: same record with kind 0x02 sent to the target window. It must run even if the action throws.
3. Not needed: a defocus record to the user's own front app, SkyLight posting instead of public posting, the (-1,-1) primer.
4. Always on for background hotkeys, clicks and drags, with a kill switch: env `PEEKABOO_BACKGROUND_FOCUS_RECORD=0` disables steps 2a, 2b and 2d (the old behaviour returns).

## Seams found (from the mapping agent; line numbers approximate)
- `HotkeyService.init` takes `eventPoster` and `backgroundWindowPreparer`; tests: `HotkeyServiceBackgroundPreparationTests`, `HotkeyServiceTargetingTests`. Key events today only carry the PID (`BackgroundInputDriver.stampKeyboardRoutingFields` ~:519), not field 51. The "Background keystrokes follow the application's own keyboard focus" refusal is `BackgroundKeyboardFocusRemediation` (`UIAutomationOperationModels.swift:325`), thrown from `UIAutomationTarget.swift:255-299` (`pinningCurrentFocusedElement`) and `UIAutomationService+ElementLookup.swift` (:76, :126, :177-180). MCP `press` path: `PressTool.swift:336-507`, then `UIAutomationService+PointerKeyboardOperations.swift:212/257`, then `HotkeyService.hotkey(automationTarget:...)` ~:194. `BackgroundHotkeyPolicy` refused background Cmd+W/Q/H/M; step 22 removed it at the user's request. The paste path `BackgroundWindowKeyboardPreparation.swift:31-45` sends 0x01 plus a click inside the chrome, with no undo.
- `WindowRoutedPointerDriver.swift` refuses points outside the window (guards ~:177, :826, :868, :889, :301, :371, :484). Do not loosen those globally. Give the priming click its own narrow path. Tests: `WindowRoutedPointerDriverTests.swift` with injected `resolveRoute`, `routeIsCurrent`, `makeEvent`, `stampWindowLocation`, `postPublic`, `postSkyLight`, `resolveTransport`, `sleep`, `clickGroupIdentifier`.
- Single left-click: `BackgroundInputDriver.click` (static, ~:1571) does an AX hit-test only, throws `noActionableElementMessage` (~:1546/:1631). Right/double/middle/triple go to `WindowRoutedPointerDriver().click` (~:1608-1618). No injection points, no tests: extract an injectable helper.
- Drag: `RT/MCP/Tools/DragTool.swift:114-137` calls `ExactWindowDrag.swift:84` `dragExactWindow`, then `ExactWindowHeldPointerLifecycle.drag` (~:427). `ExactWindowDragRequest.dispatchedUnitCount = steps + 3`, checked ~:477. Tests: `ExactWindowHeldPointerLifecycleTests.swift` (fake driver, `dragSleeper`, expects 8 units ~:563-585).
- Launch: `ApplicationService+Lifecycle.swift` (~:85 non-activating path goes to `performVerifiedBackgroundLaunchNoOp` ~:276, which refuses a cold launch ~:305; `config.activates` ~:104). `ApplicationServiceProtocol.swift:33` `isSafeBackgroundNoOp`. MCP: `AppTool+Lifecycle.swift:10-34`, `MCPToolContext.swift:1073-1079`. CLI: `AppCommand+Launch.swift:125-135, :212`. `ApplicationService.init` already takes `applicationOpenHandler`, `frontmostProcessIdentifierProvider`, `applicationActivationHandler`, `applicationActiveProvider`, `applicationActivationSleepHandler`. Tests: `ApplicationServiceLifecycleTests.swift` (:552, :568), fixtures `ApplicationServiceLifecycleTestFixtures.swift:23`, `MCPToolExecutionPolicyTests`, `AppToolLifecyclePinningTests`, `MCPAppToolOutcomeTests`.
- Electron accessibility: `ElementDetectionService.inspectReadOnlyElements` (~:324) runs an injected `detachedAXObservationRunner`. The classifier is `WindowRoutedApplicationClassifier.swift:53-62` (`.electron`). Tests: `ElementDetectionServiceDetachedObservationTests`, `WindowRoutedApplicationClassifierTests`.

## Report back (under ~500 words)
Tests added (names) and each red→green observed; files changed; results of the suites rerun (pass counts, failures verbatim); commit hash; anything you could not do or that needs a decision.
