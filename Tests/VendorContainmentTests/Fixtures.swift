import Foundation
import XCTest
@testable import VendorContainment

/// A scriptable adapter that records everything it is asked to do.
final class RecordingAdapter: VendorAdapter, @unchecked Sendable {
    // @unchecked: the recorded arrays are guarded by `lock`; the behaviour
    // closures are assigned before the runtime is created and never after.
    let id: VendorID
    let stage: StartupStage
    let payloadSchema: PayloadSchema
    private let lock = NSLock()
    private var _received: [String] = []
    private var _starts: [Date] = []
    private let clock: any ContainmentClock
    var onStart: @Sendable (VendorPayload) async throws -> Void = { _ in }
    var onSend: @Sendable (ContainedEvent) async throws -> Void = { _ in }

    init(_ id: VendorID, stage: StartupStage = .afterFirstFrame, schema: PayloadSchema = .permissive,
         clock: any ContainmentClock) {
        self.id = id
        self.stage = stage
        self.payloadSchema = schema
        self.clock = clock
    }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return _received }
    var starts: [Date] { lock.lock(); defer { lock.unlock() }; return _starts }

    private func recordStart() { lock.lock(); _starts.append(clock.now()); lock.unlock() }
    private func recordReceived(_ name: String) { lock.lock(); _received.append(name); lock.unlock() }

    func start(payload: VendorPayload) async throws {
        try await onStart(payload)
        recordStart()
    }

    func send(_ event: ContainedEvent) async throws {
        recordReceived(event.name)
        try await onSend(event)
    }
}

struct TestError: Error, Equatable {}

/// A store whose `save` can be switched to fail.
final class FlakyStore: ContainmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PersistedState?
    var failSaves = false

    func load() -> PersistedState? { lock.lock(); defer { lock.unlock() }; return state }
    func save(_ s: PersistedState) throws {
        lock.lock(); defer { lock.unlock() }
        if failSaves { throw TestError() }
        state = s
    }
}

/// A store that silently forgets everything: the broken implementation the
/// durability tests feed in to prove the marker write is load-bearing.
struct AmnesiacStore: ContainmentStore {
    func load() -> PersistedState? { nil }
    func save(_ state: PersistedState) throws {}
}

enum Fixture {
    static let a: VendorID = "analytics"
    static let b: VendorID = "attribution"
    static let c: VendorID = "messaging"

    static func policy(_ ids: [VendorID], version: Int = 1) -> PolicyDocument {
        PolicyDocument(version: version, rules: Dictionary(ids.map { ($0, VendorRule()) }, uniquingKeysWith: { first, _ in first }))
    }

    static func config(threshold: Int = 2) -> ContainmentConfiguration {
        var c = ContainmentConfiguration()
        c.stabilityWindow = 10
        c.idleStageDelay = 2
        c.sentinel = SentinelConfiguration(strikeThreshold: threshold, baseCooldown: 3_600, maxCooldown: 4 * 3_600)
        return c
    }

    static func runtime(
        _ adapters: [RecordingAdapter],
        clock: ManualClock,
        store: any ContainmentStore = InMemoryContainmentStore(),
        config: ContainmentConfiguration = config(),
        compiled: PolicyDocument? = nil
    ) throws -> ContainmentRuntime {
        try ContainmentRuntime(
            adapters: adapters,
            compiledPolicy: compiled ?? policy(adapters.map(\.id)),
            configuration: config,
            store: store,
            installID: "install-1",
            appVersion: "1.0",
            clock: clock,
            sleeper: ManualSleeper(clock: clock)
        )
    }

    static func simulator(
        _ vendors: [(id: VendorID, stage: StartupStage)],
        store: any ContainmentStore = InMemoryContainmentStore(),
        config: ContainmentConfiguration = config()
    ) -> LaunchSimulator {
        LaunchSimulator(vendors: vendors, compiledPolicy: policy(vendors.map(\.id)), configuration: config, store: store)
    }

    static let poisoned: VendorPayload = [SimulatedVendor.flagKey: .null]
}
