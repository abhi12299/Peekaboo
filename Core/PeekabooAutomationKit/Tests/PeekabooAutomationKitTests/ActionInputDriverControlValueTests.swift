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

    @Test
    func `date picker accepts the ISO instant that see displays`() async throws {
        let element = ActionInputMockAutomationElement(
            role: "AXDateTimeArea",
            value: Date(timeIntervalSince1970: 1_793_500_000) as NSDate,
            isValueSettable: true)

        let result = try await ActionInputDriver().trySetValueForTesting(
            element: element,
            value: .string("2027-03-14T18:30:00.000Z"))

        #expect(element.setDates == [Date(timeIntervalSince1970: 1_805_049_000)])
        #expect(result.valueVerification?.displayString == "2027-03-14T18:30:00.000Z")
    }

    /// An NSStepper: AXIncrementor whose AXValue is read-only and moves by `step` per AXIncrement/AXDecrement.
    static func stepper(value: Double, min: Double = 1, max: Double = 50, step: Double = 1)
        -> ActionInputMockAutomationElement
    {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXIncrementorRole,
            frame: CGRect(x: 214, y: 152, width: 20, height: 26),
            value: NSNumber(value: value),
            actionNames: ["AXIncrement", "AXDecrement"],
            isValueSettable: false,
            doubleAttributes: ["AXMinValue": min, "AXMaxValue": max])
        element.onPerformedAction = { action, element in
            let current = (element.value as? NSNumber)?.doubleValue ?? 0
            let next = action == "AXIncrement" ? current + step : current - step
            element.value = NSNumber(value: Swift.min(max, Swift.max(min, next)))
        }
        return element
    }

    @Test(arguments: [(1.0, 34, "AXIncrement"), (40.0, 3, "AXDecrement")])
    func `stepper is stepped to the requested value and verified`(
        start: Double,
        target: Int,
        action: String) async throws
    {
        let element = Self.stepper(value: start)

        let result = try await ActionInputDriver().trySetValueForTesting(element: element, value: .int(target))

        #expect((element.value as? NSNumber)?.intValue == target)
        #expect(element.performedActions == Array(repeating: action, count: abs(target - Int(start))))
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.valueVerification?.displayString == String(target))
        #expect(result.valueVerification?.matches(
            requested: .int(target),
            newValue: String(target),
            actionName: result.actionName) == true)
    }

    @Test
    func `stepper validates its snapshot target once, then trusts the per-step identity readback`() async throws {
        let element = Self.stepper(value: 1)
        var validations = 0

        _ = try await ActionInputDriver().trySetValueForTesting(
            element: element,
            value: .int(34),
            beforeMutation: { validations += 1 })

        #expect(element.performedActions.count == 33)
        #expect(validations == 1)
    }

    @Test(arguments: [UIElementValue.int(0), .int(51), .string("many")])
    func `stepper refuses a value it cannot hold before stepping`(value: UIElementValue) async {
        let element = Self.stepper(value: 1)

        do {
            _ = try await ActionInputDriver().trySetValueForTesting(element: element, value: value)
            Issue.record("Expected \(value) to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.refusalReason == .invalidRequest)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(element.attemptedActions.isEmpty)
    }

    @Test
    func `stepper keeps stepping when a step reports an error but the value moved`() async throws {
        let element = Self.stepper(value: 1)
        let onStep = element.onPerformedAction
        element.onPerformedAction = { action, element in
            try onStep?(action, element)
            if element.performedActions.count == 33 {
                throw AccessibilitySystemError(.cannotComplete)
            }
        }

        let result = try await ActionInputDriver().trySetValueForTesting(element: element, value: .int(34))

        #expect((element.value as? NSNumber)?.intValue == 34)
        #expect(result.outcome.state == .confirmedChange)
    }

    @Test
    func `stepper that stops moving is reported as a partial change`() async {
        let element = Self.stepper(value: 1)
        let onStep = element.onPerformedAction
        element.onPerformedAction = { action, element in
            if element.performedActions.count <= 3 {
                try onStep?(action, element)
            }
        }
        await Self.expectPartialStep(element, to: 34, mentioning: "stopped at 4")
        #expect(element.performedActions.count == 4)
    }

    @Test
    func `stepper whose step skips the value is reported as a partial change`() async {
        let element = Self.stepper(value: 1, step: 2)
        await Self.expectPartialStep(element, to: 4, mentioning: "moved past 4 to 5")
        #expect(element.performedActions.count == 2)
    }

    private static func expectPartialStep(
        _ element: ActionInputMockAutomationElement,
        to target: Int,
        mentioning text: String) async
    {
        do {
            _ = try await ActionInputDriver().trySetValueForTesting(element: element, value: .int(target))
            Issue.record("Expected stepping to \(target) to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.message.contains(text))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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
