import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct WindowCloseSheetOutcomeTests {
    @Test
    func `close that left a sheet on the window says so and points at the dialog tool`() {
        let failure = WindowManagementActionOutcome.closeRemained(dispatchCount: 1, sheetAttached: true)

        #expect(failure.outcome.state == .suspectedNoop)
        #expect(failure.message.contains("sheet opened on the window"))
        #expect(failure.hint?.contains("dialog tool") == true)
    }

    @Test
    func `a sheet is found through AXSheets or a child with the sheet role`() {
        let roles = ["button": "AXButton", "sheet": "AXSheet", "toolbar": "AXToolbar"]

        #expect(windowHasAttachedSheet(sheets: ["sheet"], children: nil, role: { roles[$0] }))
        #expect(windowHasAttachedSheet(sheets: [], children: ["button", "sheet"], role: { roles[$0] }))
        #expect(!windowHasAttachedSheet(sheets: nil, children: ["button", "toolbar"], role: { roles[$0] }))
        #expect(!windowHasAttachedSheet(sheets: nil, children: nil, role: { roles[$0] }))
    }
}
