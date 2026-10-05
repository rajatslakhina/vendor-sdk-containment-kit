import Foundation

/// 64-bit FNV-1a over UTF-8 bytes.
///
/// Rollout buckets must be identical on every launch, every device, and every
/// OS version. Swift's `Hasher` is randomly seeded per process, so a bucketer
/// built on it would re-roll every user on every launch, a bug that no
/// single-process test can see. That's why this exists, and why its tests
/// pin published FNV-1a vectors rather than comparing two calls.
public enum StableHash {
    static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    static let prime: UInt64 = 0x0000_0100_0000_01b3

    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash = offsetBasis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            // Wrapping multiply is the FNV definition, not an overflow bug.
            hash = hash &* prime
        }
        return hash
    }
}

/// Deterministic percentage rollout of a vendor across installs.
public struct RolloutBucketer: Sendable {
    public let installID: String

    public init(installID: String) { self.installID = installID }

    /// The install's bucket for this vendor, in `0..<100`.
    ///
    /// The vendor id is mixed in so the same 10% of users aren't the guinea
    /// pigs for every vendor rollout.
    public func bucket(for vendor: VendorID) -> Int {
        // `% 100` is < 100, so the conversion to Int cannot trap even on
        // 32-bit platforms.
        Int(StableHash.fnv1a64("\(vendor.rawValue)|\(installID)") % 100)
    }

    /// Whether this install is inside a `percent` rollout. Monotone: raising
    /// the percentage never removes an install that was already in.
    public func isIncluded(_ vendor: VendorID, percent: Int) -> Bool {
        guard percent > 0 else { return false }
        guard percent < 100 else { return true }
        return bucket(for: vendor) < percent
    }
}
