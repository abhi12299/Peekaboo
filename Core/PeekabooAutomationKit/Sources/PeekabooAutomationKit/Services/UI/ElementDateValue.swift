import Foundation
import PeekabooFoundation

/// A date requested for a date picker's AXValue (a CFDate), parsed from `set_value` text.
///
/// Only unambiguous spellings are accepted, and only when they format back to the same text, so the readback can be
/// compared at the precision the caller asked for:
/// - `yyyy-MM-dd`: the picker's day changes and its time of day is kept;
/// - `yyyy-MM-dd HH:mm` and `yyyy-MM-dd HH:mm:ss`: local time;
/// - `yyyy-MM-ddTHH:mm:ssZ` (optionally with milliseconds) or with an offset such as `+05:30`: an exact instant.
struct ElementDateValue {
    static let acceptedFormatsDescription =
        "a date such as 2027-03-15, a local time such as 2027-03-15 14:30, or an ISO 8601 instant such as " +
        "2027-03-15T14:30:00Z"

    private enum Precision {
        case day
        case minute
        case second
    }

    let text: String
    private let date: Date
    private let precision: Precision
    private let format: String
    private let timeZone: TimeZone

    init(_ value: UIElementValue) throws {
        guard case let .string(raw) = value else {
            throw Self.refusal("Expected \(Self.acceptedFormatsDescription).")
        }
        // Not trimmed: the verified readback is compared with the exact requested text.
        let text = raw
        for candidate in Self.candidates(for: text) {
            let formatter = Self.formatter(candidate.format, timeZone: candidate.timeZone)
            guard let date = formatter.date(from: text), formatter.string(from: date) == text else { continue }
            self.text = text
            self.date = date
            self.precision = candidate.precision
            self.format = candidate.format
            self.timeZone = candidate.timeZone
            return
        }
        throw Self.refusal("Expected \(Self.acceptedFormatsDescription); got '\(raw)'.")
    }

    /// Text that is not a clear date is refused before anything is written.
    private static func refusal(_ message: String) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .invalidRequest,
            message: message,
            hint: "Pass the date as yyyy-MM-dd, for example 2027-03-15.")
    }

    /// The date to write: a day-only request keeps the current value's time of day.
    func resolved(keepingTimeOf current: Date?) -> Date {
        guard self.precision == .day, let current else { return self.date }
        let calendar = Self.calendar(self.timeZone)
        let day = calendar.dateComponents([.year, .month, .day], from: self.date)
        var components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: current)
        components.year = day.year
        components.month = day.month
        components.day = day.day
        return calendar.date(from: components) ?? self.date
    }

    /// The readback spelled at the requested precision; equal to `text` when the picker holds the requested date.
    func describe(_ date: Date) -> String {
        Self.formatter(self.format, timeZone: self.timeZone).string(from: date)
    }

    func matches(_ date: Date) -> Bool {
        self.describe(date) == self.text
    }

    private struct Candidate {
        let format: String
        let precision: Precision
        let timeZone: TimeZone
    }

    private static func candidates(for text: String) -> [Candidate] {
        let local = TimeZone.current
        var candidates = [
            Candidate(format: "yyyy-MM-dd", precision: .day, timeZone: local),
            Candidate(format: "yyyy-MM-dd HH:mm", precision: .minute, timeZone: local),
            Candidate(format: "yyyy-MM-dd HH:mm:ss", precision: .second, timeZone: local),
        ]
        if let zone = self.isoTimeZone(of: text) {
            let suffix = text.hasSuffix("Z") ? "'Z'" : "xxxxx"
            // `see` shows a date picker's value with milliseconds, so that spelling is accepted as well.
            for seconds in ["ss", "ss.SSS"] {
                candidates.append(Candidate(
                    format: "yyyy-MM-dd'T'HH:mm:\(seconds)\(suffix)",
                    precision: .second,
                    timeZone: zone))
            }
        }
        return candidates
    }

    /// The zone an ISO 8601 instant names (`Z` or `±hh:mm`), so the readback is spelled in the same zone.
    private static func isoTimeZone(of text: String) -> TimeZone? {
        guard text.contains("T") else { return nil }
        if text.hasSuffix("Z") {
            return TimeZone(secondsFromGMT: 0)
        }
        let offset = text.suffix(6)
        guard offset.count == 6, let sign = offset.first, sign == "+" || sign == "-",
              offset.dropFirst(3).first == ":",
              let hours = Int(offset.dropFirst().prefix(2)), let minutes = Int(offset.suffix(2)),
              hours <= 23, minutes <= 59
        else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = self.calendar(timeZone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        formatter.dateFormat = format
        return formatter
    }
}
