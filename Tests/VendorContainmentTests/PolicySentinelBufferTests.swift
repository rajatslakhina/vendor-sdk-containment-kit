import Foundation
import XCTest
@testable import VendorContainment

final class PolicyTests: XCTestCase {
    let a: VendorID = "analytics"
    let b: VendorID = "attribution"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    var resolver: PolicyResolver {
        PolicyResolver(
            compiledDefault: PolicyDocument(version: 0, rules: [a: VendorRule(rolloutPercent: 10), b: .off]),
            maxStaleness: 3_600
        )
    }

    func testNoNetworkNoCacheUsesCompiledDefaultAndUnknownVendorsFailClosed() {
        let r = resolver.resolve(candidate: nil, cache: nil, vendors: [a, b, "unknown"], now: t0)
        XCTAssertEqual(r.source, .compiledDefault)
        XCTAssertEqual(r.rules[a]?.rolloutPercent, 10)
        XCTAssertEqual(r.rules["unknown"], .off)
    }

    func testValidCandidateIsAcceptedAndCached() {
        let doc = PolicyDocument(version: 3, rules: [a: VendorRule()])
        let r = resolver.resolve(candidate: doc, cache: nil, vendors: [a], now: t0)
        XCTAssertEqual(r.source, .fresh(version: 3))
        XCTAssertEqual(r.cache, CachedPolicy(document: doc, fetchedAt: t0))
    }

    func testRollbackAndVersionReuseFallBackToLastKnownGood() {
        let cached = CachedPolicy(document: PolicyDocument(version: 5, rules: [a: VendorRule(enabled: false)]), fetchedAt: t0)
        let older = PolicyDocument(version: 4, rules: [a: VendorRule()])
        let r1 = resolver.resolve(candidate: older, cache: cached, vendors: [a], now: t0)
        XCTAssertEqual(r1.rejections, [.rollback(candidate: 4, lastKnownGood: 5)])
        XCTAssertEqual(r1.rules[a]?.enabled, false, "a kill must survive a rollback attempt")

        let reused = PolicyDocument(version: 5, rules: [a: VendorRule()])
        let r2 = resolver.resolve(candidate: reused, cache: cached, vendors: [a], now: t0)
        XCTAssertEqual(r2.rejections, [.versionReuse(5)])
        XCTAssertEqual(r2.source, .lastKnownGood(version: 5, stale: false))

        let identical = resolver.resolve(candidate: cached.document, cache: cached, vendors: [a], now: t0)
        XCTAssertEqual(identical.rejections, [])
    }

    func testMalformedDocumentsAreRejected() {
        let doc = PolicyDocument(version: 0, rules: [a: VendorRule(rolloutPercent: 101), b: VendorRule(quarantineEpoch: -1)])
        XCTAssertEqual(PolicyResolver.validate(doc), [.nonPositiveVersion(0), .rolloutOutOfRange(a, 101), .negativeEpoch(b)])
        let r = resolver.resolve(candidate: doc, cache: nil, vendors: [a], now: t0)
        XCTAssertEqual(r.source, .compiledDefault)
    }

    func testFreshCacheIsTrustedEvenWhereItGrants() {
        let cached = CachedPolicy(document: PolicyDocument(version: 2, rules: [a: VendorRule(), b: VendorRule()]), fetchedAt: t0)
        let r = resolver.resolve(candidate: nil, cache: cached, vendors: [a, b], now: t0.addingTimeInterval(60))
        XCTAssertEqual(r.rules[a]?.rolloutPercent, 100)
        XCTAssertEqual(r.rules[b]?.enabled, true)
    }

    func testStaleCacheCanOnlyRestrict() {
        let cached = CachedPolicy(
            document: PolicyDocument(version: 2, rules: [a: VendorRule(), b: VendorRule(), "remote-only": VendorRule()]),
            fetchedAt: t0
        )
        let r = resolver.resolve(candidate: nil, cache: cached, vendors: [a, b, "remote-only"], now: t0.addingTimeInterval(7_200))
        XCTAssertEqual(r.source, .lastKnownGood(version: 2, stale: true))
        XCTAssertEqual(r.rules[a]?.rolloutPercent, 10)
        XCTAssertEqual(r.rules[b]?.enabled, false)
        XCTAssertEqual(r.rules["remote-only"]?.enabled, false)
    }

