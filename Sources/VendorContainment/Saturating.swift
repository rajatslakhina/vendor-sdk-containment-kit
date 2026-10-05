import Foundation

/// Arithmetic that clamps instead of trapping.
///
/// Every counter in this package (strikes, trips, sequence numbers, dropped
/// counts) goes through here, so no input reachable from the public API can
/// overflow-trap. Ceilings are derived from `Int.max` / `UInt64.max`, never a
/// hard-coded 64-bit literal (`Int` is 32-bit on watchOS).
public enum Saturating {
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? Int.max : Int.min
    }

    public static func increment(_ a: Int) -> Int { add(a, 1) }

    public static func increment(_ a: UInt64) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(1)
        return overflow ? UInt64.max : result
    }

    /// Doubles a cooldown, capped at `cap`. Never returns NaN or infinity:
    /// a non-finite or non-positive `cap` gives 0; NaN or ±infinite `seconds`
    /// gives `cap`; zero or negative finite `seconds` gives 0.
    public static func doubled(_ seconds: TimeInterval, cap: TimeInterval) -> TimeInterval {
        guard cap.isFinite, cap > 0 else { return 0 }
        guard seconds.isFinite else { return cap }
        guard seconds > 0 else { return 0 }
        return seconds >= cap / 2 ? cap : seconds * 2
    }

    /// Converts seconds to nanoseconds for `Task.sleep` without trapping on
    /// NaN, infinity, negatives, or values beyond `UInt64` range.
    public static func nanoseconds(fromSeconds seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let ns = seconds * 1_000_000_000
        // Double(UInt64.max) rounds up to 2^64, which is *not* representable,
        // so compare with >= and clamp before converting.
        guard ns < Double(UInt64.max) else { return UInt64.max }
        return UInt64(ns)
    }
}
