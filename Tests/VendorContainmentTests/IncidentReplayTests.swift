import Foundation
import XCTest
@testable import VendorContainment

/// End-to-end launches through the fault-injection harness. Each `launch()`
/// is a cold start; only the store survives a crash.
final class IncidentReplayTests: XCTestCase {
    let a = Fixture.a
    let b = Fixture.b
    let c = Fixture.c

    var three: [(id: VendorID, stage: StartupStage)] {
        [(a, .afterFirstFrame), (b, .afterFirstFrame), (c, .idle)]
    }

    func status(_ id: VendorID, _ record: LaunchRecord) -> VendorStatus? {
        record.snapshot.vendors.first { $0.id == id }
    }

    /// The headline claim: a vendor that crashes the app on start takes it
    /// down at most `strikeThreshold` times, and then the app stays up.
    func testPoisonedPayloadCrashesTwiceThenIsContained() async throws {
        var config = Fixture.config()
        config.validatesVendorPayloads = false // model a vendor-internal fetch we can't see
        let sim = Fixture.simulator(three, config: config)
        await sim.setFault(.nullFlagCrashOnStart, for: b)
        await sim.setPayload(Fixture.poisoned, for: b)

        let l1 = try await sim.launch()
        let l2 = try await sim.launch()
        let l3 = try await sim.launch()
        let l4 = try await sim.launch()
        XCTAssertEqual([l1, l2, l3, l4].map(\.crashedBy), [b, b, nil, nil])
        // Launch 1 died in b.start() while a was on probation: only a
        // provisional strike, and both vendors isolated. (A naive "blame
        // whoever was starting" design passes the sequence check above but
        // fails here.)
        XCTAssertEqual(l2.snapshot.findings.first, .crashProbablyAttributed(b, strikes: 1, alsoRunning: [a]))
        // In launch 2, a ran its whole window alone and was cleared before b
        // started; b then died alone.
        XCTAssertEqual(status(a, l2)?.lifecycle, .running(stable: true))
        XCTAssertTrue(l2.snapshot.findings.contains(.stable(a)))
        XCTAssertEqual(l3.snapshot.findings.first, .crashAttributed(b, strikes: 2))
        XCTAssertEqual(status(b, l3)?.lifecycle, .skipped(.quarantined))
        XCTAssertEqual(status(a, l3)?.lifecycle, .running(stable: true))
        XCTAssertEqual(status(c, l3)?.lifecycle, .running(stable: true))
        XCTAssertGreaterThan(status(b, l4)?.buffered ?? 0, 0, "the quarantined vendor's events are kept, not lost")
    }

    /// The same incident with the validation boundary on never crashes once.
    func testValidationBoundaryStopsThePoisonOnLaunchOne() async throws {
        let sim = Fixture.simulator(three)
        await sim.setFault(.nullFlagCrashOnStart, for: b)
        await sim.setPayload(Fixture.poisoned, for: b)
        let l1 = try await sim.launch()
        XCTAssertNil(l1.crashedBy)
        XCTAssertEqual(status(b, l1)?.lifecycle, .skipped(.payloadRejected([.nullValue(SimulatedVendor.flagKey)])))
    }

    /// Ops bumps the quarantine epoch once the vendor is fixed: the vendor
    /// starts, and every event buffered while it was out is replayed.
    func testEpochReleaseReplaysBufferedEvents() async throws {
        var config = Fixture.config()
        config.validatesVendorPayloads = false
        let sim = Fixture.simulator(three, config: config)
        await sim.setFault(.nullFlagCrashOnStart, for: b)
        await sim.setPayload(Fixture.poisoned, for: b)
        for _ in 0..<4 { try await sim.launch() }

        await sim.setFault(.none, for: b)
        await sim.setRemotePolicy(PolicyDocument(version: 2, rules: [
            a: VendorRule(), b: VendorRule(quarantineEpoch: 1), c: VendorRule(),
        ]))
        let l5 = try await sim.launch()
        XCTAssertNil(l5.crashedBy)
        XCTAssertTrue(l5.snapshot.findings.contains(.releasedByEpoch(b)))
        XCTAssertEqual(status(b, l5)?.lifecycle, .running(stable: true))
        // app_open from every launch b missed (1-4; the crashed ones were
        // queued before the crash and persisted) plus launch 5's own.
        XCTAssertEqual(sim.ledger.received(by: b).filter { $0 == "app_open" }.count, 5)
    }

    /// Two vendors on probation when the app dies: nobody is blamed blind.
    /// Isolation on the next launch pins the real culprit, and the innocent
    /// vendor never picks up a strike.
    func testAmbiguousCrashConvergesOnTheTrueCulpritOnly() async throws {
        let sim = Fixture.simulator([(a, .afterFirstFrame), (b, .afterFirstFrame)])
        await sim.setFault(.crashAfterStart, for: b)
        var records: [LaunchRecord] = []
        for _ in 0..<6 { records.append(try await sim.launch()) }

        XCTAssertEqual(records[1].snapshot.findings.first, .ambiguousCrash([a, b]))
        for record in records {
            XCTAssertEqual(status(a, record)?.health.strikes ?? 0, 0, "launch \(record.number): innocent vendor blamed")
            XCTAssertNil(status(a, record)?.health.quarantine)
        }
        XCTAssertNotNil(status(b, records[5])?.health.quarantine)
        XCTAssertNil(records[5].crashedBy)
        // Ground truth agrees with every attribution the sentinel made.
        for (prev, next) in zip(records, records.dropFirst()) {
            for case .crashAttributed(let blamed, _) in next.snapshot.findings {
                XCTAssertEqual(blamed, prev.crashedBy)
            }
        }
    }

