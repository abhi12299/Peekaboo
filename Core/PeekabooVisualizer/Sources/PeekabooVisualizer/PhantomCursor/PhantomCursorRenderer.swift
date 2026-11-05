import AppKit
import PeekabooFoundation
import QuartzCore

/// Click-through, never-activating overlay panel used for every phantom cursor surface.
final class PhantomCursorPanel: NSPanel {
    init(frame: NSRect, level: NSWindow.Level) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.canHide = false
        self.level = level
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.animationBehavior = .none
        self.title = PhantomCursorEndpoint.windowTitle
        self.setAccessibilityElement(false)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        self.contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var rootLayer: CALayer? { self.contentView?.layer }
}

/// Draws one agent cursor in agent-desktop's style: an accent dart with a dark rim, a two-ring click
/// ripple and a brief outline around the clicked element. It never moves or replaces the real pointer.
///
/// Resource use: a frame timer runs only while the cursor travels, a 10 Hz proximity check only while it
/// is visible, and nothing at all once it has rested.
@MainActor
final class PhantomCursorRenderer {
    enum Metrics {
        static let stage: CGFloat = 72
        /// Dart tip inside the stage window, AppKit (bottom-left) coordinates.
        static let tip = CGPoint(x: 20, y: 52)
        static let rippleSize: CGFloat = 108
        static let highlightPad: CGFloat = 5
        static let highlightBleed: CGFloat = 24
        static let highlightSeconds: TimeInterval = 0.9
        static let restAfter: TimeInterval = 6
        static let proximityRadius: CGFloat = 56
        static let labelOffset = CGPoint(x: 20, y: 30)
        static let labelHeight: CGFloat = 24
        static let labelPadding: CGFloat = 10
        static let labelMargin: CGFloat = 8
    }

    enum Palette {
        static let accent = NSColor(srgbRed: 0.26, green: 0.60, blue: 1.0, alpha: 1)
        static let rim = NSColor(srgbRed: 0.067, green: 0.075, blue: 0.094, alpha: 1)
    }

    private let cursorPanel: PhantomCursorPanel
    private let pointer: CALayer
    private let ripplePanel: PhantomCursorPanel
    private var highlightPanel: PhantomCursorPanel?
    private var highlightBorder: CALayer?
    private var labelPanel: PhantomCursorPanel?
    private var labelText: NSTextField?
    private var labelPill: CALayer?
    private var labelSize: CGSize = .zero

    /// Current tip position in global display coordinates (top-left origin).
    private var position: CGPoint?
    private var isShowing = false
    private var pendingTarget: CGRect?
    private var restWork: DispatchWorkItem?
    private var highlightWork: DispatchWorkItem?
    private var proximityTimer: Timer?

    private var motion: Motion?
    private var frameTimer: Timer?

    private(set) var lastActivity = Date()

    private struct Motion {
        let path: PhantomCursorHandPath
        let startedAt: CFTimeInterval
        let duration: TimeInterval
        let completion: (() -> Void)?
    }

    init() {
        let effectLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        let cursorLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        self.cursorPanel = PhantomCursorPanel(
            frame: NSRect(x: 0, y: 0, width: Metrics.stage, height: Metrics.stage),
            level: cursorLevel)
        self.pointer = Self.makePointer()
        self.cursorPanel.rootLayer?.addSublayer(self.pointer)
        self.ripplePanel = PhantomCursorPanel(
            frame: NSRect(x: 0, y: 0, width: Metrics.rippleSize, height: Metrics.rippleSize),
            level: effectLevel)
        Self.installRipple(in: self.ripplePanel)
    }

    // MARK: - Requests

