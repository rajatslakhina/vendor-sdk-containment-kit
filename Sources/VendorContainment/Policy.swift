import Foundation

/// What happens to a vendor's events while the *app's own* policy has it off.
public enum DisabledEventHandling: String, Codable, Sendable {
    /// Queue and replay when re-enabled (an operational pause).
    case buffer
    /// Discard (a legal or privacy kill, where keeping the data is the problem).
    case drop
}

/// The app's own rule for one vendor, served from the app's own control plane.
/// This is the kill switch you control, as opposed to the vendor's.
public struct VendorRule: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// `0...100`. Anything outside that range rejects the whole document.
    public var rolloutPercent: Int
    public var whenDisabled: DisabledEventHandling
    /// Bump to release a crash quarantine ("the vendor shipped a fix").
    public var quarantineEpoch: Int

    public init(
        enabled: Bool = true,
        rolloutPercent: Int = 100,
        whenDisabled: DisabledEventHandling = .buffer,
        quarantineEpoch: Int = 0
    ) {
        self.enabled = enabled
        self.rolloutPercent = rolloutPercent
        self.whenDisabled = whenDisabled
        self.quarantineEpoch = quarantineEpoch
    }

    public static let off = VendorRule(enabled: false, rolloutPercent: 0, whenDisabled: .drop)

    /// The more restrictive of two rules: the lattice *meet*.
    ///
    /// Used when the cached policy is stale: staleness may only ever take
    /// capability away, never grant it.
    public func meet(_ other: VendorRule) -> VendorRule {
        VendorRule(
            enabled: enabled && other.enabled,
            rolloutPercent: min(rolloutPercent, other.rolloutPercent),
            whenDisabled: (whenDisabled == .drop || other.whenDisabled == .drop) ? .drop : .buffer,
            // An epoch is a release token, not a capability; keep the newest.
            quarantineEpoch: max(quarantineEpoch, other.quarantineEpoch)
        )
    }
}

/// A versioned policy document from the app's own server.
public struct PolicyDocument: Codable, Sendable, Equatable {
    public var version: Int
    public var rules: [VendorID: VendorRule]

    public init(version: Int, rules: [VendorID: VendorRule]) {
        self.version = version
        self.rules = rules
    }
}

/// The last document that passed validation, and when it was fetched.
public struct CachedPolicy: Codable, Sendable, Equatable {
    public var document: PolicyDocument
    public var fetchedAt: Date

    public init(document: PolicyDocument, fetchedAt: Date) {
        self.document = document
        self.fetchedAt = fetchedAt
    }
}

public enum PolicyRejection: Sendable, Equatable, CustomStringConvertible {
    case nonPositiveVersion(Int)
    case rollback(candidate: Int, lastKnownGood: Int)
    case versionReuse(Int)
    case rolloutOutOfRange(VendorID, Int)
    case negativeEpoch(VendorID)

    public var description: String {
        switch self {
        case .nonPositiveVersion(let v): "version \(v) is not positive"
        case .rollback(let c, let l): "version \(c) is older than last-known-good \(l)"
        case .versionReuse(let v): "version \(v) was reused with a different body"
        case .rolloutOutOfRange(let id, let p): "\(id): rollout \(p)% is outside 0...100"
        case .negativeEpoch(let id): "\(id): negative quarantine epoch"
        }
    }
}

public enum PolicySource: Sendable, Equatable {
    case fresh(version: Int)
    case lastKnownGood(version: Int, stale: Bool)
    case compiledDefault
}

public struct PolicyResolution: Sendable, Equatable {
    public var source: PolicySource
    public var rules: [VendorID: VendorRule]
    public var cache: CachedPolicy?
    public var rejections: [PolicyRejection]
}

/// Validates fetched policy, maintains last-known-good, and degrades safely.
///
/// - A candidate is accepted only if it validates and is not older than the
///   cached version. Re-serving the same version with a different body is
///   rejected too: that's a config change that skipped review.
/// - Any problem (no network, bad document) falls back to last-known-good, so
///   a kill you sent yesterday survives a dead control plane today.
/// - A cache older than `maxStaleness` (or dated in the future, i.e. the clock
///   moved backwards) is *met* with the compiled-in default per vendor, so it
///   can restrict but never grant.
/// - A vendor named in neither document is off. Unknown vendors fail closed.
public struct PolicyResolver: Sendable {
    public let compiledDefault: PolicyDocument
    public let maxStaleness: TimeInterval

    public init(compiledDefault: PolicyDocument, maxStaleness: TimeInterval) {
        self.compiledDefault = compiledDefault
        self.maxStaleness = maxStaleness
    }

    public static func validate(_ document: PolicyDocument) -> [PolicyRejection] {
        var out: [PolicyRejection] = []
        if document.version <= 0 { out.append(.nonPositiveVersion(document.version)) }
        for (id, rule) in document.rules.sorted(by: { $0.key < $1.key }) {
            if !(0...100).contains(rule.rolloutPercent) { out.append(.rolloutOutOfRange(id, rule.rolloutPercent)) }
            if rule.quarantineEpoch < 0 { out.append(.negativeEpoch(id)) }
        }
        return out
    }

    public func resolve(
        candidate: PolicyDocument?,
        cache: CachedPolicy?,
        vendors: [VendorID],
        now: Date
    ) -> PolicyResolution {
        var rejections: [PolicyRejection] = []
        var accepted: CachedPolicy?

        if let candidate {
            rejections = Self.validate(candidate)
            if rejections.isEmpty, let cache {
                if candidate.version < cache.document.version {
                    rejections.append(.rollback(candidate: candidate.version, lastKnownGood: cache.document.version))
                } else if candidate.version == cache.document.version, candidate != cache.document {
                    rejections.append(.versionReuse(candidate.version))
                }
            }
            if rejections.isEmpty { accepted = CachedPolicy(document: candidate, fetchedAt: now) }
        }

        let effective = accepted ?? cache
        let source: PolicySource
        var rules: [VendorID: VendorRule] = [:]

        if let effective {
            let age = now.timeIntervalSince(effective.fetchedAt)
            let stale = !(age >= 0 && age <= maxStaleness)
            source = accepted != nil
                ? .fresh(version: effective.document.version)
                : .lastKnownGood(version: effective.document.version, stale: stale)
            for vendor in vendors {
                let compiled = compiledDefault.rules[vendor]
                switch (effective.document.rules[vendor], compiled) {
                case let (remote?, compiled?): rules[vendor] = stale ? remote.meet(compiled) : remote
                case let (remote?, nil): rules[vendor] = stale ? remote.meet(.off) : remote
                case let (nil, compiled?): rules[vendor] = compiled
                case (nil, nil): rules[vendor] = .off
                }
            }
        } else {
            source = .compiledDefault
            for vendor in vendors { rules[vendor] = compiledDefault.rules[vendor] ?? .off }
        }
        return PolicyResolution(source: source, rules: rules, cache: effective, rejections: rejections)
    }
}
