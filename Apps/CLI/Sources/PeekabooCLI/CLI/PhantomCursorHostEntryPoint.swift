import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import PeekabooVisualizer

/// Runs the hidden phantom cursor renderer when the binary was launched as
/// `peekaboo __phantom-cursor-host <owner-pid>`; returns otherwise. Checked before any CLI setup so the
/// renderer stays a lightweight, Dock-less AppKit process.
@MainActor
public func runPhantomCursorHostIfRequested(_ arguments: [String] = CommandLine.arguments) {
    guard arguments.count >= 2, arguments[1] == PhantomCursorEndpoint.hostArgument else { return }
    // The renderer is a `peekaboo` process but never uses ScreenCaptureKit; register it as coordinated so
    // capture ownership checks in the MCP servers do not treat it as an unknown capture host.
    try? ScreenCaptureKitOwnerLease.registerCurrentProcessCapability()
    PhantomCursorHost.run(arguments: Array(arguments.dropFirst(2)))
}