    func testClockMovingBackwardsCountsAsStale() {
        let cached = CachedPolicy(document: PolicyDocument(version: 2, rules: [b: VendorRule()]), fetchedAt: t0)
        let r = resolver.resolve(candidate: nil, cache: cached, vendors: [b], now: t0.addingTimeInterval(-60))
        XCTAssertEqual(r.source, .lastKnownGood(version: 2, stale: true))
        XCTAssertEqual(r.rules[b]?.enabled, false)
    }

    /// The property the README claims: under staleness the effective rule is
    /// never more permissive than the compiled default. The checker is run
    /// against the real `meet` *and* a deliberately broken "remote wins"
    /// combiner, and must reject the broken one.
    func testStalenessPropertyCheckerCatchesABrokenCombiner() {
        func violations(_ combine: (VendorRule, VendorRule) -> VendorRule) -> Int {
            var count = 0
            for e1 in [true, false] {
                for e2 in [true, false] {
                    for p1 in [0, 10, 50, 100] {
                        for p2 in [0, 10, 50, 100] {
                            for h1 in [DisabledEventHandling.buffer, .drop] {
                                for h2 in [DisabledEventHandling.buffer, .drop] {
                                    let remote = VendorRule(enabled: e1, rolloutPercent: p1, whenDisabled: h1)
                                    let compiled = VendorRule(enabled: e2, rolloutPercent: p2, whenDisabled: h2)
                                    let out = combine(remote, compiled)
                                    if (out.enabled && !compiled.enabled) || out.rolloutPercent > compiled.rolloutPercent
                                        || (compiled.whenDisabled == .drop && out.whenDisabled != .drop) {
                                        count += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return count
        }
        XCTAssertEqual(violations { $0.meet($1) }, 0)
        XCTAssertGreaterThan(violations { remote, _ in remote }, 0, "the checker must be able to fail")
    }
}

final class SentinelTests: XCTestCase {
    let a: VendorID = "analytics"
    let b: VendorID = "attribution"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let config = SentinelConfiguration(strikeThreshold: 2, baseCooldown: 100, maxCooldown: 350)

    func recover(_ s: SentinelState, at t: TimeInterval = 0, version: String = "1.0", epochs: [VendorID: Int] = [:])
        -> (SentinelState, [SentinelFinding]) {
        LaunchSentinel.recover(s, configuration: config, now: t0.addingTimeInterval(t), appVersion: version, epochs: epochs)
    }

    func crashedWhileStarting(_ v: VendorID, from s: SentinelState) -> SentinelState {
        var s = s
        s.markers = [v: .starting]
        return s
    }

    func testStartingMarkerIsAnAttributedStrikeAndThresholdQuarantines() {
        let (s1, f1) = recover(crashedWhileStarting(b, from: SentinelState()))
        XCTAssertEqual(s1.health[b]?.strikes, 1)
        XCTAssertNil(s1.health[b]?.quarantine)
        XCTAssertEqual(f1, [.crashAttributed(b, strikes: 1)])
        XCTAssertTrue(s1.markers.isEmpty)

        let (s2, f2) = recover(crashedWhileStarting(b, from: s1))
        XCTAssertEqual(s2.health[b]?.quarantine?.cooldown, 100)
        XCTAssertTrue(s2.health[b]?.isBlocked ?? false)
        XCTAssertEqual(f2.last, .quarantined(b, cooldown: 100))
    }

    func testAStableLaunchResetsStrikes() {
        var (s, _) = recover(crashedWhileStarting(b, from: SentinelState()))
        _ = LaunchSentinel.markStable(b, in: &s)
        let (s2, _) = recover(crashedWhileStarting(b, from: s))
        XCTAssertEqual(s2.health[b]?.strikes, 1, "strikes are consecutive")
        XCTAssertNil(s2.health[b]?.quarantine)
    }

    func testCleanPreviousLaunchProducesNoFindings() {
        let (s, f) = recover(SentinelState())
        XCTAssertEqual(f, [])
        XCTAssertEqual(s.launchCount, 1)
    }

    func testSingleProbationMarkerIsAttributed() {
        var s = SentinelState()
        s.markers = [a: .probation(since: t0)]
        XCTAssertEqual(recover(s).1, [.crashAttributed(a, strikes: 1)])
    }

    func testSeveralProbationMarkersAreAmbiguousNotBlamed() {
        var s = SentinelState()
        s.markers = [a: .probation(since: t0), b: .probation(since: t0)]
        let (out, findings) = recover(s)
        XCTAssertEqual(findings, [.ambiguousCrash([a, b])])
        XCTAssertEqual(out.health[a]?.strikes, 0)
        XCTAssertEqual(out.health[a]?.suspect, true)
        XCTAssertEqual(out.health[b]?.needsIsolation, true)
    }

    func testTwoStartingMarkersMeansCorruptionAndBlamesNobody() {
        var s = SentinelState()
        s.markers = [a: .starting, b: .starting]
        let (out, findings) = recover(s)
        XCTAssertEqual(findings, [.ambiguousCrash([a, b])])
        XCTAssertEqual(out.health[a]?.strikes ?? 0, 0)
    }

    func quarantined() -> SentinelState {
        recover(crashedWhileStarting(b, from: recover(crashedWhileStarting(b, from: SentinelState())).0)).0
    }

    func testCooldownProbeAndRequarantineDoublesUpToCap() {
        let q = quarantined()
        let (early, _) = recover(q, at: 50)
        XCTAssertTrue(early.health[b]?.isBlocked ?? false)

        var (probe, f) = recover(q, at: 100)
        XCTAssertEqual(f, [.probing(b, reason: .cooldownElapsed)])
        XCTAssertEqual(probe.health[b]?.needsIsolation, true)

        probe.markers = [b: .starting]
        let (re, f2) = recover(probe, at: 101)
        XCTAssertEqual(re.health[b]?.quarantine?.cooldown, 200)
        XCTAssertEqual(re.health[b]?.quarantine?.trips, 2)
        XCTAssertTrue(f2.contains(.requarantined(b, cooldown: 200)))

        var re2 = recover(re, at: 301).0
        re2.markers = [b: .starting]
        let capped = recover(re2, at: 302).0
        XCTAssertEqual(capped.health[b]?.quarantine?.cooldown, 350, "capped at maxCooldown")
    }

    func testSuccessfulProbeClosesTheCircuit() {
        var (probe, _) = recover(quarantined(), at: 100)
        _ = LaunchSentinel.markStable(b, in: &probe)
        XCTAssertEqual(probe.health[b], VendorHealth())
    }

    func testEpochBumpReleasesAndUpgradeOnlyProbes() {
        let q = quarantined()
        let (released, f) = recover(q, at: 1, epochs: [b: 1])
        XCTAssertEqual(released.health[b], VendorHealth())
        XCTAssertEqual(f, [.releasedByEpoch(b)])

        let (upgraded, f2) = recover(q, at: 1, version: "1.1")
        XCTAssertEqual(upgraded.health[b]?.probing, true)
        XCTAssertNotNil(upgraded.health[b]?.quarantine)
        XCTAssertEqual(f2, [.probing(b, reason: .appUpgraded)])
    }

    func testClockMovingBackwardsNeverShortensAQuarantine() {
        let (s, f) = recover(quarantined(), at: -10_000)
        XCTAssertTrue(s.health[b]?.isBlocked ?? false)
        XCTAssertEqual(f, [])
    }

    func testLaunchCountSaturates() {
        var s = SentinelState()
        s.launchCount = UInt64.max
        XCTAssertEqual(recover(s).0.launchCount, UInt64.max)
    }
}

final class EventBufferTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ name: String, _ privacy: PrivacyClass = .anonymous, at t: TimeInterval = 0) -> ContainedEvent {
        ContainedEvent(name: name, privacy: privacy, at: t0.addingTimeInterval(t))
    }

    func testOverflowEvictsOnlyTheNoisyVendorsOwnOldest() {
        var buffer = EventBuffer(capacityPerVendor: 2)
        buffer.append(event("quiet-1"), for: "quiet")
        buffer.append(event("n1"), for: "noisy")
        buffer.append(event("n2"), for: "noisy")
        XCTAssertEqual(buffer.append(event("n3"), for: "noisy"), .bufferedEvictingOldest)
        XCTAssertEqual(buffer.pending(for: "noisy").map(\.event.name), ["n2", "n3"])
        XCTAssertEqual(buffer.pending(for: "quiet").map(\.event.name), ["quiet-1"])
        XCTAssertEqual(buffer.evicted, 1)
    }

    func testPersonalEventsAreNeverBuffered() {
        var buffer = EventBuffer(capacityPerVendor: 10)
        XCTAssertEqual(buffer.append(event("email", .personal), for: "a"), .refusedPersonal)
        XCTAssertEqual(buffer.totalCount, 0)
    }

    func testZeroCapacityRefuses() {
        var buffer = EventBuffer(capacityPerVendor: 0)
        XCTAssertEqual(buffer.append(event("x"), for: "a"), .refusedNoCapacity)
    }

    func testExpiryAndNonsenseMaxAge() {
        var buffer = EventBuffer(capacityPerVendor: 10)
        buffer.append(event("old", at: 0), for: "a")
        buffer.append(event("new", at: 90), for: "a")
        buffer.expire(olderThan: -1, now: t0.addingTimeInterval(100))
        XCTAssertEqual(buffer.count(for: "a"), 2, "a negative maxAge must expire nothing")
        buffer.expire(olderThan: .nan, now: t0.addingTimeInterval(100))
        XCTAssertEqual(buffer.count(for: "a"), 2)
        buffer.expire(olderThan: 50, now: t0.addingTimeInterval(100))
        XCTAssertEqual(buffer.pending(for: "a").map(\.event.name), ["new"])
        XCTAssertEqual(buffer.expired, 1)
    }

    func testRemoveHeadOnlyRemovesTheExpectedEvent() {
        var buffer = EventBuffer(capacityPerVendor: 1)
        buffer.append(event("first"), for: "a")
        let head = buffer.first(for: "a")
        buffer.append(event("second"), for: "a") // evicts "first"
        XCTAssertFalse(buffer.removeHead(for: "a", ifSeq: head?.seq ?? 0))
        XCTAssertEqual(buffer.pending(for: "a").map(\.event.name), ["second"])
    }
}

final class ReviewRegressionTests: XCTestCase {
    let a: VendorID = "analytics"
    let b: VendorID = "attribution"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// One vendor in `start()` while another is on probation: the crash may
    /// have come from either. With threshold 1, a naive rule would
    /// quarantine the starting vendor on this single, ambiguous crash.
    func testCrashInStartWithOthersOnProbationIsOnlyProvisional() {
        var s = SentinelState()
        s.markers = [a: .probation(since: t0), b: .starting]
        let strict = SentinelConfiguration(strikeThreshold: 1, baseCooldown: 100, maxCooldown: 100)
        let (out, findings) = LaunchSentinel.recover(s, configuration: strict, now: t0, appVersion: "1", epochs: [:])
        XCTAssertEqual(findings, [.crashProbablyAttributed(b, strikes: 0, alsoRunning: [a])])
        XCTAssertNil(out.health[b]?.quarantine, "a provisional strike can never quarantine by itself")
        XCTAssertEqual(out.health[b]?.needsIsolation, true)
        XCTAssertEqual(out.health[a]?.needsIsolation, true)

        let normal = SentinelConfiguration(strikeThreshold: 2, baseCooldown: 100, maxCooldown: 100)
        let (out2, _) = LaunchSentinel.recover(s, configuration: normal, now: t0, appVersion: "1", epochs: [:])
        XCTAssertEqual(out2.health[b]?.strikes, 1)
        XCTAssertNil(out2.health[b]?.quarantine)
    }

    func testFindingDescriptionsNeverTrapAndHugeDurationsAreRejected() {
        XCTAssertEqual(SentinelFinding.quarantined(b, cooldown: 1e300).description.isEmpty, false)
        XCTAssertEqual(SentinelFinding.requarantined(b, cooldown: .infinity).description, "attribution failed its probe; quarantined for ∞")
        var config = ContainmentConfiguration()
        config.sentinel = SentinelConfiguration(strikeThreshold: 2, baseCooldown: 1e19, maxCooldown: 1e19)
        XCTAssertThrowsError(try config.validate())
    }

    /// Object members are walked in key order, so the first structural
    /// violation reported doesn't depend on dictionary layout.
    func testValidatorResultIsIndependentOfDictionaryLayout() {
        var deep = PayloadValue.null
        for _ in 0..<20 { deep = .array([deep]) }
        let long = PayloadValue.string(String(repeating: "x", count: 5_000))
        var small: VendorPayload = [:]
        small["a"] = deep
        small["b"] = long
        var big = VendorPayload(minimumCapacity: 4_096)
        big["b"] = long
        big["a"] = deep
        for payload in [small, big] {
            XCTAssertEqual(PayloadValidator.validate(payload, against: .permissive), [.tooDeep(limit: 8)])
        }
    }

    func testStaleMeetKeepsTheNewestQuarantineEpoch() {
        let merged = VendorRule(quarantineEpoch: 3).meet(VendorRule(quarantineEpoch: 0))
        XCTAssertEqual(merged.quarantineEpoch, 3, "a remote release must survive staleness")
    }

    func testPayloadKeysAndWideObjectsAreBounded() {
        let longKey = String(repeating: "k", count: 5_000)
        XCTAssertEqual(PayloadValidator.validate([longKey: .null], against: .permissive), [.stringTooLong(limit: 4_096)])
        let nestedKey: VendorPayload = ["o": .object([longKey: .null])]
        XCTAssertEqual(PayloadValidator.validate(nestedKey, against: .permissive), [.stringTooLong(limit: 4_096)])
        var wide: [String: PayloadValue] = [:]
        for i in 0..<2_500 { wide["k\(i)"] = .null }
        XCTAssertEqual(PayloadValidator.validate(["o": .object(wide)], against: .permissive), [.tooManyNodes(limit: 2_000)])
    }

    /// Extreme thresholds on the provisional path must clamp, not trap
    /// (`Int.min - 1` would overflow).
    func testExtremeThresholdsNeverTrap() {
        var s = SentinelState()
        s.markers = [a: .probation(since: t0), b: .starting]
        for threshold in [Int.min, -1, 0, Int.max] {
            let config = SentinelConfiguration(strikeThreshold: threshold, baseCooldown: 1, maxCooldown: 1)
            let (out, _) = LaunchSentinel.recover(s, configuration: config, now: t0, appVersion: "1", epochs: [:])
            XCTAssertEqual(out.health[b]?.strikes, threshold == Int.max ? 1 : 0, "threshold \(threshold)")
            XCTAssertNil(out.health[b]?.quarantine, "threshold \(threshold): a probable-only crash must never quarantine")
        }
    }

    func testResizePreservesOrderAndCounters() {
        var buffer = EventBuffer(capacityPerVendor: 5)
        for i in 0..<4 { buffer.append(ContainedEvent(name: "e\(i)", privacy: .anonymous, at: t0), for: a) }
        buffer.append(ContainedEvent(name: "p", privacy: .personal, at: t0), for: a)
        let resized = buffer.resized(to: 2)
        XCTAssertEqual(resized.pending(for: a).map(\.event.name), ["e2", "e3"])
        XCTAssertEqual(resized.evicted, 2)
        XCTAssertEqual(resized.refused, 1, "lifetime counters survive a resize")
        XCTAssertEqual(resized.nextSeq, buffer.nextSeq)
    }

    func testFileStoreRoundTripsAndTreatsCorruptionAsNoHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("containment.json")
        let store = FileContainmentStore(url: url)
        XCTAssertNil(store.load())

        var state = PersistedState(buffer: EventBuffer(capacityPerVendor: 3))
        state.sentinel.markers[a] = .starting
        state.sentinel.health[b] = VendorHealth()
        state.buffer.append(ContainedEvent(name: "x", privacy: .anonymous, at: t0), for: a)
        try store.save(state)
        XCTAssertEqual(store.load(), state)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"analytics\""), "VendorID keys encode as JSON object keys")

        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(store.load(), "corrupt file = no history, never a crash")
    }
}
