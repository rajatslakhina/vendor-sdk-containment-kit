import Foundation

/// The port every vendor SDK is wrapped behind. App code never imports a
/// vendor module directly; it talks to ``ContainmentRuntime``, which talks to
/// adapters.
public protocol VendorAdapter: Sendable {
    var id: VendorID { get }
    var stage: StartupStage { get }
    var payloadSchema: PayloadSchema { get }
    func start(payload: VendorPayload) async throws
    func send(_ event: ContainedEvent) async throws
}

public struct ContainmentConfiguration: Sendable, Equatable {
    /// How long a vendor must run before its marker is cleared.
    public var stabilityWindow: TimeInterval = 10
    /// Extra delay before the `.idle` stage starts.
    public var idleStageDelay: TimeInterval = 2
    public var sentinel = SentinelConfiguration()
    public var bufferCapacityPerVendor = 200
    public var bufferMaxAge: TimeInterval = 86_400
    /// Validate vendor payloads against each adapter's schema before start.
    public var validatesVendorPayloads = true
    /// How old a cached policy may get before it can only restrict.
    public var policyMaxStaleness: TimeInterval = 7 * 86_400
    /// Backoff after a failed send. There is no timer: the queue is retried on
    /// the next `track` after the backoff has elapsed, or immediately by
    /// ``ContainmentRuntime/flush()``.
    public var baseRetryDelay: TimeInterval = 1
    public var maxRetryDelay: TimeInterval = 60

    /// Ten years: an upper bound for any duration setting, so nothing
    /// downstream ever has to reason about astronomically large intervals.
    public static let maxDuration: TimeInterval = 10 * 365 * 86_400

    public init() {}

    public func validate() throws {
        func check(_ ok: Bool, _ message: String) throws {
            if !ok { throw ContainmentError.invalidConfiguration(message) }
        }
        try check(stabilityWindow.isFinite && stabilityWindow > 0, "stabilityWindow must be > 0")
        try check(idleStageDelay.isFinite && idleStageDelay >= 0, "idleStageDelay must be >= 0")
        try check(sentinel.strikeThreshold >= 1, "strikeThreshold must be >= 1")
        try check(sentinel.baseCooldown.isFinite && sentinel.baseCooldown > 0, "baseCooldown must be > 0")
        try check(sentinel.maxCooldown.isFinite && sentinel.maxCooldown >= sentinel.baseCooldown,
                  "maxCooldown must be >= baseCooldown")
        try check(bufferCapacityPerVendor >= 1, "bufferCapacityPerVendor must be >= 1 (every bufferable event goes through the queue)")
        try check(bufferMaxAge.isFinite && bufferMaxAge >= 0, "bufferMaxAge must be >= 0")
        try check(policyMaxStaleness.isFinite && policyMaxStaleness >= 0, "policyMaxStaleness must be >= 0")
        try check(baseRetryDelay.isFinite && baseRetryDelay > 0, "baseRetryDelay must be > 0")
        try check(maxRetryDelay.isFinite && maxRetryDelay >= baseRetryDelay, "maxRetryDelay must be >= baseRetryDelay")
        let durations = [stabilityWindow, idleStageDelay, sentinel.maxCooldown, bufferMaxAge, policyMaxStaleness, maxRetryDelay]
        try check(durations.allSatisfy { $0 <= Self.maxDuration }, "durations must be <= 10 years")
    }
}

public enum ContainmentError: Error, Equatable, Sendable {
    case duplicateVendor(VendorID)
    case invalidConfiguration(String)
    case notBooted
    case alreadyBooted
    case startupAlreadyRan
    /// The stability wait gave up (the sleeper isn't advancing time).
    /// Markers are still on disk; call ``ContainmentRuntime/settle()`` later.
    case stabilityWaitExhausted
    /// A ``FatalFault`` was thrown; this runtime models a dead process.
    case terminated
}

public enum SkipReason: Sendable, Equatable, CustomStringConvertible {
    case disabledByPolicy(DisabledEventHandling)
    case outsideRollout
    case quarantined
    case payloadRejected([PayloadViolation])
    case startFailed(String)

    public var description: String {
        switch self {
        case .disabledByPolicy(let h): "disabled by app policy (\(h.rawValue))"
        case .outsideRollout: "outside rollout"
        case .quarantined: "quarantined after crashing the app"
        case .payloadRejected(let v): "payload rejected: \(v.map(\.description).joined(separator: "; "))"
        case .startFailed(let m): "start failed: \(m)"
        }
    }

