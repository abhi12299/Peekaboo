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
}
