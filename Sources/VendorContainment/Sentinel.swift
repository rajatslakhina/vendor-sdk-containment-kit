import Foundation

/// A durable "this vendor is in flight" marker, written *before* the vendor
/// runs and removed only once it has survived the stability window.
///
/// If the process dies, the marker is still on disk at the next launch, and
/// that is the whole detection mechanism. It needs no crash reporter, no
/// signal handler and no network.
public enum MarkerPhase: Codable, Sendable, Equatable {
    /// Inside `start()`. Vendors start one at a time, so at most one vendor is
    /// ever in this phase. A crash here is attributed to it *unambiguously*
    /// only if nothing else was on probation at the time; otherwise it is a
    /// *probable* attribution (see ``LaunchSentinel/recover``).
    case starting
    /// `start()` returned; the vendor is running but not yet trusted. Several
    /// vendors can be here at once, so a crash here may be ambiguous.
    case probation(since: Date)
}

/// A vendor that crashed the app and is not started until released.
public struct Quarantine: Codable, Sendable, Equatable {
    public var since: Date
    public var cooldown: TimeInterval
    public var trips: Int
    /// The policy epoch when the quarantine began; a higher epoch releases it.
    public var epoch: Int
    /// The app build that crashed. A new build earns a probe, not a pardon.
    public var appVersion: String
}

/// Crash bookkeeping for one vendor.
public struct VendorHealth: Codable, Sendable, Equatable {
    /// Consecutive attributed crash launches. Reset by one stable launch.
    public var strikes: Int = 0
    /// Implicated in an ambiguous crash; started in isolation next time.
    public var suspect: Bool = false
    public var quarantine: Quarantine?
    /// Half-open: quarantined, but allowed one isolated probe this launch.
    public var probing: Bool = false

    public init() {}

    public var isBlocked: Bool { quarantine != nil && !probing }
    /// Anything with a strike, a suspicion, or a probe runs its stability
    /// window alone, so if it crashes again the blame is unambiguous.
    public var needsIsolation: Bool { suspect || probing || strikes > 0 }
}

/// Everything the sentinel persists between launches.
public struct SentinelState: Codable, Sendable, Equatable {
    public var launchCount: UInt64 = 0
    public var markers: [VendorID: MarkerPhase] = [:]
    public var health: [VendorID: VendorHealth] = [:]

    public init() {}
}

public enum SentinelFinding: Sendable, Equatable, CustomStringConvertible {
    case crashAttributed(VendorID, strikes: Int)
    /// Crashed inside this vendor's `start()` while others were on probation.
    case crashProbablyAttributed(VendorID, strikes: Int, alsoRunning: [VendorID])
    case ambiguousCrash([VendorID])
    case quarantined(VendorID, cooldown: TimeInterval)
    case requarantined(VendorID, cooldown: TimeInterval)
    case releasedByEpoch(VendorID)
    case probing(VendorID, reason: ProbeReason)
    case stable(VendorID)

    public enum ProbeReason: String, Sendable { case cooldownElapsed, appUpgraded }

    /// Formats a duration without `Int(Double)`, which traps above `Int.max`.
    static func seconds(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "∞" }
        return String(format: "%.0fs", value)
    }

    public var description: String {
        switch self {
        case .crashAttributed(let v, let s): "previous launch crashed while \(v) was in flight (strike \(s))"
        case .crashProbablyAttributed(let v, let s, let others):
            "previous launch crashed in \(v).start() with \(others.map(\.rawValue).joined(separator: ", ")) on probation (provisional strike \(s); isolating)"
        case .ambiguousCrash(let vs): "previous launch crashed with \(vs.map(\.rawValue).joined(separator: ", ")) on probation; isolating"
        case .quarantined(let v, let c): "\(v) quarantined for \(Self.seconds(c))"
        case .requarantined(let v, let c): "\(v) failed its probe; quarantined for \(Self.seconds(c))"
        case .releasedByEpoch(let v): "\(v) released by policy epoch"
        case .probing(let v, let r): "\(v) gets one isolated probe (\(r.rawValue))"
        case .stable(let v): "\(v) survived the stability window"
        }
    }
}

public struct SentinelConfiguration: Sendable, Equatable {
    public var strikeThreshold: Int
    public var baseCooldown: TimeInterval
    public var maxCooldown: TimeInterval

    public init(strikeThreshold: Int = 2, baseCooldown: TimeInterval = 3_600, maxCooldown: TimeInterval = 7 * 86_400) {
        self.strikeThreshold = strikeThreshold
        self.baseCooldown = baseCooldown
        self.maxCooldown = maxCooldown
    }
}

