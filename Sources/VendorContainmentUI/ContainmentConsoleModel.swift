import Foundation
import Observation
import VendorContainment

/// View model for the containment console. Platform-neutral (Observation
/// only), so its behaviour is unit-tested on Linux; the SwiftUI view is a skin.
///
/// It drives a ``LaunchSimulator``: every "Launch" is a cold start against
/// the same persistent store, so you can watch a poisoned vendor crash the
/// app, get attributed, get quarantined, and stop crashing it.
@MainActor
@Observable
public final class ContainmentConsoleModel {
    public struct LaunchRow: Identifiable, Equatable, Sendable {
        public let id: UInt64
        public let crashedBy: VendorID?
        public let headline: String
        public let details: [String]
    }

    public struct VendorRow: Identifiable, Equatable, Sendable {
        public let id: VendorID
        public let stage: StartupStage
        public let state: String
        public let isHealthy: Bool
        public let strikes: Int
        public let quarantined: Bool
        public let buffered: Int
        public let sent: Int
        public let dropped: Int
    }

    public let vendorIDs: [VendorID]
    public private(set) var launches: [LaunchRow] = []
    public private(set) var vendorRows: [VendorRow] = []
    public private(set) var faults: [VendorID: SimulatedFault]
    public private(set) var killed: Set<VendorID> = []
    public private(set) var epochs: [VendorID: Int] = [:]
    public private(set) var policyVersion = 1
    public private(set) var policySummary = "not launched yet"
    public private(set) var appVersion = "1.0"
    public private(set) var isBusy = false
    public private(set) var lastMessage: String?
    public var validatesPayloads: Bool
    /// Attributed crash launches before a vendor is quarantined.
    public var strikeThreshold: Int { baseConfiguration.sentinel.strikeThreshold }

    private let simulator: LaunchSimulator
    private let baseConfiguration: ContainmentConfiguration
    private let compiledPolicy: PolicyDocument

    public init(
        vendors: [(id: VendorID, stage: StartupStage)],
        compiledPolicy: PolicyDocument,
        configuration: ContainmentConfiguration = ContainmentConfiguration(),
        initialFaults: [VendorID: SimulatedFault] = [:],
        validatesPayloads: Bool = false
    ) {
        self.vendorIDs = vendors.map(\.id)
        self.compiledPolicy = compiledPolicy
        self.baseConfiguration = configuration
        self.validatesPayloads = validatesPayloads
        self.faults = initialFaults
        self.simulator = LaunchSimulator(
            vendors: vendors,
            compiledPolicy: compiledPolicy,
            configuration: configuration
        )
        self.vendorRows = vendors.map {
            VendorRow(id: $0.id, stage: $0.stage, state: "not started", isHealthy: true,
                      strikes: 0, quarantined: false, buffered: 0, sent: 0, dropped: 0)
        }
    }

    // MARK: - Actions

