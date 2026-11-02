import AppKit
import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

/// `set_value` on controls whose AXValue is not a plain string or number: date pickers and steppers.
@MainActor
struct ActionInputDriverControlValueTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test
    func `date picker takes a year-month-day string as a date and keeps its time of day`() async throws {
        let element = ActionInputMockAutomationElement(
            role: "AXDateTimeArea",
            value: Self.date(2026, 11, 1, 9, 30) as NSDate,
            isValueSettable: true)

        let result = try await ActionInputDriver().trySetValueForTesting(element: element, value: .string("2027-03-15"))

        #expect(element.setDates == [Self.date(2027, 3, 15, 9, 30)])
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.actionName == AXActionNames.kAXSetValueAction)
        #expect(result.valueVerification?.displayString == "2027-03-15")
        #expect(result.valueVerification?.matches(
            requested: .string("2027-03-15"),
            newValue: "2027-03-15",
            actionName: AXActionNames.kAXSetValueAction) == true)
    }

    @Test(arguments: ["2027-3-5", "2027-02-30", "15/03/2027", "next tuesday"])
    func `date picker refuses unclear date text before writing anything`(text: String) async {
        let element = ActionInputMockAutomationElement(
            role: "AXDateTimeArea",
            value: Self.date(2026, 11, 1) as NSDate,
            isValueSettable: true)

        do {
            _ = try await ActionInputDriver().trySetValueForTesting(element: element, value: .string(text))
            Issue.record("Expected '\(text)' to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(failure.message.contains("2027-03-15"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(element.setDates.isEmpty)
    }
}

struct AXMutationDateReadbackTests {
    @Test
    func `post-write reader returns a date picker's CFDate value`() {
        let element = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        let written = Date(timeIntervalSince1970: 1_805_000_000)
        let observed = DetachedAXMutationReader.readSynchronously(
            request: (
                target: AXMutationObservationTarget(processIdentifier: 4242, processStartIdentity: 99),
                attribute: .value,
                deadline: .now.advanced(by: .seconds(1))),
            processStartIdentity: { 99 },
            readSnapshot: { _ in
                ExactWindowFocusSnapshot(
                    processIdentifier: 4242,
                    windowID: 42,
                    frame: CGRect(x: 150, y: 196, width: 140, height: 26),
                    role: "AXDateTimeArea",
                    subrole: nil,
                    subroleIsReadable: true,
                    identifier: nil,
                    nativeElement: element)
            },
            readAttribute: { name, _ in
                #expect(name == kAXValueAttribute)
                return written as CFDate
            })

        #expect(observed?.dateValue == written)
        #expect(observed?.value == nil)
    }
}