    /// Whether events for a vendor skipped for this reason are kept.
    var buffersEvents: Bool {
        switch self {
        case .disabledByPolicy(.drop), .outsideRollout: false
        default: true
        }
    }
}

public enum VendorLifecycle: Sendable, Equatable {
    case pending(isolated: Bool)
    case starting
    case running(stable: Bool)
    case skipped(SkipReason)
}

public enum Delivery: Sendable, Equatable {
    case sent
    case buffered
    /// Queued in memory, but the store refused the write: it will replay in
    /// this process, but would not survive a crash.
    case bufferedVolatile
    case dropped(DropReason)

    public enum DropReason: String, Sendable { case policy, personalNotBufferable, noCapacity }
}

public struct VendorStatus: Sendable, Equatable, Identifiable {
    public var id: VendorID
    public var stage: StartupStage
    public var lifecycle: VendorLifecycle
    public var health: VendorHealth
    public var rule: VendorRule
    public var buffered: Int
    public var sent: Int
    public var dropped: Int
}

public struct RuntimeSnapshot: Sendable, Equatable {
    public var launchCount: UInt64
    public var vendors: [VendorStatus]
    public var findings: [SentinelFinding]
    public var policySource: PolicySource
    public var policyRejections: [PolicyRejection]
    public var lastStoreError: String?
    public var terminated: Bool
}

