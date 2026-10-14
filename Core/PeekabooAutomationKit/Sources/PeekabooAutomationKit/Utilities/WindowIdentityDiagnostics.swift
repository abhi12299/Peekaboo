import CoreGraphics
import Foundation

/// One-line descriptions of window identity values for refusal messages and debug logs.
///
/// Fractions are kept (no rounding) so a sub-point difference stays visible.
public enum WindowIdentityDiagnostics {
    /// `x,y w×h`, e.g. `152,73 656×422`.
    public static func bounds(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return "\(self.number(rect.origin.x)),\(self.number(rect.origin.y)) " +
            "\(self.number(rect.width))×\(self.number(rect.height))"
    }

    /// Lists only the fields that differ, as `name: <label> a, now b`, joined with `; `.
    static func differences(
        _ fields: [(name: String, expected: String, actual: String)],
        expectedLabel: String) -> String
    {
        fields.filter { $0.expected != $0.actual }
            .map { "\($0.name): \(expectedLabel) \($0.expected), now \($0.actual)" }
            .joined(separator: "; ")
    }

    private static func number(_ value: CGFloat) -> String {
        let double = Double(value)
        if double == double.rounded(), abs(double) < 1e15 {
            return String(Int64(double))
        }
        return String(double)
    }
}
