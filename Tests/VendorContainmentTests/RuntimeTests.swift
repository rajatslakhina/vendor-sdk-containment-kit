import Foundation
import XCTest
@testable import VendorContainment

final class RuntimeTests: XCTestCase {
    let clock = ManualClock()

    func testConstructionRejectsDuplicatesAndBadConfiguration() {
        let x = RecordingAdapter("x", clock: clock)
        let y = RecordingAdapter("x", clock: clock)
        XCTAssertThrowsError(try Fixture.runtime([x, y], clock: clock)) {
            XCTAssertEqual($0 as? ContainmentError, .duplicateVendor("x"))
        }
        var bad = Fixture.config()
        bad.stabilityWindow = .nan
        XCTAssertThrowsError(try Fixture.runtime([x], clock: clock, config: bad))
        bad = Fixture.config(threshold: 0)
        XCTAssertThrowsError(try Fixture.runtime([x], clock: clock, config: bad))
        bad = Fixture.config()
        bad.bufferCapacityPerVendor = 0
        XCTAssertThrowsError(try Fixture.runtime([x], clock: clock, config: bad), "capacity 0 would starve running vendors")
    }

    func testCallsBeforeBootAndTwiceAreRefused() async throws {
        let runtime = try Fixture.runtime([RecordingAdapter("x", clock: clock)], clock: clock)
        await assertThrows(.notBooted) { try await runtime.runStartup() }
        await assertThrows(.notBooted) { try await runtime.track("e") }
        try await runtime.boot(policy: nil)
        await assertThrows(.alreadyBooted) { try await runtime.boot(policy: nil) }
    }

    func testEventsBeforeStartupAreBufferedThenReplayedOnceInOrder() async throws {
        let a = RecordingAdapter("a", clock: clock)
        let runtime = try Fixture.runtime([a], clock: clock)
        try await runtime.boot(policy: nil)
        for name in ["e1", "e2", "e3"] {
            let d = try await runtime.track(name)
            XCTAssertEqual(d["a"], .buffered)
        }
        XCTAssertTrue(a.received.isEmpty, "nothing reaches a vendor before it starts")
        try await runtime.runStartup()
        let live = try await runtime.track("e4")
        XCTAssertEqual(live["a"], .sent)
        XCTAssertEqual(a.received, ["e1", "e2", "e3", "e4"])
        let snap = await runtime.snapshot()
        XCTAssertEqual(snap.vendors.first?.lifecycle, .running(stable: true))
        XCTAssertEqual(snap.vendors.first?.buffered, 0)
    }

    func testPrivacyKillDropsAndPurgesButOperationalPauseKeeps() async throws {
        let store = InMemoryContainmentStore()
        let a = RecordingAdapter("a", clock: clock)
        let b = RecordingAdapter("b", clock: clock)
        let r1 = try Fixture.runtime([a, b], clock: clock, store: store)
        try await r1.boot(policy: nil)
        try await r1.track("queued-before-kill")

        let kill = PolicyDocument(version: 2, rules: [
            "a": VendorRule(enabled: false, whenDisabled: .drop),
            "b": VendorRule(enabled: false, whenDisabled: .buffer),
        ])
        let r2 = try Fixture.runtime([a, b], clock: clock, store: store)
        try await r2.boot(policy: kill)
        let d = try await r2.track("after-kill")
        XCTAssertEqual(d["a"], .dropped(.policy))
        XCTAssertEqual(d["b"], .buffered)
        let snap = await r2.snapshot()
        XCTAssertEqual(snap.vendors.first { $0.id == "a" }?.buffered, 0, "a privacy kill purges what was queued")
        XCTAssertEqual(snap.vendors.first { $0.id == "b" }?.buffered, 2)
    }

    func testOutsideRolloutDropsAndNeverStarts() async throws {
        let a = RecordingAdapter("a", clock: clock)
        let runtime = try Fixture.runtime([a], clock: clock)
        try await runtime.boot(policy: PolicyDocument(version: 1, rules: ["a": VendorRule(rolloutPercent: 0)]))
        try await runtime.runStartup()
        let d = try await runtime.track("e")
        XCTAssertEqual(d["a"], .dropped(.policy))
        XCTAssertTrue(a.starts.isEmpty)
    }