/// The imperative shell around the pure cores (``LaunchSentinel``,
/// ``PolicyResolver``, ``RolloutBucketer``, ``PayloadValidator``,
/// ``EventBuffer``).
///
/// Lifecycle per launch: `boot` (synchronous decisions, no vendor code runs)
/// → first frame → `runStartup` (serial, marker-guarded starts) → `track`
/// any time. Every `await` into vendor code (`start`, `send`) that involves
/// persisted state is preceded by a synchronous `save`, so whatever is on disk is the truth a crash would
/// leave: the marker for a start, and for a send the queue with the
/// in-flight event still at its head. Bufferable events always go through
/// the queue (append, save, send, remove), so delivery is at-least-once.
/// `.personal` events are the deliberate exception: never written to disk,
/// sent live only, so at-most-once.
public actor ContainmentRuntime {
    private let adapters: [VendorID: any VendorAdapter]
    private let order: [VendorID]
    private let configuration: ContainmentConfiguration
    private let resolver: PolicyResolver
    private let store: any ContainmentStore
    private let clock: any ContainmentClock
    private let sleeper: any ContainmentSleeper
    private let bucketer: RolloutBucketer
    private let appVersion: String

    private var state: PersistedState
    private var booted = false
    private var startupBegan = false
    private var terminated = false
    private var payloads: [VendorID: VendorPayload] = [:]
    private var lifecycle: [VendorID: VendorLifecycle] = [:]
    private var rules: [VendorID: VendorRule] = [:]
    /// Vendors with a send (live or replay) currently suspended.
    private var inFlight: Set<VendorID> = []
    /// Monotonic start of each vendor's stability window, this launch only.
    private var probationStartedAt: [VendorID: TimeInterval] = [:]
    private var retry: [VendorID: (delay: TimeInterval, notBefore: TimeInterval)] = [:]
    private var sent: [VendorID: Int] = [:]
    private var dropped: [VendorID: Int] = [:]
    private var findings: [SentinelFinding] = []
    private var policySource: PolicySource = .compiledDefault
    private var rejections: [PolicyRejection] = []
    private var lastStoreError: String?

    public init(
        adapters: [any VendorAdapter],
        compiledPolicy: PolicyDocument,
        configuration: ContainmentConfiguration = ContainmentConfiguration(),
        store: any ContainmentStore,
        installID: String,
        appVersion: String,
        clock: any ContainmentClock = SystemClock(),
        sleeper: any ContainmentSleeper = TaskSleeper()
    ) throws {
        try configuration.validate()
        var map: [VendorID: any VendorAdapter] = [:]
        for adapter in adapters {
            guard map[adapter.id] == nil else { throw ContainmentError.duplicateVendor(adapter.id) }
            map[adapter.id] = adapter
        }
        self.adapters = map
        self.order = adapters
            .sorted { ($0.stage, $0.id) < ($1.stage, $1.id) }
            .map(\.id)
        self.configuration = configuration
        self.resolver = PolicyResolver(compiledDefault: compiledPolicy, maxStaleness: configuration.policyMaxStaleness)
        self.store = store
        self.clock = clock
        self.sleeper = sleeper
        self.bucketer = RolloutBucketer(installID: installID)
        self.appVersion = appVersion
        self.state = PersistedState(buffer: EventBuffer(capacityPerVendor: configuration.bufferCapacityPerVendor))
    }

    // MARK: - Boot

    /// Reads the previous launch's evidence, resolves policy, and decides who
    /// may start. Runs no vendor code, so it is safe before the first frame.
    ///
    /// - Parameters:
    ///   - policy: a document from the app's own control plane that is already
    ///     on hand (typically fetched in the background during the *previous*
    ///     session; never block the first frame on a network call), or `nil`,
    ///     in which case the cached last-known-good is used.
    ///   - payloads: each vendor's configuration payload.
    @discardableResult
    public func boot(policy: PolicyDocument?, payloads: [VendorID: VendorPayload] = [:]) throws -> RuntimeSnapshot {
        try ensureAlive()
        guard !booted else { throw ContainmentError.alreadyBooted }
        booted = true
        self.payloads = payloads
        let now = clock.now()

        var loaded = store.load() ?? state
        if loaded.buffer.capacityPerVendor != configuration.bufferCapacityPerVendor {
            loaded.buffer = loaded.buffer.resized(to: configuration.bufferCapacityPerVendor)
        }
        state = loaded

        let resolution = resolver.resolve(candidate: policy, cache: state.policyCache, vendors: order, now: now)
        state.policyCache = resolution.cache
        policySource = resolution.source
        rejections = resolution.rejections
        rules = resolution.rules

        let (sentinel, recovered) = LaunchSentinel.recover(
            state.sentinel,
            configuration: configuration.sentinel,
            now: now,
            appVersion: appVersion,
            epochs: rules.mapValues(\.quarantineEpoch)
        )
        state.sentinel = sentinel
        findings = recovered

        for id in order {
            guard let adapter = adapters[id] else { continue }
            lifecycle[id] = decide(adapter, rule: rules[id] ?? .off, health: sentinel.health[id] ?? VendorHealth())
            if case .skipped(let reason) = lifecycle[id], !reason.buffersEvents {
                _ = state.buffer.purge(id)
            }
        }
        state.buffer.expire(olderThan: configuration.bufferMaxAge, now: now)
        persist()
        return snapshot()
    }

    private func decide(_ adapter: any VendorAdapter, rule: VendorRule, health: VendorHealth) -> VendorLifecycle {
        guard rule.enabled else { return .skipped(.disabledByPolicy(rule.whenDisabled)) }
        guard bucketer.isIncluded(adapter.id, percent: rule.rolloutPercent) else { return .skipped(.outsideRollout) }
        guard !health.isBlocked else { return .skipped(.quarantined) }
        if configuration.validatesVendorPayloads {
            let violations = PayloadValidator.validate(payloads[adapter.id] ?? [:], against: adapter.payloadSchema)
            guard violations.isEmpty else { return .skipped(.payloadRejected(violations)) }
        }
        return .pending(isolated: health.needsIsolation)
    }

    // MARK: - Startup

    /// Starts every pending vendor, stage by stage, after the first frame.
    ///
    /// Vendors start strictly one at a time, so at most one vendor is ever
    /// inside `start()`. Vendors with a strike, under suspicion, or on a
    /// quarantine probe run *isolated*: they start only when nothing else is
    /// on probation, and nothing else starts until their window has passed,
    /// so if they crash again the blame is unambiguous.
    public func runStartup() async throws {
        try ensureAlive()
        guard booted else { throw ContainmentError.notBooted }
        // Set before the first suspension point: a reentrant second call
        // observes it and throws instead of double-starting vendors.
        guard !startupBegan else { throw ContainmentError.startupAlreadyRan }
        startupBegan = true

        for stage in StartupStage.allCases.sorted() {
            let inStage = order.filter { adapters[$0]?.stage == stage }
            let isolated = inStage.filter { lifecycle[$0] == .pending(isolated: true) }
            let normal = inStage.filter { lifecycle[$0] == .pending(isolated: false) }
            guard !(isolated.isEmpty && normal.isEmpty) else { continue }
            if stage == .idle, configuration.idleStageDelay > 0 {
                try await sleep(configuration.idleStageDelay)
            }
            for id in isolated {
                try await awaitQuiescence()
                try await startVendor(id)
                try await awaitQuiescence()
            }
            for id in normal {
                try await startVendor(id)
            }
        }
        try await awaitQuiescence()
    }

    private func startVendor(_ id: VendorID) async throws {
        guard let adapter = adapters[id] else { return }
        state.sentinel.markers[id] = .starting
        do {
            try store.save(state)
        } catch {
            // Fail closed: a start we couldn't record is a crash we couldn't
            // detect. Better to lose a vendor for one launch.
            state.sentinel.markers[id] = nil
            lastStoreError = String(describing: error)
            lifecycle[id] = .skipped(.startFailed("marker could not be persisted"))
            return
        }
        lifecycle[id] = .starting
        do {
            try await adapter.start(payload: payloads[id] ?? [:])
        } catch let fault as FatalFault {
            terminated = true
            throw fault
        } catch {
            try ensureAlive()
            state.sentinel.markers[id] = nil
            lifecycle[id] = .skipped(.startFailed(String(describing: error)))
            persist()
            return
        }
        try ensureAlive()
        state.sentinel.markers[id] = .probation(since: clock.now())
        probationStartedAt[id] = clock.uptime()
        lifecycle[id] = .running(stable: false)
        persist()
        try await drain(id)
    }

    /// Clears the markers of every vendor whose stability window has elapsed,
    /// measured on the monotonic clock (a wall-clock change can't stretch or
    /// shrink it).
    ///
    /// `runStartup` calls this itself; call it again if the startup task was
    /// cancelled, or the next launch will treat those markers as a crash.
    @discardableResult
    public func settle() throws -> [VendorID] {
        try ensureAlive()
        let now = clock.uptime()
        var cleared: [VendorID] = []
        for (id, startedAt) in probationStartedAt.sorted(by: { $0.key < $1.key }) {
            guard now - startedAt >= configuration.stabilityWindow else { continue }
            probationStartedAt[id] = nil
            findings.append(LaunchSentinel.markStable(id, in: &state.sentinel))
            lifecycle[id] = .running(stable: true)
            cleared.append(id)
        }
        if !cleared.isEmpty { persist() }
        return cleared
    }

    private func awaitQuiescence() async throws {
        // Bounded so a sleeper that never advances time can't spin forever.
        // Hitting the bound is surfaced, not swallowed: the markers are still
        // on disk and the caller must `settle()` later.
        for _ in 0..<1_000 {
            try settle()
            guard let earliest = probationStartedAt.values.min() else { return }
            let remaining = earliest + configuration.stabilityWindow - clock.uptime()
            try await sleep(max(0, remaining))
        }
        throw ContainmentError.stabilityWaitExhausted
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        do {
            try await sleeper.sleep(for: seconds)
        } catch let fault as FatalFault {
            terminated = true
            throw fault
        }
        try ensureAlive()
    }

    // MARK: - Events

    /// Routes one event to each target vendor (all vendors by default).
    @discardableResult
    public func track(
        _ name: String,
        privacy: PrivacyClass = .anonymous,
        to targets: [VendorID]? = nil
    ) async throws -> [VendorID: Delivery] {
        try ensureAlive()
        guard booted else { throw ContainmentError.notBooted }
        let event = ContainedEvent(name: name, privacy: privacy, at: clock.now())
        var result: [VendorID: Delivery] = [:]
        for id in (targets ?? order) where adapters[id] != nil {
            // Another task may have hit a FatalFault while we were suspended.
            try ensureAlive()
            result[id] = try await route(event, to: id)
        }
        return result
    }

    private func route(_ event: ContainedEvent, to id: VendorID) async throws -> Delivery {
        switch lifecycle[id] {
        case .running? where event.privacy == .personal:
            return try await sendPersonalLive(event, to: id)
        case .running?:
            // Append, save, then drain: the event is on disk before vendor
            // code runs, and it can never overtake anything queued before it
            // (a send in flight, or a failed head waiting out its backoff).
            let seq = state.buffer.nextSeq
            let evictedBefore = state.buffer.evicted
            let delivery = buffer(event, for: id)
            guard delivery == .buffered || delivery == .bufferedVolatile else { return delivery }
            try await drainIfDue(id)
            let stillQueued = state.buffer.pending(for: id).contains { $0.seq == seq }
            return (stillQueued || state.buffer.evicted != evictedBefore) ? delivery : .sent
        case .skipped(let reason)? where !reason.buffersEvents:
            dropped[id] = Saturating.increment(dropped[id] ?? 0)
            return .dropped(.policy)
        default:
            return buffer(event, for: id)
        }
    }

    /// `.personal` events never touch disk. They go out live only when that
    /// can't overtake anything; otherwise they are dropped and counted.
    private func sendPersonalLive(_ event: ContainedEvent, to id: VendorID) async throws -> Delivery {
        guard state.buffer.count(for: id) == 0, !inFlight.contains(id), let adapter = adapters[id] else {
            dropped[id] = Saturating.increment(dropped[id] ?? 0)
            return .dropped(.personalNotBufferable)
        }
        inFlight.insert(id)
        let delivery: Delivery
        do {
            try await adapter.send(event)
            inFlight.remove(id)
            try ensureAlive()
            sent[id] = Saturating.increment(sent[id] ?? 0)
            delivery = .sent
        } catch let fault as FatalFault {
            terminated = true
            throw fault
        } catch {
            inFlight.remove(id)
            try ensureAlive()
            dropped[id] = Saturating.increment(dropped[id] ?? 0)
            delivery = .dropped(.personalNotBufferable)
        }
        // Anything a reentrant `track` queued while this send was in flight
        // is delivered now, not stranded until the next event.
        try await drainIfDue(id)
        return delivery
    }

    private func buffer(_ event: ContainedEvent, for id: VendorID) -> Delivery {
        switch state.buffer.append(event, for: id) {
        case .buffered, .bufferedEvictingOldest:
            return persist() ? .buffered : .bufferedVolatile
        case .refusedPersonal:
            dropped[id] = Saturating.increment(dropped[id] ?? 0)
            return .dropped(.personalNotBufferable)
        case .refusedNoCapacity:
            dropped[id] = Saturating.increment(dropped[id] ?? 0)
            return .dropped(.noCapacity)
        }
    }

    private func noteSendFailure(_ id: VendorID) {
        let previous = retry[id]?.delay ?? 0
        let delay = previous > 0
            ? Saturating.doubled(previous, cap: configuration.maxRetryDelay)
            : min(configuration.baseRetryDelay, configuration.maxRetryDelay)
        retry[id] = (delay, clock.uptime() + delay)
    }

    /// Drains a running vendor's queue unless it is in retry backoff.
    private func drainIfDue(_ id: VendorID) async throws {
        guard case .running? = lifecycle[id], state.buffer.count(for: id) > 0 else { return }
        if let r = retry[id], clock.uptime() < r.notBefore { return }
        try await drain(id)
    }

    /// Replays a running vendor's queue in order, at-least-once.
    ///
    /// Reentrancy: while a send is suspended the vendor is `inFlight`, so a
    /// reentrant `track` appends behind the queue and returns, and this loop
    /// picks the event up. The head stays on disk until its send
    /// succeeds, so a crash mid-send replays it next launch instead of losing
    /// it. A failed send leaves the head in place, starts an exponential
    /// backoff (no timer), and stops; the next `track` after the backoff, or
    /// ``flush()`` at any time, resumes the drain.
    private func drain(_ id: VendorID) async throws {
        guard let adapter = adapters[id], !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        state.buffer.expire(olderThan: configuration.bufferMaxAge, now: clock.now())
        persist()
        while case .running? = lifecycle[id], let next = state.buffer.first(for: id) {
            do {
                try await adapter.send(next.event)
            } catch let fault as FatalFault {
                terminated = true
                throw fault
            } catch {
                try ensureAlive()
                noteSendFailure(id)
                return
            }
            try ensureAlive()
            state.buffer.removeHead(for: id, ifSeq: next.seq)
            sent[id] = Saturating.increment(sent[id] ?? 0)
            retry[id] = nil
            persist()
        }
    }

    /// Retries the queues of every running vendor now, ignoring backoff.
    public func flush() async throws {
        try ensureAlive()
        for id in order {
            if case .running? = lifecycle[id] {
                retry[id] = nil
                try await drain(id)
            }
        }
    }

    // MARK: - Introspection

    public func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            launchCount: state.sentinel.launchCount,
            vendors: order.compactMap { id in
                guard let adapter = adapters[id] else { return nil }
                return VendorStatus(
                    id: id,
                    stage: adapter.stage,
                    lifecycle: lifecycle[id] ?? .pending(isolated: false),
                    health: state.sentinel.health[id] ?? VendorHealth(),
                    rule: rules[id] ?? .off,
                    buffered: state.buffer.count(for: id),
                    sent: sent[id] ?? 0,
                    dropped: dropped[id] ?? 0
                )
            },
            findings: findings,
            policySource: policySource,
            policyRejections: rejections,
            lastStoreError: lastStoreError,
            terminated: terminated
        )
    }

    // MARK: - Helpers

    private func ensureAlive() throws {
        if terminated { throw ContainmentError.terminated }
    }

    /// Saves state; returns whether it is now durable.
    @discardableResult
    private func persist() -> Bool {
        guard !terminated else { return false }
        do {
            try store.save(state)
            lastStoreError = nil
            return true
        } catch {
            lastStoreError = String(describing: error)
            return false
        }
    }
}
