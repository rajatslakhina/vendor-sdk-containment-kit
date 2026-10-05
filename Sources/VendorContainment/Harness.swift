import Foundation

// MARK: - Fault-injection harness
//
// A deterministic model of "the app launches, a vendor kills it, the user
// opens it again". Used by the test suite and by the demo app. The only
// state that survives a simulated crash is the ``ContainmentStore``, which
// is exactly what survives a real one.

/// How a simulated vendor misbehaves.
public enum SimulatedFault: String, Sendable, CaseIterable, Codable {
    case none
    /// Crashes inside `start()` when its payload carries a null or empty
    /// flag name, which is the shape of the 28 Sep 2026 Firebase incident.
    case nullFlagCrashOnStart
    /// Starts fine, then crashes a few seconds later on a background callback
    /// (inside the stability window, while other vendors may also be running).
    case crashAfterStart
    /// Starts fine, then crashes if *another* vendor starts while it is still
    /// inside its stability window (a contention bug on a shared resource).
    /// At the moment of death a different vendor is inside `start()`, which
    /// is exactly the case naive "blame whoever was starting" gets wrong.
    case crashWhenAnotherStartsDuringProbation
}

/// The simulated process died. Only the harness throws this.
public struct SimulatedCrash: FatalFault, Equatable {
    public let vendor: VendorID
    public init(vendor: VendorID) { self.vendor = vendor }
}

/// Shared, thread-safe record of what the simulated vendors did.
public final class SimulationLedger: @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var _started: [VendorID] = []
    private var _startedAt: [VendorID: TimeInterval] = [:]
    private var _received: [VendorID: [String]] = [:]
    private var _faults: [VendorID: SimulatedFault] = [:]

    public init() {}

    public func setFault(_ fault: SimulatedFault, for vendor: VendorID) {
        lock.lock(); defer { lock.unlock() }
        _faults[vendor] = fault
    }

    public func fault(for vendor: VendorID) -> SimulatedFault {
        lock.lock(); defer { lock.unlock() }
        return _faults[vendor] ?? SimulatedFault.none
    }

    func recordStart(_ vendor: VendorID, at uptime: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _started.append(vendor)
        _startedAt[vendor] = uptime
    }

    func startedAt(_ vendor: VendorID) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return _startedAt[vendor]
    }

    func recordReceived(_ name: String, by vendor: VendorID) {
        lock.lock(); defer { lock.unlock() }
        _received[vendor, default: []].append(name)
    }

    /// Vendors started in the current launch, in start order.
    public var startedThisLaunch: [VendorID] {
        lock.lock(); defer { lock.unlock() }
        return _started
    }

    public func received(by vendor: VendorID) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return _received[vendor] ?? []
    }

    func beginLaunch() {
        lock.lock(); defer { lock.unlock() }
        _started = []
        _startedAt = [:]
    }
}

/// A vendor SDK stand-in that can be told to misbehave.
public struct SimulatedVendor: VendorAdapter {
    public static let flagKey = "flag_name"

    public let id: VendorID
    public let stage: StartupStage
    public let payloadSchema: PayloadSchema
    let ledger: SimulationLedger
    let clock: any ContainmentClock
    let contentionWindow: TimeInterval

    public init(
        id: VendorID,
        stage: StartupStage,
        ledger: SimulationLedger,
        clock: any ContainmentClock = SystemClock(),
        contentionWindow: TimeInterval = 10
    ) {
        self.id = id
        self.stage = stage
        self.ledger = ledger
        self.clock = clock
        self.contentionWindow = contentionWindow
        self.payloadSchema = PayloadSchema(requiredNonEmptyStrings: [Self.flagKey])
    }

    public func start(payload: VendorPayload) async throws {
        let now = clock.uptime()
        for other in ledger.startedThisLaunch where other != id
            && ledger.fault(for: other) == .crashWhenAnotherStartsDuringProbation {
            if let at = ledger.startedAt(other), now - at < contentionWindow {
                throw SimulatedCrash(vendor: other)
            }
        }
        if ledger.fault(for: id) == .nullFlagCrashOnStart {
            switch payload[Self.flagKey] {
            case .string(let name) where !name.isEmpty: break
            // The vendor force-unwraps the flag name. In a real app this is
            // EXC_BREAKPOINT inside didFinishLaunching.
            default: throw SimulatedCrash(vendor: id)
            }
        }
        ledger.recordStart(id, at: clock.uptime())
    }

    public func send(_ event: ContainedEvent) async throws {
        ledger.recordReceived(event.name, by: id)
    }
}

/// Sleeper that advances a manual clock and, while a `crashAfterStart`
/// vendor is running, kills the process partway through the wait.
struct FaultingSleeper: ContainmentSleeper {
    let clock: ManualClock
    let ledger: SimulationLedger