/// Pure crash-attribution logic: previous launch's leftovers in, verdicts out.
public enum LaunchSentinel {
    /// Interprets whatever markers the previous launch left behind, then
    /// applies release rules. Pure: same input, same output, no I/O.
    public static func recover(
        _ previous: SentinelState,
        configuration: SentinelConfiguration,
        now: Date,
        appVersion: String,
        epochs: [VendorID: Int]
    ) -> (SentinelState, [SentinelFinding]) {
        var state = previous
        var findings: [SentinelFinding] = []
        state.launchCount = Saturating.increment(state.launchCount)

        let starting = previous.markers.filter { $0.value == .starting }.keys.sorted()
        let onProbation = previous.markers.filter { $0.value != .starting }.keys.sorted()
        state.markers = [:]

        // A probe that didn't crash was cleared by `settle`; anything still
        // `probing` here either crashed (handled below) or was cut short by
        // a non-crash exit, so it simply probes again.
        // Attribution rules, strongest evidence first:
        // - exactly one marker in total, `.starting` or `.probation`:
        //   unambiguous, a full strike.
        // - one `.starting` plus others on probation: *probable*. The vendor
        //   in `start()` gets a strike capped below the threshold, and every
        //   vendor involved runs isolated next launch. Quarantine therefore
        //   always requires at least one unambiguous strike, so a
        //   coincidental background crash can't quarantine an innocent SDK.
        // - several on probation, nobody starting: ambiguous, no strike,
        //   all suspects.
        // - more than one `.starting`: impossible under serial start, so the
        //   store is corrupt. Blame nobody.
        var culprits: [VendorID] = []
        var provisional: Set<VendorID> = []
        if starting.count > 1 {
            findings.append(.ambiguousCrash(starting))
            for v in starting { state.health[v, default: VendorHealth()].suspect = true }
        } else if starting.count == 1 {
            culprits = starting
            if !onProbation.isEmpty {
                provisional = Set(starting)
                for v in onProbation { state.health[v, default: VendorHealth()].suspect = true }
            }
        } else if onProbation.count == 1 {
            culprits = onProbation
        } else if !onProbation.isEmpty {
            findings.append(.ambiguousCrash(onProbation))
            for v in onProbation { state.health[v, default: VendorHealth()].suspect = true }
        }

        for vendor in culprits {
            var h = state.health[vendor, default: VendorHealth()]
            let isProvisional = provisional.contains(vendor)
            h.strikes = Saturating.increment(h.strikes)
            if isProvisional {
                h.strikes = min(h.strikes, max(0, configuration.strikeThreshold - 1))
                h.suspect = true
                findings.append(.crashProbablyAttributed(vendor, strikes: h.strikes, alsoRunning: onProbation))
            } else {
                h.suspect = false
                findings.append(.crashAttributed(vendor, strikes: h.strikes))
            }
            if isProvisional, h.probing {
                // A probe that died alongside others proves nothing either
                // way: stay quarantined, probe again (isolated) next launch.
                state.health[vendor] = h
                continue
            } else if h.probing, var q = h.quarantine {
                q.cooldown = Saturating.doubled(q.cooldown, cap: configuration.maxCooldown)
                q.trips = Saturating.increment(q.trips)
                q.since = now
                q.appVersion = appVersion
                h.quarantine = q
                h.probing = false
                findings.append(.requarantined(vendor, cooldown: q.cooldown))
            } else if h.quarantine == nil, h.strikes >= configuration.strikeThreshold {
                let cooldown = min(configuration.baseCooldown, configuration.maxCooldown)
                h.quarantine = Quarantine(
                    since: now, cooldown: cooldown, trips: 1,
                    epoch: epochs[vendor] ?? 0, appVersion: appVersion
                )
                findings.append(.quarantined(vendor, cooldown: cooldown))
            }
            state.health[vendor] = h
        }

        for vendor in state.health.keys.sorted() {
            guard var h = state.health[vendor], let q = h.quarantine else { continue }
            if (epochs[vendor] ?? 0) > q.epoch {
                h = VendorHealth()
                findings.append(.releasedByEpoch(vendor))
            } else if !h.probing, !culprits.contains(vendor) {
                let elapsed = now.timeIntervalSince(q.since)
                if q.appVersion != appVersion {
                    h.probing = true
                    findings.append(.probing(vendor, reason: .appUpgraded))
                } else if elapsed >= 0, elapsed >= q.cooldown {
                    // `elapsed >= 0`: a clock that moved backwards never
                    // shortens a quarantine.
                    h.probing = true
                    findings.append(.probing(vendor, reason: .cooldownElapsed))
                }
            }
            state.health[vendor] = h
        }
        return (state, findings)
    }

    /// Marks a vendor as having survived its window. Clears strikes, suspicion
    /// and, for a probe, the quarantine itself (the circuit closes).
    public static func markStable(_ vendor: VendorID, in state: inout SentinelState) -> SentinelFinding {
        state.markers[vendor] = nil
        state.health[vendor] = VendorHealth()
        return .stable(vendor)
    }
}