    func testRejectedPayloadMeansTheVendorNeverRuns() async throws {
        let a = RecordingAdapter("a", schema: PayloadSchema(requiredNonEmptyStrings: ["flag_name"]), clock: clock)
        let runtime = try Fixture.runtime([a], clock: clock)
        let snap = try await runtime.boot(policy: nil, payloads: ["a": ["flag_name": .null]])
        XCTAssertEqual(snap.vendors.first?.lifecycle, .skipped(.payloadRejected([.nullValue("flag_name")])))
        try await runtime.runStartup()
        XCTAssertTrue(a.starts.isEmpty)
    }

    func testANonFatalStartErrorIsNotACrashStrike() async throws {
        let store = InMemoryContainmentStore()
        let a = RecordingAdapter("a", clock: clock)
        a.onStart = { _ in throw TestError() }
        let r1 = try Fixture.runtime([a], clock: clock, store: store)
        try await r1.boot(policy: nil)
        try await r1.runStartup()
        let snap = await r1.snapshot()
        guard case .skipped(.startFailed)? = snap.vendors.first?.lifecycle else {
            return XCTFail("expected startFailed, got \(String(describing: snap.vendors.first?.lifecycle))")
        }
        let r2 = try Fixture.runtime([RecordingAdapter("a", clock: clock)], clock: clock, store: store)
        let next = try await r2.boot(policy: nil)
        XCTAssertEqual(next.findings, [], "the app stayed up; nothing to attribute")
    }

    func testFailsClosedWhenTheMarkerCannotBePersisted() async throws {
        let store = FlakyStore()
        let a = RecordingAdapter("a", clock: clock)
        let runtime = try Fixture.runtime([a], clock: clock, store: store)
        try await runtime.boot(policy: nil)
        store.failSaves = true
        try await runtime.runStartup()
        XCTAssertTrue(a.starts.isEmpty, "an unrecorded start is an undetectable crash")
        let snap = await runtime.snapshot()
        XCTAssertEqual(snap.vendors.first?.lifecycle, .skipped(.startFailed("marker could not be persisted")))
        XCTAssertNotNil(snap.lastStoreError)
    }

    func testFatalFaultLeavesTheMarkerAndKillsTheRuntime() async throws {
        let store = InMemoryContainmentStore()
        let a = RecordingAdapter("a", clock: clock)
        a.onStart = { _ in throw SimulatedCrash(vendor: "a") }
        let runtime = try Fixture.runtime([a], clock: clock, store: store)
        try await runtime.boot(policy: nil)
        do {
            try await runtime.runStartup()
            XCTFail("expected the simulated crash to propagate")
        } catch is SimulatedCrash {}
        XCTAssertEqual(store.load()?.sentinel.markers["a"], .starting)
        await assertThrows(.terminated) { try await runtime.track("e") }
    }

    func testStartupIsSingleFlightUnderReentrancy() async throws {
        let a = RecordingAdapter("a", clock: clock)
        a.onStart = { _ in await Task.yield() }
        let runtime = try Fixture.runtime([a], clock: clock)
        try await runtime.boot(policy: nil)
        async let first: Void = runtime.runStartup()
        async let second: Void = runtime.runStartup()
        var errors: [ContainmentError] = []
        do { try await first } catch let e as ContainmentError { errors.append(e) }
        do { try await second } catch let e as ContainmentError { errors.append(e) }
        XCTAssertEqual(errors, [.startupAlreadyRan])
        XCTAssertEqual(a.starts.count, 1)
    }

    /// While the replay of e1 is suspended inside the vendor, the vendor's own
    /// callback re-enters `track`. The live event must queue behind e2, not
    /// overtake it.
    func testReentrantTrackDuringReplayCannotOvertakeQueuedEvents() async throws {
        let a = RecordingAdapter("a", clock: clock)
        let box = RuntimeBox()
        a.onSend = { event in
            if event.name == "e1" { _ = try await box.runtime?.track("live") }
        }
        let runtime = try Fixture.runtime([a], clock: clock)
        box.runtime = runtime
        try await runtime.boot(policy: nil)
        try await runtime.track("e1")
        try await runtime.track("e2")
        try await runtime.runStartup()
        XCTAssertEqual(a.received, ["e1", "e2", "live"])
    }

