import Foundation

/// Everything that must survive a crash.
public struct PersistedState: Codable, Sendable, Equatable {
    public var sentinel: SentinelState
    public var policyCache: CachedPolicy?
    public var buffer: EventBuffer

    public init(sentinel: SentinelState = SentinelState(), policyCache: CachedPolicy? = nil, buffer: EventBuffer) {
        self.sentinel = sentinel
        self.policyCache = policyCache
        self.buffer = buffer
    }
}

/// Durable storage for ``PersistedState``.
///
/// **Synchronous on purpose.** The marker must be durable *before* the vendor
/// runs; an async save could still be in flight when the vendor crashes the
/// process, and then the crash leaves no trace. The runtime calls `save`
/// before every `await` that hands control to vendor code.
public protocol ContainmentStore: Sendable {
    func load() -> PersistedState?
    func save(_ state: PersistedState) throws
}

/// In-memory store. Survives runtime instances (so the harness can model
/// relaunches) but not the real process.
public final class InMemoryContainmentStore: ContainmentStore, @unchecked Sendable {
    // @unchecked: `state` is only touched under `lock`.
    private let lock = NSLock()
    private var state: PersistedState?

    public init(initial: PersistedState? = nil) { self.state = initial }

    public func load() -> PersistedState? {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func save(_ state: PersistedState) throws {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }
}

/// JSON file store using an atomic write (temp file + rename), so a crash
/// mid-write leaves the previous state, never a torn file.
public struct FileContainmentStore: ContainmentStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A corrupt file is treated as "no history": we lose strikes, but we
        // never crash-loop on our own crash-loop detector.
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    public func save(_ state: PersistedState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}