    /// Negative control for the scenario above: the identical run with a
    /// store that forgets must crash every time. Paired with the positive
    /// test, it shows the containment comes from persisted evidence and not
    /// from anything in-process. (The save-*before*-start ordering is pinned
    /// separately by `testMarkerIsDurableBeforeVendorCodeRuns`.)
    func testWithAStoreThatForgetsTheAppCrashLoopsForever() async throws {
        var config = Fixture.config()
        config.validatesVendorPayloads = false
        let sim = Fixture.simulator(three, store: AmnesiacStore(), config: config)
        await sim.setFault(.nullFlagCrashOnStart, for: b)
        await sim.setPayload(Fixture.poisoned, for: b)
        var crashes = 0
        for _ in 0..<6 {
            if try await sim.launch().crashedBy == b { crashes += 1 }
        }
        XCTAssertEqual(crashes, 6)
    }

    func testCooldownProbeRequarantinesThenClosesWhenFixed() async throws {
        var config = Fixture.config()
        config.validatesVendorPayloads = false
        let sim = Fixture.simulator(three, config: config)
        await sim.setFault(.nullFlagCrashOnStart, for: b)
        await sim.setPayload(Fixture.poisoned, for: b)
        for _ in 0..<3 { try await sim.launch() }

        await sim.setRelaunchGap(3_700) // beyond the 3,600 s cooldown
        let probe = try await sim.launch()
        XCTAssertEqual(probe.crashedBy, b, "probe still crashes while the vendor is broken")
        await sim.setRelaunchGap(30)
        let after = try await sim.launch()
        XCTAssertNil(after.crashedBy)
        XCTAssertEqual(status(b, after)?.health.quarantine?.cooldown, 7_200)

        await sim.setFault(.none, for: b)
        await sim.setRelaunchGap(7_300)
        let fixed = try await sim.launch()
        XCTAssertNil(fixed.crashedBy)
        XCTAssertEqual(status(b, fixed)?.lifecycle, .running(stable: true))
        XCTAssertNil(status(b, fixed)?.health.quarantine)
    }

    func testNewAppBuildEarnsAProbeNotAPardon() async throws {
        var config = Fixture.config()
        config.validatesVendorPayloads = false
        let sim = Fixture.simulator(three, config: config)
        await sim.setFault(.nullFlagCrashOnStart, for: b)
        await sim.setPayload(Fixture.poisoned, for: b)
        for _ in 0..<3 { try await sim.launch() }
        await sim.setAppVersion("1.1")
        let probe = try await sim.launch()
        XCTAssertEqual(probe.crashedBy, b)
        let next = try await sim.launch()
        XCTAssertNil(next.crashedBy)
        XCTAssertEqual(status(b, next)?.health.quarantine?.trips, 2)
    }

    /// A contention crash: `a` dies when another vendor starts during its
    /// window, so at the moment of death `b` is inside `start()`. Naive
    /// attribution would quarantine `b`. Here `b` only ever gets a
    /// provisional strike, isolation stops the crash (it needs both running
    /// together), and the innocent vendor is never quarantined. The honest
    /// cost, documented in the README: the crash alternates between launches
    /// rather than being pinned on `a`.
    func testContentionCrashNeverQuarantinesTheVendorThatHappenedToBeStarting() async throws {
        let sim = Fixture.simulator([(a, .afterFirstFrame), (b, .afterFirstFrame)])
        await sim.setFault(.crashWhenAnotherStartsDuringProbation, for: a)
        var records: [LaunchRecord] = []
        for _ in 0..<8 { records.append(try await sim.launch()) }
        XCTAssertEqual(records[0].crashedBy, a)
        XCTAssertEqual(records[1].snapshot.findings.first, .crashProbablyAttributed(b, strikes: 1, alsoRunning: [a]))
        XCTAssertNil(records[1].crashedBy, "isolation separates the two and the launch survives")
        for record in records {
            XCTAssertNil(status(b, record)?.health.quarantine, "launch \(record.number): innocent vendor quarantined")
        }
        XCTAssertLessThanOrEqual(records.filter { $0.crashedBy != nil }.count, 4)
    }

    /// A second `launch()` issued while the first is suspended mid-launch
    /// (here: from inside it, after boot) must be refused.
    func testOverlappingLaunchesAreRefused() async throws {
        let sim = Fixture.simulator([(a, .afterFirstFrame)])
        let outcome = OutcomeBox()
        await sim.setBeforeStartupHook { [sim] in
            // One-shot, so a broken (unguarded) simulator fails this test
            // cleanly instead of recursing forever.
            guard outcome.claim() else { return }
            do {
                _ = try await sim.launch()
                outcome.set("completed")
            } catch let error as LaunchSimulatorError {
                outcome.set(error == .launchInProgress ? "refused" : "other")
            } catch {
                outcome.set("other")
            }
        }
        let first = try await sim.launch()
        XCTAssertNil(first.crashedBy)
        XCTAssertEqual(outcome.get(), "refused")
        let history = await sim.history.count
        XCTAssertEqual(history, 1, "only the first launch ran")
    }

    func testHistoryIsBounded() async throws {
        let sim = Fixture.simulator([(a, .afterFirstFrame)])
        for _ in 0..<(LaunchSimulator.maxHistory + 5) { try await sim.launch() }
        let count = await sim.history.count
        XCTAssertEqual(count, LaunchSimulator.maxHistory)
    }
}

final class OutcomeBox: @unchecked Sendable {
    // @unchecked: guarded by `lock`.
    private let lock = NSLock()
    private var value: String?
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