    /// e2's send fails once while a reentrant event arrives. The failed event
    /// must stay at the head, and a later flush must deliver in order.
    func testFailedReplayKeepsOrderAcrossARetry() async throws {
        let a = RecordingAdapter("a", clock: clock)
        let box = RuntimeBox()
        let failures = Counter()
        a.onSend = { event in
            if event.name == "e2", failures.next() == 0 {
                _ = try await box.runtime?.track("live")
                throw TestError()
            }
        }
        let runtime = try Fixture.runtime([a], clock: clock)
        box.runtime = runtime
        try await runtime.boot(policy: nil)
        try await runtime.track("e1")
        try await runtime.track("e2")
        try await runtime.runStartup()
        XCTAssertEqual(a.received, ["e1", "e2"])
        try await runtime.flush()
        XCTAssertEqual(a.received, ["e1", "e2", "e2", "live"], "retry of e2 precedes the newer event")
    }

    /// Fifty concurrent writers race the startup drain. Every event must
    /// arrive exactly once.
    func testConcurrentWritersDuringStartupDeliverExactlyOnce() async throws {
        let a = RecordingAdapter("a", clock: clock)
        a.onSend = { _ in await Task.yield() }
        let runtime = try Fixture.runtime([a], clock: clock)
        try await runtime.boot(policy: nil)
        for i in 0..<20 { try await runtime.track("pre-\(i)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runtime.runStartup() }
            for i in 0..<50 {
                group.addTask { _ = try await runtime.track("c-\(i)") }
            }
            try await group.waitForAll()
        }
        try await runtime.flush()
        let got = a.received
        XCTAssertEqual(got.count, 70)
        XCTAssertEqual(Set(got).count, 70, "no duplicates")
        XCTAssertEqual(Array(got.prefix(20)), (0..<20).map { "pre-\($0)" }, "pre-start events replay first, in order")
    }

    func testSuspectVendorRunsItsWindowAlone() async throws {
        let store = InMemoryContainmentStore()
        var seeded = PersistedState(buffer: EventBuffer(capacityPerVendor: 10))
        seeded.sentinel.markers = ["a": .probation(since: clock.now()), "b": .probation(since: clock.now())]
        try store.save(seeded)

        let a = RecordingAdapter("a", clock: clock)
        let b = RecordingAdapter("b", clock: clock)
        let c = RecordingAdapter("c", clock: clock)
        let runtime = try Fixture.runtime([a, b, c], clock: clock, store: store)
        let snap = try await runtime.boot(policy: nil)
        XCTAssertEqual(snap.findings, [.ambiguousCrash(["a", "b"])])
        try await runtime.runStartup()
        let aStart = try XCTUnwrap(a.starts.first)
        let bStart = try XCTUnwrap(b.starts.first)
        let cStart = try XCTUnwrap(c.starts.first)
        XCTAssertGreaterThanOrEqual(bStart.timeIntervalSince(aStart), 10, "b waits for a's whole window")
        XCTAssertGreaterThanOrEqual(cStart.timeIntervalSince(bStart), 10, "normal vendors wait for isolation to finish")
    }

    func testIdleStageStartsAfterTheDelay() async throws {
        let early = RecordingAdapter("early", stage: .afterFirstFrame, clock: clock)
        let late = RecordingAdapter("late", stage: .idle, clock: clock)
        let runtime = try Fixture.runtime([late, early], clock: clock)
        try await runtime.boot(policy: nil)
        try await runtime.runStartup()
        let e = try XCTUnwrap(early.starts.first)
        let l = try XCTUnwrap(late.starts.first)
        XCTAssertGreaterThanOrEqual(l.timeIntervalSince(e), 2)
    }

    // MARK: helpers

    func assertThrows(_ expected: ContainmentError, file: StaticString = #filePath, line: UInt = #line,
                      _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ContainmentError, expected, file: file, line: line)
        }
    }
}

final class RuntimeBox: @unchecked Sendable {
    // @unchecked: written once before any concurrent read.
    var runtime: ContainmentRuntime?
}

final class Counter: @unchecked Sendable {
    // @unchecked: guarded by `lock`.
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}

final class RuntimeDurabilityTests: XCTestCase {
    let clock = ManualClock()

    /// The ordering claim itself: when vendor code first runs, the marker is
    /// already in the store.
    func testMarkerIsDurableBeforeVendorCodeRuns() async throws {
        let store = InMemoryContainmentStore()
        let a = RecordingAdapter("a", clock: clock)
        let seen = Counter()
        a.onStart = { _ in
            if store.load()?.sentinel.markers["a"] == .starting { _ = seen.next() }
        }
        let runtime = try Fixture.runtime([a], clock: clock, store: store)
        try await runtime.boot(policy: nil)
        try await runtime.runStartup()
        XCTAssertEqual(seen.next(), 1, "start() ran exactly once, and saw its own marker on disk")
    }

