import Foundation

/// A third-party SDK the app has wrapped behind its own facade.
///
/// A newtype rather than a bare `String` so a vendor id can never be confused
/// with an event name or a flag key at a call site.
public struct VendorID: Hashable, Codable, Sendable, Comparable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
    public static func < (lhs: VendorID, rhs: VendorID) -> Bool { lhs.rawValue < rhs.rawValue }

    // CodingKeyRepresentable: lets `[VendorID: T]` encode as a JSON object
    // rather than Swift's default alternating-array form.
    public var codingKey: any CodingKey { _Key(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.rawValue = codingKey.stringValue }

    private struct _Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// When a vendor is allowed to start.
///
/// There is deliberately **no pre-first-frame case**. The Firebase outage of
/// 28 Sep 2026 crashed apps inside `didFinishLaunching`, before any UI existed
/// and before any app-owned recovery code could run. Making "start a vendor
/// during launch" unrepresentable is cheaper than reviewing for it.
public enum StartupStage: Int, Codable, Sendable, CaseIterable, Comparable {
    /// Immediately after the first frame is on screen.
    case afterFirstFrame = 1
    /// After a further idle delay (``ContainmentConfiguration/idleStageDelay``).
    case idle = 2

    public static func < (lhs: StartupStage, rhs: StartupStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How sensitive an analytics event is. Drives what may be written to disk.
public enum PrivacyClass: String, Codable, Sendable, CaseIterable {
    /// No identifier at all (e.g. "app_open").
    case anonymous
    /// Tied to a rotating install-scoped identifier.
    case pseudonymous
    /// Contains personal data. **Never buffered to disk**: if it can't be
    /// sent live it is dropped and counted.
    case personal
}

/// An event as the app's code emits it, before any vendor sees it.
public struct ContainedEvent: Codable, Sendable, Equatable {
    public let name: String
    public let privacy: PrivacyClass
    public let at: Date

    public init(name: String, privacy: PrivacyClass, at: Date) {
        self.name = name
        self.privacy = privacy
        self.at = at
    }
}

/// Time source. Injected so every time-dependent rule is testable.
///
/// Two readings on purpose: `now()` is wall time (persisted, compared across
/// launches, may jump), `uptime()` is monotonic within one process and is
/// what in-launch windows (the stability window) are measured on, so a user
/// changing the clock can't stretch or shrink them.
public protocol ContainmentClock: Sendable {
    func now() -> Date
    func uptime() -> TimeInterval
}

public struct SystemClock: ContainmentClock {
    public init() {}
    public func now() -> Date { Date() }
    public func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// A clock you move by hand. Thread-safe so it can be shared by a simulated
/// sleeper and the runtime.
public final class ManualClock: ContainmentClock, @unchecked Sendable {
    // @unchecked: all access to `current` goes through `lock`.
    private let lock = NSLock()
    private var current: Date
    private var elapsed: TimeInterval = 0

    public init(start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        self.current = start
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func uptime() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return elapsed
    }

    /// Moves the clock. Non-finite intervals are ignored rather than trapping
    /// inside `Date` arithmetic.
    public func advance(by seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
        if seconds > 0 { elapsed += seconds }
    }

    /// Sets wall time only (models a user changing the clock); monotonic
    /// uptime is unaffected.
    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}

/// Suspends the startup coordinator between isolated vendor starts.
public protocol ContainmentSleeper: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

/// Real sleeper backed by `Task.sleep`.
public struct TaskSleeper: ContainmentSleeper {
    public init() {}

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: Saturating.nanoseconds(fromSeconds: seconds))
    }
}

/// A sleeper that advances a ``ManualClock`` instead of waiting.
public struct ManualSleeper: ContainmentSleeper {
    public let clock: ManualClock
    public init(clock: ManualClock) { self.clock = clock }

    public func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        clock.advance(by: max(0, seconds))
        await Task.yield()
    }
}

/// A fault that models the process dying.
///
/// In production a real crash never returns, so nothing ever throws this. It
/// exists for the fault-injection harness: when an adapter (or sleeper)
/// throws a `FatalFault`, the runtime rethrows immediately, touches no
/// persisted state, and refuses every later call, leaving the store exactly
/// as a real crash would.
public protocol FatalFault: Error {}