    func handle(_ request: PhantomCursorRequest, reply: @escaping @Sendable (PhantomCursorReply) -> Void) {
        self.lastActivity = Date()
        switch request.kind {
        case .ping:
            reply(PhantomCursorReply(ok: true))
        case .hide:
            self.hide()
            reply(PhantomCursorReply(ok: true))
        case .move:
            guard let point = request.point else {
                reply(PhantomCursorReply(ok: false, detail: "missing point"))
                return
            }
            self.pendingTarget = request.target?.cgRect
            self.setLabel(request.label)
            self.travel(to: point) { reply(PhantomCursorReply(ok: true)) }
        case .click:
            guard let point = request.point else {
                reply(PhantomCursorReply(ok: false, detail: "missing point"))
                return
            }
            reply(PhantomCursorReply(ok: true))
            let target = request.target?.cgRect ?? self.pendingTarget.flatMap { $0.contains(point) ? $0 : nil }
            self.pendingTarget = nil
            self.setLabel(request.label)
            let kind = request.click ?? .single
            if let position, self.isShowing, hypot(position.x - point.x, position.y - point.y) < 2 {
                self.playClick(at: point, kind: kind, target: target)
            } else {
                self.travel(to: point) { [weak self] in
                    self?.playClick(at: point, kind: kind, target: target)
                }
            }
        }
        self.scheduleRest()
    }

    // MARK: - Travel

    private func travel(to destination: CGPoint, completion: (() -> Void)?) {
        // A newer instruction supersedes an unfinished one; acknowledge it so its caller is not held up.
        if let previous = self.motion {
            self.motion = nil
            previous.completion?()
        }
        let start = self.currentPoint() ?? CGPoint(x: destination.x + 48, y: destination.y + 64)
        self.show(at: start)
        let path = PhantomCursorHandPath(start: start, destination: destination)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduceMotion ? 0 : path.duration
        guard duration > 0 else {
            self.place(at: destination)
            completion?()
            return
        }
        self.motion = Motion(
            path: path,
            startedAt: CACurrentMediaTime(),
            duration: duration,
            completion: completion)
        self.startFrameTimer()
    }

    private func startFrameTimer() {
        guard self.frameTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.frameTimer = timer
    }

    private func step() {
        guard let motion = self.motion else {
            self.frameTimer?.invalidate()
            self.frameTimer = nil
            return
        }
        let progress = (CACurrentMediaTime() - motion.startedAt) / motion.duration
        self.place(at: motion.path.point(at: progress))
        if progress >= 1 {
            self.motion = nil
            self.frameTimer?.invalidate()
            self.frameTimer = nil
            motion.completion?()
        }
    }

    /// The tip's current on-screen location, mid-flight included.
    private func currentPoint() -> CGPoint? {
        if let motion = self.motion {
            let progress = (CACurrentMediaTime() - motion.startedAt) / motion.duration
            return motion.path.point(at: progress)
        }
        return self.position
    }

    private func place(at point: CGPoint) {
        self.position = point
        let mainHeight = Self.mainDisplayHeight
        self.cursorPanel.setFrameOrigin(NSPoint(
            x: point.x - Metrics.tip.x,
            y: mainHeight - point.y - Metrics.tip.y))
        self.placeLabel(at: point, mainHeight: mainHeight)
    }

    // MARK: - Visibility

    private func show(at point: CGPoint) {
        self.restWork?.cancel()
        guard !self.isShowing else { return }
        self.isShowing = true
        self.place(at: point)
        self.cursorPanel.alphaValue = 0
        self.cursorPanel.orderFrontRegardless()
        if self.labelSize != .zero { self.labelPanel?.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.cursorPanel.animator().alphaValue = 1
            self.labelPanel?.animator().alphaValue = 1
        }
        self.startProximityTimer()
    }

