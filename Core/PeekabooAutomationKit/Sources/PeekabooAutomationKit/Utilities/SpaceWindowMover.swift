import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Moves a window to a Space in one window-server operation.
///
/// Since macOS 14.5 the window server ignores `CGSMoveWindowsToManagedSpace` and `CGSAddWindowsToSpaces` for
/// windows another process owns: the calls return without error and nothing moves. SkyLight's bridged
/// `SLSBridgedMoveWindowsToManagedSpaceOperation` still moves them, without switching the user's Space or
/// activating the app (checked on macOS 27 against another app's window, to the current Space and away from it).
/// The bridged add and remove operations don't work for this, so only the atomic move is used. When the class is
/// missing, the plain call is used; it still moves the caller's own windows and works on older systems.
/// Callers verify the result from the window's Space memberships; macOS applies the move asynchronously.
enum SpaceWindowMover {
    private static let bridgedMoveClassName = "SLSBridgedMoveWindowsToManagedSpaceOperation"
    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    static func move(windowID: CGWindowID, to spaceID: CGSSpaceID, connection: CGSConnectionID) {
        let windows = [NSNumber(value: windowID)] as NSArray
        guard self.performBridgedMove(windows: windows, spaceID: spaceID) else {
            CGSMoveWindowsToManagedSpace(connection, windows as CFArray, spaceID)
            return
        }
    }

    /// Whether this system has the bridged move operation.
    static var isBridgedMoveAvailable: Bool {
        self.bridgedMoveClass() != nil
    }

    private static func bridgedMoveClass() -> AnyClass? {
        guard self.isSkyLightLoaded else { return nil }
        return NSClassFromString(self.bridgedMoveClassName)
    }

    /// SkyLight is already loaded through CoreGraphics; opening it again only makes that explicit.
    private static let isSkyLightLoaded: Bool = dlopen(SpaceWindowMover.skyLightPath, RTLD_LAZY | RTLD_LOCAL) != nil

    private static func performBridgedMove(windows: NSArray, spaceID: CGSSpaceID) -> Bool {
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
        let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let operationClass = self.bridgedMoveClass(),
              let metaclass = object_getClass(operationClass),
              class_respondsToSelector(metaclass, allocSelector),
              class_respondsToSelector(operationClass, initSelector),
              class_respondsToSelector(operationClass, performSelector),
              let allocIMP = class_getMethodImplementation(metaclass, allocSelector),
              let initIMP = class_getMethodImplementation(operationClass, initSelector),
              let performIMP = class_getMethodImplementation(operationClass, performSelector)
        else {
            return false
        }

        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        typealias Initialize = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
        typealias Perform = @convention(c) (AnyObject, Selector) -> Void

        guard let allocated = unsafeBitCast(allocIMP, to: Alloc.self)(operationClass, allocSelector) else {
            return false
        }
        // `init` consumes the allocated reference and returns the owned operation.
        guard let operation = unsafeBitCast(initIMP, to: Initialize.self)(
            allocated.takeUnretainedValue(),
            initSelector,
            windows,
            spaceID)?.takeRetainedValue()
        else {
            return false
        }
        unsafeBitCast(performIMP, to: Perform.self)(operation, performSelector)
        return true
    }
}
