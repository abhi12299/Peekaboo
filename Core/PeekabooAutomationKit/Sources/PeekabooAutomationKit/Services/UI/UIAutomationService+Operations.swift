import CoreGraphics
import Foundation
import PeekabooFoundation

extension UIAutomationService {
    // MARK: - Element Detection

    /// Reads the target's Accessibility element map. An explicit snapshot ID also stores the result.
    public func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        self.logger.debug("Delegating element detection to ElementDetectionService")
        let result = try await self.elementDetectionService.detectElements(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext)
        if let snapshotId {
            try await self.snapshotManager.storeDetectionResult(snapshotId: snapshotId, result: result)
        }
        return result
    }

    public func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        self.logger.debug("Delegating accessibility tree inspection to ElementDetectionService")
        return try await self.elementDetectionService.inspectElements(
            snapshotId: nil,
            windowContext: windowContext)
    }

    // MARK: - Click Operations

    public func focusExactElementWithOutcome(
        target: ClickTarget,
        snapshotId: String,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<FocusedElementIdentity>
    {
        try await self.clickService.focusExactElementWithOutcome(
            target: target,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    /**
     * Perform precise click operations on UI elements or screen coordinates.
     *
     * This method handles all types of mouse click interactions with intelligent targeting,
     * accessibility API integration, and visual feedback. It supports both element-based
     * and coordinate-based clicking with multiple click types.
     *
     * - Parameters:
     *   - target: The click target (element ID, query, or coordinates)
     *   - clickType: Type of click to perform (single, double, right-click, etc.)
     *   - snapshotId: Optional snapshot ID for element resolution and state tracking
     * - Throws: `PeekabooError` if the target cannot be found or click fails
     *
     * ## Click Targeting
     * Three targeting modes are supported:
     * - **Element ID**: Click on a specific element using its opaque detected ID
     * - **Query**: Find element by text content or accessibility label
     * - **Coordinates**: Click at exact screen coordinates
     *
     * ## Click Types
     * - `.single`: Standard left click
     * - `.double`: Double-click for opening/selecting
     * - `.right`: Right-click for context menus
     * - `.middle`: Middle-click (wheel button)
     *
     * ## Visual Feedback
     * When visualizer is connected, shows:
     * - Animated cursor gliding to the click location
     * - Visible single, double, or right-button press
     * - Subtle click ring centered on the cursor hotspot
     *
     * ## Performance
     * - **Element Resolution**: 10-50ms for cached elements
     * - **Accessibility Lookup**: 50-200ms for query-based targeting
     * - **Click Execution**: 5-20ms for coordinate-based clicks
     *
     * ## Example
     * ```swift
     * // Click on detected element
     * try await automation.click(
     *     target: .elementId(detectedElement.id),
     *     clickType: .single,
     *     snapshotId: "ps1_0123456789abcdef0123456789abcdef"
     * )
     *
     * // Click by searching for text
     * try await automation.click(
     *     target: .query("Submit"),
     *     clickType: .single,
     *     snapshotId: "ps1_0123456789abcdef0123456789abcdef"
     * )
     *
     * // Click at specific coordinates
     * try await automation.click(
     *     target: .coordinates(CGPoint(x: 100, y: 200)),
     *     clickType: .right,
     *     snapshotId: nil
     * )
     * ```
     *
     * - Important: Requires Accessibility permission for element-based clicking
     * - Note: Visual feedback is automatically shown if visualizer is connected
     */
    public func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        self.logger.debug("Delegating click to ClickService")
        var fallbackPoint: CGPoint?
        var visualizerTarget: VisualizerTargetWindow?
        let result = try await self.normalizingSnapshotErrors {
            try await self.clickService.clickWithLanePreparation(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                lanePreparation: {
                    fallbackPoint = await self.getClickPoint(for: target, snapshotId: snapshotId)
                    visualizerTarget = await self.visualizerTargetWindow(snapshotId: snapshotId)
                },
                laneCompletion: { result in
                    await self.visualizeClick(
                        target: target,
                        actionAnchor: result.anchorPoint,
                        clickType: clickType,
                        snapshotId: snapshotId,
                        targetProcessIdentifier: nil,
                        fallbackPoint: fallbackPoint,
                        visualizerTarget: visualizerTarget)
                })
        }
        return UIAutomationActionResult(payload: (), outcome: result.outcome)
            .withForegroundHandBack(result.foregroundHandBack)
            .withTargetWindowChange(result.targetWindowChange)
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        self.logger.debug("Delegating background click to ClickService")
        let automationTarget: UIAutomationTarget = try .process(UIAutomationTarget.Process(
            processIdentifier: targetProcessIdentifier))
        await self.travelPhantomCursor(to: target, snapshotId: snapshotId)
        let result = try await self.normalizingSnapshotErrors {
            try await self.clickService.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                automationTarget: automationTarget)
        }

        await self.visualizeClick(
            target: target,
            actionAnchor: result.anchorPoint,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)

        return UIAutomationActionResult(payload: (), outcome: result.outcome)
            .withForegroundHandBack(result.foregroundHandBack)
            .withTargetWindowChange(result.targetWindowChange)
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws
    {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity,
            allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity,
            allowsAccessibilityValueDelivery: true)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIAutomationActionResult<Void>
    {
        self.logger.debug("Delegating generation-pinned background click to ClickService")
        let automationTarget: UIAutomationTarget = try .process(UIAutomationTarget.Process(
            processIdentifier: expectedProcessIdentity.processIdentifier,
            identity: expectedProcessIdentity))
        await self.travelPhantomCursor(to: target, snapshotId: snapshotId)
        let result = try await self.normalizingSnapshotErrors {
            try await self.clickService.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                automationTarget: automationTarget,
                validatesProcessIdentity: true,
                allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
        }

        await self.visualizeClick(
            target: target,
            actionAnchor: result.anchorPoint,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier)

        return try UIAutomationActionResult(
            payload: (),
            outcome: result.outcome,
            targetIdentity: DesktopTargetIdentity(processIdentity: expectedProcessIdentity))
            .withForegroundHandBack(result.foregroundHandBack)
            .withTargetWindowChange(result.targetWindowChange)
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        windowEvidence: ExactWindowClickEvidence,
        allowsAccessibilityValueDelivery: Bool) async throws
    {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            windowEvidence: windowEvidence,
            allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            windowEvidence: ExactWindowClickEvidence(identity: expectedWindowIdentity, bounds: expectedWindowBounds),
            allowsAccessibilityValueDelivery: true)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        windowEvidence: ExactWindowClickEvidence,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIAutomationActionResult<Void>
    {
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: windowEvidence.identity,
            bounds: windowEvidence.bounds)
        let automationTarget: UIAutomationTarget = .exactWindow(exactWindow)
        self.logger.debug("Delegating exact-window background click to ClickService")
        await self.travelPhantomCursor(to: target, snapshotId: snapshotId)
        let result = try await self.normalizingSnapshotErrors {
            try await self.clickService.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                automationTarget: automationTarget,
                validatesProcessIdentity: true,
                allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
        }

        await self.visualizeClick(
            target: target,
            actionAnchor: result.anchorPoint,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: windowEvidence.identity.ownerProcessIdentifier)

        return UIAutomationActionResult(
            payload: (),
            outcome: result.outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow))
            .withForegroundHandBack(result.foregroundHandBack)
            .withTargetWindowChange(result.targetWindowChange)
    }

    /// Background delivery must remain invisible to the foreground user. Visualizer windows are
    /// desktop-global, so only untargeted/foreground clicks may emit click feedback.
    func visualizeClick(
        target: ClickTarget,
        actionAnchor: CGPoint?,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        fallbackPoint: CGPoint? = nil,
        visualizerTarget: VisualizerTargetWindow? = nil) async
    {
        if targetProcessIdentifier != nil {
            // Opt-in phantom cursor: background delivery never moves the real pointer, so the agent cursor
            // (already travelled there before dispatch) plays the click effect at the delivered point.
            if let clickPoint = Self.visualFeedbackPoint(actionAnchor: actionAnchor, fallbackPoint: fallbackPoint) {
                await BackgroundPhantomCursor.click(at: clickPoint, type: clickType)
            }
            return
        }
        // Foreground input drives the real pointer; keep the phantom cursor out of its way.
        await BackgroundPhantomCursor.hide()
        if let clickPoint = Self.visualFeedbackPoint(actionAnchor: actionAnchor, fallbackPoint: fallbackPoint) {
            _ = await self.feedbackClient.showClickFeedback(
                at: clickPoint,
                type: clickType,
                target: visualizerTarget)
        }
    }

    func normalizingSnapshotErrors<T>(
        _ operation: () async throws -> T) async throws -> T
    {
        do {
            return try await operation()
        } catch let error as ActionInputError where error == .staleElement {
            throw PeekabooError.snapshotStale("target element is no longer available")
        }
    }

    /// Moves the phantom cursor onto the click target before a background click is dispatched, so the picture
    /// and the real effect stay in step. Query targets resolve inside the click service and only get the
    /// post-dispatch effect.
    func travelPhantomCursor(to target: ClickTarget, snapshotId: String?) async {
        guard BackgroundPhantomCursor.isEnabled else { return }
        switch target {
        case let .coordinates(point):
            await BackgroundPhantomCursor.travel(to: point, target: nil)
        case let .elementId(id):
            guard let snapshotId,
                  let result = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
                  let element = result.elements.findById(id)
            else { return }
            let bounds = element.bounds
            await BackgroundPhantomCursor.travel(to: CGPoint(x: bounds.midX, y: bounds.midY), target: bounds)
        case .query:
            return
        }
    }

    private func getClickPoint(for target: ClickTarget, snapshotId: String?) async -> CGPoint? {
        switch target {
        case let .coordinates(point):
            return point
        case let .elementId(id):
            if let snapshotId,
               let result = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId),
               let element = result.elements.findById(id)
            {
                return CGPoint(x: element.bounds.midX, y: element.bounds.midY)
            }
        case .query:
            // For queries, we don't have easy access to the clicked element's position
            // The click service would need to expose this information
            return nil
        }
        return nil
    }

    nonisolated static func visualFeedbackPoint(actionAnchor: CGPoint?, fallbackPoint: CGPoint?) -> CGPoint? {
        actionAnchor ?? fallbackPoint
    }
}