    func sleep(for seconds: TimeInterval) async throws {
        if let culprit = ledger.startedThisLaunch.first(where: { ledger.fault(for: $0) == .crashAfterStart }) {
            clock.advance(by: min(max(0, seconds), 3))
            throw SimulatedCrash(vendor: culprit)
        }
        clock.advance(by: max(0, seconds))
        await Task.yield()
    }
}

/// The result of one simulated launch.
public struct LaunchRecord: Sendable, Equatable, Identifiable {
    public var id: UInt64 { number }
    public let number: UInt64
    /// Ground truth: which vendor actually killed this launch, if any.
    public let crashedBy: VendorID?
    public let snapshot: RuntimeSnapshot
}

/// Drives repeated launches against one persistent store.
public actor LaunchSimulator {
    public nonisolated let ledger = SimulationLedger()
    public let clock: ManualClock
    public let store: any ContainmentStore
    public let vendors: [(id: VendorID, stage: StartupStage)]
    public let compiledPolicy: PolicyDocument
    public let configuration: ContainmentConfiguration
    public let installID: String

    /// What the app's control plane would serve. `nil` = unreachable.
    public var remotePolicy: PolicyDocument?
    public var payloads: [VendorID: VendorPayload]
    public var appVersion: String
    /// Seconds between one launch and the next (user reopening the app).
    public var relaunchGap: TimeInterval = 30
    public private(set) var current: ContainmentRuntime?
    public private(set) var history: [LaunchRecord] = []

    public init(
        vendors: [(id: VendorID, stage: StartupStage)],
        compiledPolicy: PolicyDocument,
        configuration: ContainmentConfiguration = ContainmentConfiguration(),
        store: any ContainmentStore = InMemoryContainmentStore(),
        installID: String = "sim-install",
        appVersion: String = "1.0"
    ) {
        self.vendors = vendors
        self.compiledPolicy = compiledPolicy
        self.configuration = configuration
        self.store = store
        self.installID = installID
        self.appVersion = appVersion
        self.clock = ManualClock()
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: duplicate ids must
        // surface as `ContainmentError.duplicateVendor` at launch, not a trap.
        self.payloads = Dictionary(
            vendors.map { ($0.id, [SimulatedVendor.flagKey: PayloadValue.string("enabled")]) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func setRemotePolicy(_ policy: PolicyDocument?) { remotePolicy = policy }
    public func setPayload(_ payload: VendorPayload, for vendor: VendorID) { payloads[vendor] = payload }
    public func setFault(_ fault: SimulatedFault, for vendor: VendorID) { ledger.setFault(fault, for: vendor) }
    public func setAppVersion(_ version: String) { appVersion = version }
    public func setRelaunchGap(_ seconds: TimeInterval) { relaunchGap = seconds }

    /// Simulates one cold launch: boot → first frame → `app_open` →
    /// staged startup. Returns what happened, including the ground-truth
    /// culprit if the launch crashed.
    @discardableResult
    public func launch(
        configuration override: ContainmentConfiguration? = nil
    ) async throws -> LaunchRecord {
        clock.advance(by: relaunchGap)
        ledger.beginLaunch()
        let adapters: [any VendorAdapter] = vendors.map {
            SimulatedVendor(
                id: $0.id, stage: $0.stage, ledger: ledger,
                clock: clock, contentionWindow: (override ?? configuration).stabilityWindow
            )
        }
        let runtime = try ContainmentRuntime(
            adapters: adapters,
            compiledPolicy: compiledPolicy,
            configuration: override ?? configuration,
            store: store,
            installID: installID,
            appVersion: appVersion,
            clock: clock,
            sleeper: FaultingSleeper(clock: clock, ledger: ledger)
        )
        current = runtime
        try await runtime.boot(policy: remotePolicy, payloads: payloads)
        try await runtime.track("app_open")

        var culprit: VendorID?
        do {
            try await runtime.runStartup()
        } catch let crash as SimulatedCrash {
            culprit = crash.vendor
            current = nil
        }
        let snap = await runtime.snapshot()
        let record = LaunchRecord(number: snap.launchCount, crashedBy: culprit, snapshot: snap)
        history.append(record)
        return record
    }

    /// Sends an event through the live runtime, if the last launch survived.
    @discardableResult
    public func track(_ name: String, privacy: PrivacyClass = .anonymous) async throws -> [VendorID: Delivery] {
        guard let current else { return [:] }
        return try await current.track(name, privacy: privacy)
    }

    public func liveSnapshot() async -> RuntimeSnapshot? {
        await current?.snapshot()
    }
}