    func testCrashMidReplayKeepsTheHeadOnDisk() async throws {
        let store = InMemoryContainmentStore()
        let a = RecordingAdapter("a", clock: clock)
        a.onSend = { event in if event.name == "e1" { throw SimulatedCrash(vendor: "a") } }
        let runtime = try Fixture.runtime([a], clock: clock, store: store)
        try await runtime.boot(policy: nil)
        try await runtime.track("e1")
        try await runtime.track("e2")
        do { try await runtime.runStartup(); XCTFail("expected crash") } catch is SimulatedCrash {}
        XCTAssertEqual(store.load()?.buffer.pending(for: "a").map(\.event.name), ["e1", "e2"])
    }

    func testCrashInALiveSendDoesNotLoseAnEarlierTargetsEvent() async throws {
        let store = InMemoryContainmentStore()
        let paused = RecordingAdapter("a", clock: clock)
        let live = RecordingAdapter("b", clock: clock)
        live.onSend = { _ in throw SimulatedCrash(vendor: "b") }
        let runtime = try Fixture.runtime([paused, live], clock: clock, store: store)
        try await runtime.boot(policy: PolicyDocument(version: 1, rules: ["a": VendorRule(enabled: false), "b": VendorRule()]))
        try await runtime.runStartup()
        do { try await runtime.track("e", to: ["a", "b"]); XCTFail("expected crash") } catch is SimulatedCrash {}
        XCTAssertEqual(store.load()?.buffer.pending(for: "a").map(\.event.name), ["e"])
    }

    /// A live send fails while a newer event arrives: the newer one must not
    /// overtake the retry.
    func testFailedLiveSendIsRetriedBeforeNewerEvents() async throws {
        let a = RecordingAdapter("a", clock: clock)
        let box = RuntimeBox()
        let attempts = Counter()
        a.onSend = { event in
            if event.name == "e1", attempts.next() == 0 {
                let d = try await box.runtime?.track("e2")
                XCTAssertEqual(d?["a"], .buffered, "e2 must queue while e1 is in flight")
                throw TestError()
            }
        }
        let runtime = try Fixture.runtime([a], clock: clock)
        box.runtime = runtime
        try await runtime.boot(policy: nil)
        try await runtime.runStartup()
        let d1 = try await runtime.track("e1")
        XCTAssertEqual(d1["a"], .buffered)
        try await runtime.flush()
        XCTAssertEqual(a.received, ["e1", "e1", "e2"])
    }

    /// After a transient failure there is no timer: the queue resumes on the
    /// next `track` once the backoff has passed (or on `flush()`).
    func testQueueResumesOnTheNextTrackAfterBackoff() async throws {
        let a = RecordingAdapter("a", clock: clock)
        let attempts = Counter()
        a.onSend = { _ in if attempts.next() == 0 { throw TestError() } }
        let runtime = try Fixture.runtime([a], clock: clock)
        try await runtime.boot(policy: nil)
        try await runtime.runStartup()
        try await runtime.track("e1")
        let during = try await runtime.track("e2")
        XCTAssertEqual(during["a"], .buffered)
        XCTAssertEqual(a.received, ["e1"], "inside the backoff nothing is retried")
        clock.advance(by: 1)
        let after = try await runtime.track("e3")
        XCTAssertEqual(after["a"], .sent, "e3 went out behind the retried e1 and e2")
        XCTAssertEqual(a.received, ["e1", "e1", "e2", "e3"])
    }

    func testPersonalEventIsDroppedNotQueuedWhileTheVendorIsDown() async throws {
        let runtime = try Fixture.runtime([RecordingAdapter("a", clock: clock)], clock: clock)
        try await runtime.boot(policy: nil)
        let d = try await runtime.track("email_entered", privacy: .personal)
        XCTAssertEqual(d["a"], .dropped(.personalNotBufferable))
    }

    /// A bufferable event to a running vendor is on disk before vendor code
    /// runs: crash inside its very first (live) send and it is still queued.
    func testCrashDuringAFirstLiveSendKeepsTheEventOnDisk() async throws {
        let store = InMemoryContainmentStore()
        let a = RecordingAdapter("a", clock: clock)
        a.onSend = { _ in throw SimulatedCrash(vendor: "a") }
        let runtime = try Fixture.runtime([a], clock: clock, store: store)
        try await runtime.boot(policy: nil)
        try await runtime.runStartup()
        do { try await runtime.track("live"); XCTFail("expected crash") } catch is SimulatedCrash {}
        XCTAssertEqual(store.load()?.buffer.pending(for: "a").map(\.event.name), ["live"])
    }