    /// One cold launch of the simulated app.
    public func launch() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await pushSimulatorInputs()
        var config = baseConfiguration
        config.validatesVendorPayloads = validatesPayloads
        do {
            let record = try await simulator.launch(configuration: config)
            launches.insert(Self.row(for: record), at: 0)
            apply(record.snapshot)
            lastMessage = record.crashedBy.map { "Launch \(record.number) crashed in \($0)." }
                ?? "Launch \(record.number) is up."
        } catch {
            lastMessage = "Launch could not run: \(error)"
        }
    }

    /// Four launches back to back: enough to watch detection → quarantine.
    public func replayIncident(launches count: Int = 4) async {
        for _ in 0..<max(0, count) {
            await launch()
        }
    }

    /// Sends an analytics event through the live (surviving) launch.
    public func trackEvent(_ name: String = "button_tap") async {
        do {
            let result = try await simulator.track(name)
            if result.isEmpty {
                lastMessage = "No live launch: the last one crashed. Launch again."
            } else {
                let parts = result.sorted { $0.key < $1.key }.map { "\($0.key): \(Self.describe($0.value))" }
                lastMessage = "\(name) → " + parts.joined(separator: ", ")
            }
            if let snap = await simulator.liveSnapshot() { apply(snap) }
        } catch {
            lastMessage = "Event failed: \(error)"
        }
    }

    public func setFault(_ fault: SimulatedFault, for vendor: VendorID) {
        faults[vendor] = fault
    }

    /// Flips the app's *own* kill switch for a vendor (a new policy version).
    public func toggleKillSwitch(_ vendor: VendorID) {
        if killed.contains(vendor) { killed.remove(vendor) } else { killed.insert(vendor) }
        policyVersion = Saturating.increment(policyVersion)
    }

    /// Ops confirms the vendor shipped a fix: clear the fault and bump the
    /// vendor's quarantine epoch in a new policy version.
    public func releaseQuarantine(_ vendor: VendorID) {
        faults[vendor] = SimulatedFault.none
        epochs[vendor] = Saturating.increment(epochs[vendor] ?? 0)
        policyVersion = Saturating.increment(policyVersion)
    }

    /// Ships a new app build; quarantined vendors get one isolated probe.
    public func upgradeApp() {
        let parts = appVersion.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 1
        let minor = parts.count > 1 ? parts[1] : 0
        appVersion = "\(major).\(Saturating.increment(minor))"
    }

    // MARK: - Plumbing

    private func pushSimulatorInputs() async {
        var rules: [VendorID: VendorRule] = [:]
        for id in vendorIDs {
            var rule = compiledPolicy.rules[id] ?? VendorRule()
            rule.enabled = rule.enabled && !killed.contains(id)
            rule.quarantineEpoch = epochs[id] ?? 0
            rules[id] = rule
        }
        await simulator.setRemotePolicy(PolicyDocument(version: policyVersion, rules: rules))
        await simulator.setAppVersion(appVersion)
        for id in vendorIDs {
            let fault = faults[id] ?? SimulatedFault.none
            await simulator.setFault(fault, for: id)
            // A poisoned vendor config: the flag name the SDK dereferences is null.
            let flag: PayloadValue = fault == .nullFlagCrashOnStart ? .null : .string("enabled")
            await simulator.setPayload([SimulatedVendor.flagKey: flag], for: id)
        }
    }

    private func apply(_ snapshot: RuntimeSnapshot) {
        vendorRows = snapshot.vendors.map { status in
            let (state, healthy) = Self.describe(status.lifecycle, terminated: snapshot.terminated)
            return VendorRow(
                id: status.id, stage: status.stage, state: state, isHealthy: healthy,
                strikes: status.health.strikes, quarantined: status.health.quarantine != nil,
                buffered: status.buffered, sent: status.sent, dropped: status.dropped
            )
        }
        policySummary = switch snapshot.policySource {
        case .fresh(let v): "fresh policy v\(v)"
        case .lastKnownGood(let v, let stale): "last-known-good v\(v)\(stale ? " (stale: restrict-only)" : "")"
        case .compiledDefault: "compiled-in default"
        }
    }

    static func row(for record: LaunchRecord) -> LaunchRow {
        let quarantined = record.snapshot.vendors.filter { $0.health.quarantine != nil }.map(\.id.rawValue)
        let headline: String
        if let culprit = record.crashedBy {
            headline = "Crashed: \(culprit) took the app down"
        } else if quarantined.isEmpty {
            headline = "Up: all enabled vendors started"
        } else {
            headline = "Up: \(quarantined.joined(separator: ", ")) contained"
        }
        return LaunchRow(
            id: record.number,
            crashedBy: record.crashedBy,
            headline: headline,
            details: record.snapshot.findings.map(\.description)
        )
    }

    static func describe(_ lifecycle: VendorLifecycle, terminated: Bool) -> (String, Bool) {
        switch lifecycle {
        case .pending: (terminated ? "never started (process died)" : "pending", !terminated)
        case .starting: ("crashed during start", false)
        case .running(let stable): (stable ? "running · stable" : (terminated ? "crashed on probation" : "running · probation"), stable || !terminated)
        case .skipped(let reason): (reason.description, false)
        }
    }

    static func describe(_ delivery: Delivery) -> String {
        switch delivery {
        case .sent: "sent"
        case .buffered: "buffered"
        case .bufferedVolatile: "buffered (not durable)"
        case .dropped(let reason): "dropped (\(reason.rawValue))"
        }
    }
}
