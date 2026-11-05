import CoreGraphics
import Foundation

/// Human-hand cursor travel: a minimum-jerk primary sub-movement that slightly overshoots, a short
/// corrective sub-movement back onto the target, a gentle sideways bow and a low tremor that settles
/// at both ends. Durations follow Fitts' law. Modelled on agent-desktop's cursor overlay motion.
struct PhantomCursorHandPath {
    static let travelMin: Double = 0.09
    static let travelMax: Double = 0.32

    private static let primarySpan = 0.74
    private static let correctionStart = 0.62
    private static let bowRatio = 0.055
    private static let maxBow = 38.0
    private static let overshoot = 0.035
    private static let tremorPixels = 1.1
    private static let tremorCycles = 7.0

    let start: CGPoint
    let destination: CGPoint
    private let bow: Double
    private let seed: UInt64
    private let pace: Double

    init(start: CGPoint, destination: CGPoint, seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.start = start
        self.destination = destination
        self.seed = seed
        let distance = Double(hypot(destination.x - start.x, destination.y - start.y))
        let side: Double = Self.unitHash(seed, 0x5EED_0001) < 0.5 ? -1 : 1
        let bowFactor = 0.7 + 0.6 * Self.unitHash(seed, 0x5EED_0002)
        self.pace = 0.9 + 0.2 * Self.unitHash(seed, 0x5EED_0003)
        self.bow = side * bowFactor * min(Self.bowRatio * distance, Self.maxBow)
    }

    var distance: Double {
        Double(hypot(self.destination.x - self.start.x, self.destination.y - self.start.y))
    }

    /// Travel time in seconds; zero for moves too small to see.
    var duration: TimeInterval {
        guard self.distance >= 1.5 else { return 0 }
        let fitts = (40 + 70 * log2(self.distance / 40 + 1)) / 1000
        return min(max(fitts * self.pace, Self.travelMin), Self.travelMax)
    }

    func point(at progress: Double) -> CGPoint {
        let t = min(max(progress, 0), 1)
        guard t < 1 else { return self.destination }
        let dx = Double(self.destination.x - self.start.x)
        let dy = Double(self.destination.y - self.start.y)
        let distance = self.distance
        let normal = distance > .ulpOfOne ? (x: -dy / distance, y: dx / distance) : (x: 0.0, y: 0.0)
        let travelled = self.submovements(t)
        let settle = sin(Double.pi * t)
        let sideways = self.bow * sin(Double.pi * pow(t, 0.8))
            + Self.tremorPixels * Self.tremor(self.seed, t) * settle
        return CGPoint(
            x: Double(self.start.x) + dx * travelled + normal.x * sideways,
            y: Double(self.start.y) + dy * travelled + normal.y * sideways)
    }

    private func submovements(_ t: Double) -> Double {
        let reach = 1 + Self.overshoot
        let primary = Self.minimumJerk(min(max(t / Self.primarySpan, 0), 1))
        let correction = Self.minimumJerk(min(max((t - Self.correctionStart) / (1 - Self.correctionStart), 0), 1))
        return reach * primary + (1 - reach) * correction
    }

    static func minimumJerk(_ t: Double) -> Double {
        t * t * t * (10 + t * (-15 + 6 * t))
    }

    private static func tremor(_ seed: UInt64, _ t: Double) -> Double {
        let x = t * self.tremorCycles
        let step = floor(x)
        let fraction = x - step
        let low = self.unitHash(seed, UInt64(step))
        let high = self.unitHash(seed, UInt64(step) + 1)
        let blend = fraction * fraction * (3 - 2 * fraction)
        return (low + (high - low) * blend) * 2 - 1
    }

    private static func unitHash(_ seed: UInt64, _ index: UInt64) -> Double {
        Double(self.mix(seed, index) >> 11) / Double(UInt64(1) << 53)
    }

    private static func mix(_ seed: UInt64, _ index: UInt64) -> UInt64 {
        var hash = seed ^ index &* 0x9E37_79B9_7F4A_7C15
        hash ^= hash >> 33
        hash = hash &* 0xFF51_AFD7_ED55_8CCD
        return hash ^ (hash >> 33)
    }
}