    private func scheduleRest() {
        self.restWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rest() }
        }
        self.restWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.restAfter, execute: work)
    }

    /// Fades out after a quiet period; the last position is kept so the next move starts from there.
    private func rest() {
        guard self.isShowing, self.motion == nil else { return }
        self.isShowing = false
        self.stopProximityTimer()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            self.cursorPanel.animator().alphaValue = 0
            self.labelPanel?.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                guard !self.isShowing else { return }
                self.cursorPanel.orderOut(nil)
                self.labelPanel?.orderOut(nil)
            }
        }
    }

    func hide() {
        if let motion = self.motion {
            self.motion = nil
            motion.completion?()
        }
        self.frameTimer?.invalidate()
        self.frameTimer = nil
        self.restWork?.cancel()
        self.stopProximityTimer()
        self.isShowing = false
        self.cursorPanel.orderOut(nil)
        self.labelPanel?.orderOut(nil)
        self.ripplePanel.orderOut(nil)
        self.highlightPanel?.orderOut(nil)
    }

    /// Fades the cursor while the user's real pointer is close, so it never hides what they aim at.
    private func startProximityTimer() {
        guard self.proximityTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProximity() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.proximityTimer = timer
    }

    private func stopProximityTimer() {
        self.proximityTimer?.invalidate()
        self.proximityTimer = nil
    }

    private func updateProximity() {
        guard self.isShowing, let position = self.position else { return }
        let mouse = NSEvent.mouseLocation
        let mouseGlobal = CGPoint(x: mouse.x, y: Self.mainDisplayHeight - mouse.y)
        let near = hypot(mouseGlobal.x - position.x, mouseGlobal.y - position.y) < Metrics.proximityRadius
        let alpha: CGFloat = near ? 0.18 : 1
        guard abs(self.cursorPanel.alphaValue - alpha) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.cursorPanel.animator().alphaValue = alpha
            self.labelPanel?.animator().alphaValue = alpha
        }
    }

    // MARK: - Click effects

    private func playClick(at point: CGPoint, kind: PhantomCursorRequest.Click, target: CGRect?) {
        let mainHeight = Self.mainDisplayHeight
        self.ripplePanel.setFrameOrigin(NSPoint(
            x: point.x - Metrics.rippleSize / 2,
            y: mainHeight - point.y - Metrics.rippleSize / 2))
        self.ripplePanel.orderFrontRegardless()
        self.playRipple()
        self.pressPointer()
        if kind == .double {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                MainActor.assumeIsolated {
                    self?.playRipple()
                    self?.pressPointer()
                }
            }
        }
        if let target, target.width >= 4, target.height >= 4 {
            self.showHighlight(target, mainHeight: mainHeight)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.ripplePanel.orderOut(nil) }
        }
    }

    private func playRipple() {
        guard let layers = self.ripplePanel.rootLayer?.sublayers else { return }
        for (index, layer) in layers.enumerated() {
            guard let ring = layer as? CAShapeLayer else { continue }
            ring.removeAllAnimations()
            ring.fillColor = index == 0 ? Palette.accent.cgColor : NSColor.clear.cgColor
            ring.strokeColor = Palette.accent.cgColor
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = index == 0 ? [0.0, 0.42, 0.0] : [0.0, 0.9, 0.0]
            opacity.keyTimes = [0.0, 0.18, 1.0]
            let spread = CABasicAnimation(keyPath: "transform.scale")
            spread.fromValue = index == 0 ? 0.22 : 0.04
            spread.toValue = index == 0 ? 1.12 : 1.0
            let group = CAAnimationGroup()
            group.animations = [opacity, spread]
            group.duration = 0.3
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "phantom-ripple")
        }
    }

    private func pressPointer() {
        let press = CAKeyframeAnimation(keyPath: "transform.scale")
        press.values = [1.0, 0.86, 1.0]
        press.keyTimes = [0.0, 0.35, 1.0]
        press.duration = 0.2
        press.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.pointer.add(press, forKey: "phantom-press")
    }

    private func showHighlight(_ target: CGRect, mainHeight: CGFloat) {
        let frame = NSRect(
            x: target.minX - Metrics.highlightPad,
            y: mainHeight - target.maxY - Metrics.highlightPad,
            width: target.width + Metrics.highlightPad * 2,
            height: target.height + Metrics.highlightPad * 2)
        let windowFrame = frame.insetBy(dx: -Metrics.highlightBleed, dy: -Metrics.highlightBleed)
        if self.highlightPanel == nil {
            let panel = PhantomCursorPanel(
                frame: windowFrame,
                level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1))
            let border = CALayer()
            border.borderWidth = 2.5
            border.cornerRadius = 8
            border.opacity = 0
            border.borderColor = Palette.accent.cgColor
            border.backgroundColor = Palette.accent.withAlphaComponent(0.10).cgColor
            border.shadowColor = Palette.accent.cgColor
            border.shadowOpacity = 0.5
            border.shadowRadius = 10
            border.shadowOffset = .zero
            Self.freeze(border)
            panel.rootLayer?.addSublayer(border)
            self.highlightPanel = panel
            self.highlightBorder = border
        }
        guard let panel = self.highlightPanel, let border = self.highlightBorder else { return }
        panel.setFrame(windowFrame, display: false)
        border.frame = CGRect(
            x: Metrics.highlightBleed,
            y: Metrics.highlightBleed,
            width: frame.width,
            height: frame.height)
        border.removeAllAnimations()
        border.add(
            Self.hold("opacity", [0.0, 1.0, 1.0, 0.0], [0.0, 0.04, 0.55, 1.0], Metrics.highlightSeconds),
            forKey: "phantom-highlight-fade")
        border.add(
            Self.hold("transform.scale", [1.08, 0.99, 1.0, 1.0], [0.0, 0.12, 0.22, 1.0], Metrics.highlightSeconds),
            forKey: "phantom-highlight-pop")
        panel.orderFrontRegardless()
        self.highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.highlightPanel?.orderOut(nil) }
        }
        self.highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.highlightSeconds + 0.05, execute: work)
    }

    // MARK: - Label

    private func setLabel(_ label: String?) {
        let text = label ?? ""
        guard text != (self.labelText?.stringValue ?? "") else { return }
        guard !text.isEmpty else {
            self.labelSize = .zero
            self.labelText?.stringValue = ""
            self.labelPanel?.orderOut(nil)
            return
        }
        if self.labelPanel == nil {
            let panel = PhantomCursorPanel(
                frame: NSRect(x: 0, y: 0, width: 10, height: 10),
                level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2))
            let pill = CALayer()
            pill.backgroundColor = NSColor.black.cgColor
            pill.shadowColor = NSColor.black.cgColor
            pill.shadowOpacity = 0.31
            pill.shadowRadius = 2.5
            pill.shadowOffset = CGSize(width: 0, height: -2)
            Self.freeze(pill)
            panel.rootLayer?.addSublayer(pill)
            let field = NSTextField(labelWithString: "")
            field.textColor = .white
            field.font = .systemFont(ofSize: 12.5, weight: .medium)
            field.alignment = .center
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            panel.contentView?.addSubview(field)
            self.labelPanel = panel
            self.labelPill = pill
            self.labelText = field
        }
        guard let panel = self.labelPanel, let pill = self.labelPill, let field = self.labelText else { return }
        field.stringValue = text
        let font = field.font ?? .systemFont(ofSize: 12.5, weight: .medium)
        let textWidth = min(ceil((text as NSString).size(withAttributes: [.font: font]).width), 340)
        let size = CGSize(width: textWidth + Metrics.labelPadding * 2, height: Metrics.labelHeight)
        self.labelSize = size
        let margin = Metrics.labelMargin
        panel.setContentSize(NSSize(width: size.width + margin * 2, height: size.height + margin * 2))
        pill.frame = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        pill.cornerRadius = size.height / 2
        let line = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 100)).height ?? 16)
        field.frame = NSRect(
            x: margin + Metrics.labelPadding - 6,
            y: margin + (size.height - line) / 2,
            width: textWidth + 12,
            height: line)
        if let position { self.placeLabel(at: position, mainHeight: Self.mainDisplayHeight) }
        if self.isShowing { panel.orderFrontRegardless() }
    }

    private func placeLabel(at point: CGPoint, mainHeight: CGFloat) {
        guard let panel = self.labelPanel, self.labelSize != .zero else { return }
        let margin = Metrics.labelMargin
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: point.x, y: mainHeight - point.y))
        }?.visibleFrame
        var x = point.x + Metrics.labelOffset.x
        var top = point.y + Metrics.labelOffset.y
        if let screen {
            if x + self.labelSize.width > screen.maxX { x = point.x - self.labelSize.width - Metrics.labelOffset.x }
            if mainHeight - top - self.labelSize.height < screen.minY {
                top = point.y - self.labelSize.height - Metrics.labelOffset.y
            }
        }
        panel.setFrameOrigin(NSPoint(x: x - margin, y: mainHeight - top - self.labelSize.height - margin))
    }

    // MARK: - Drawing

    private static var mainDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// The dart: a four-point arrowhead whose tip is the hotspot, filled with the accent over a dark rim.
    private static func makePointer() -> CALayer {
        let box = CGSize(width: 32, height: 40)
        let pointer = CALayer()
        pointer.bounds = CGRect(origin: .zero, size: box)
        pointer.anchorPoint = CGPoint(x: 1 / box.width, y: 35 / box.height)
        pointer.position = Metrics.tip
        self.freeze(pointer)

        let rim = self.dartLayer()
        rim.lineWidth = 6.5
        rim.shadowOpacity = 0.34
        rim.fillColor = Palette.rim.cgColor
        rim.strokeColor = Palette.rim.cgColor
        let body = self.dartLayer()
        body.fillColor = Palette.accent.cgColor
        body.strokeColor = Palette.accent.cgColor
        pointer.addSublayer(rim)
        pointer.addSublayer(body)
        return pointer
    }

    private static func dartLayer() -> CAShapeLayer {
        let points = [
            CGPoint(x: 1.0, y: 35.0),
            CGPoint(x: 29.6, y: 17.5),
            CGPoint(x: 12.7, y: 16.3),
            CGPoint(x: 4.2, y: 1.6),
        ]
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        let layer = CAShapeLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 32, height: 40)
        layer.path = path
        layer.lineWidth = 3
        layer.lineJoin = .round
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 2.5, height: -3)
        self.freeze(layer)
        return layer
    }

    private static func installRipple(in panel: PhantomCursorPanel) {
        let size = Metrics.rippleSize
        func ring(radius: CGFloat, glow: Bool) -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.position = CGPoint(x: size / 2, y: size / 2)
            layer.path = CGPath(
                ellipseIn: CGRect(x: size / 2 - radius, y: size / 2 - radius, width: radius * 2, height: radius * 2),
                transform: nil)
            layer.fillColor = NSColor.clear.cgColor
            layer.strokeColor = NSColor.clear.cgColor
            layer.opacity = 0
            if glow {
                layer.shadowColor = Palette.accent.cgColor
                layer.shadowOffset = .zero
                layer.shadowRadius = 14
                layer.shadowOpacity = 1
            }
            self.freeze(layer)
            return layer
        }
        panel.rootLayer?.addSublayer(ring(radius: 19, glow: true))
        panel.rootLayer?.addSublayer(ring(radius: size / 2 - 4, glow: false))
        panel.rootLayer?.addSublayer(ring(radius: size / 2 - 4, glow: false))
    }

    private static func freeze(_ layer: CALayer) {
        layer.actions = [
            "transform": NSNull(),
            "opacity": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "hidden": NSNull(),
            "frame": NSNull(),
        ]
    }

    private static func hold(
        _ keyPath: String,
        _ values: [Double],
        _ times: [NSNumber],
        _ seconds: TimeInterval) -> CAKeyframeAnimation
    {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = seconds
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}