    /// `.personal` events go out live to a running vendor with an empty
    /// queue, and are never written to the store.
    func testPersonalEventIsSentLiveButNeverPersisted() async throws {
        let store = InMemoryContainmentStore()
        let a = RecordingAdapter("a", clock: clock)
        let seenOnDisk = Counter()
        a.onSend = { event in
            // Checked *during* the send: append-save-send-remove would fail here.
            if store.load()?.buffer.pending(for: "a").contains(where: { $0.event.name == event.name }) == true {
                _ = seenOnDisk.next()
            }
        }
        let runtime = try Fixture.runtime([a], clock: clock, store: store)
        try await runtime.boot(policy: nil)
        try await runtime.runStartup()
        let d = try await runtime.track("email_entered", privacy: .personal)
        XCTAssertEqual(d["a"], .sent)
        XCTAssertEqual(a.received, ["email_entered"])
        XCTAssertEqual(store.load()?.buffer.totalCount, 0)
        XCTAssertEqual(seenOnDisk.next(), 0, "the personal event was never in the persisted queue")
    }

    /// An event queued by a reentrant `track` during a personal live send is
    /// delivered when that send finishes, not stranded until the next event.
    func testEventQueuedDuringAPersonalSendIsNotStranded() async throws {
        let a = RecordingAdapter("a", clock: clock)
        let box = RuntimeBox()
        a.onSend = { event in
            if event.name == "pii" { _ = try await box.runtime?.track("follow_up") }
        }
        let runtime = try Fixture.runtime([a], clock: clock)
        box.runtime = runtime
        try await runtime.boot(policy: nil)
        try await runtime.runStartup()
        try await runtime.track("pii", privacy: .personal)
        XCTAssertEqual(a.received, ["pii", "follow_up"])
        let snap = await runtime.snapshot()
        XCTAssertEqual(snap.vendors.first?.buffered, 0)
    }

    func testAStoreFailureIsReportedAsVolatile() async throws {
        let store = FlakyStore()
        let runtime = try Fixture.runtime([RecordingAdapter("a", clock: clock)], clock: clock, store: store)
        try await runtime.boot(policy: nil)
        store.failSaves = true
        let d = try await runtime.track("e")
        XCTAssertEqual(d["a"], .bufferedVolatile)
    }

    /// A cancelled startup leaves its markers; `settle()` clears them later,
    /// and a wall-clock jump backwards doesn't stretch the window.
    func testCancelledStartupCanBeSettledLaterOnTheMonotonicClock() async throws {
        struct Cancelling: ContainmentSleeper {
            func sleep(for seconds: TimeInterval) async throws { throw CancellationError() }
        }
        let store = InMemoryContainmentStore()
        let runtime = try ContainmentRuntime(
            adapters: [RecordingAdapter("a", clock: clock)],
            compiledPolicy: Fixture.policy(["a"]), configuration: Fixture.config(),
            store: store, installID: "i", appVersion: "1", clock: clock, sleeper: Cancelling()
        )
        try await runtime.boot(policy: nil)
        do { try await runtime.runStartup(); XCTFail("expected cancellation") } catch is CancellationError {}
        guard case .probation? = store.load()?.sentinel.markers["a"] else { return XCTFail("marker should remain") }
        clock.set(clock.now().addingTimeInterval(-86_400)) // user moves the clock back a day
        clock.advance(by: 10)
        let cleared = try await runtime.settle()
        XCTAssertEqual(cleared, ["a"])
        XCTAssertEqual(store.load()?.sentinel.markers, [:])
    }

    func testAStalledSleeperIsSurfacedNotSwallowed() async throws {
        struct Stalled: ContainmentSleeper {
            func sleep(for seconds: TimeInterval) async throws {}
        }
        let runtime = try ContainmentRuntime(
            adapters: [RecordingAdapter("a", clock: clock)],
            compiledPolicy: Fixture.policy(["a"]), configuration: Fixture.config(),
            store: InMemoryContainmentStore(), installID: "i", appVersion: "1", clock: clock, sleeper: Stalled()
        )
        try await runtime.boot(policy: nil)
        do {
            try await runtime.runStartup()
            XCTFail("expected stabilityWaitExhausted")
        } catch {
            XCTAssertEqual(error as? ContainmentError, .stabilityWaitExhausted)
        }
    }
}
