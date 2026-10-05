# VendorContainment

**Your app's uptime currently depends on someone else's config server. This package puts a blast radius around every third-party SDK. When a vendor's config crashes your app at launch, the vendor is contained after two crashes by default, and then the app stays up and keeps the data.**

[![CI](https://github.com/rajatslakhina/vendor-sdk-containment-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/vendor-sdk-containment-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue) ![License MIT](https://img.shields.io/badge/license-MIT-lightgrey)

Demo app: (added after the companion repo is pushed — see below)

---

## Why this matters

On 28 September 2026, a two-line flag cleanup on the vendor's side made the Google Analytics for Firebase iOS SDK crash apps at launch for 2 h 11 m ([Firebase postmortem](https://firebase.blog/posts/2026/10/firebase-analytics-outage), [firebase-ios-sdk #16728](https://github.com/firebase/firebase-ios-sdk/issues/16728)). Three details from that postmortem are the design brief for this package:

1. **The SDK didn't validate a `nil` flag name.** The poison came in through config, not code. No release on your side and no review on your side.
2. **The vendor's kill switch rolled out globally, all at once.** You can't rely on the vendor's control plane to undo the vendor's control plane.
3. **Status dashboards stayed green.** They watched server health, and the failure was on the client. The only system positioned to notice was the app itself.

For an engineering lead, the question isn't how to fix one SDK. It's this: **which of our 15 vendor SDKs can take the whole app down, and what stops that from happening without a release?** That's a systems problem (detection across process deaths, attribution under ambiguity, a control plane you own, data durability) with an architecture problem inside it: app code must never touch a vendor SDK directly.

## What it does

```
            app code ──► ContainmentRuntime (actor, imperative shell)
                              │
   ┌──────────────┬───────────┼──────────────┬───────────────┐
   ▼              ▼           ▼              ▼               ▼
PolicyResolver LaunchSentinel PayloadValidator RolloutBucketer EventBuffer   ← pure value-type cores
(own kill switch (crash detection (validation    (FNV-1a sticky  (per-vendor,
 + last-known-   + attribution    boundary)       % rollout)      privacy-aware)
 good + meet)    + quarantine)
                              │
                     VendorAdapter (port)  ◄── one thin adapter per SDK
```

| Layer | Defends against | How |
|---|---|---|
| **Staged startup** | Crashes before any recovery code can run | `StartupStage` has no pre-first-frame case. Starting a vendor in `didFinishLaunching` can't be expressed. |
| **Validation boundary** | Poisoned vendor config (the Firebase root cause) | `PayloadSchema` declares the keys the SDK will dereference. `PayloadValidator` rejects null/empty/missing values, plus over-deep or oversized payloads, iteratively. |
| **Launch sentinel** | A vendor that crashes the app anyway | A durable marker is written *synchronously* before each vendor runs and cleared after a stability window. A marker still on disk at the next launch is a crash. |
| **Attribution + isolation** | Blaming the wrong vendor | Vendors start one at a time. A crash with exactly one marker on disk is unambiguous. A crash inside one vendor's `start()` while others were on probation is only *probable*: it gets a strike capped below the threshold, and every vendor involved starts *isolated* next launch (each runs its window alone). If several vendors were on probation and none was starting, nobody gets a strike, and all of them are isolated. Quarantine always requires at least one *unambiguous* strike: a crash with exactly one unproven vendor on disk. |
| **Quarantine circuit breaker** | Crash loops | After `strikeThreshold` consecutive attributed crashes, the vendor is quarantined. After a cooldown it gets one isolated **probe**. A failed probe doubles the cooldown (capped, saturating); a successful one closes the circuit. A new app build earns a probe, not a pardon. |
| **Your own kill switch** | Depending on the vendor's control plane | `PolicyDocument` comes from *your* server: enable/disable, % rollout, buffer-or-drop, and a `quarantineEpoch` that ops bumps to release a quarantine. |
| **Event buffer** | Losing analytics while a vendor is out | Events for a not-yet-started, quarantined or paused vendor are queued per vendor and replayed in order, at-least-once, when it comes back. After a failed send, the queue backs off exponentially (1 s → 60 s) and resumes on its own. |

## Design decisions and trade-offs

**1. The marker write is synchronous, and that's load-bearing.** `ContainmentStore.save` is deliberately not `async`. If it were, the save could still be in flight when the vendor kills the process, and the crash would leave no trace. Every `await` into vendor code (`start` or `send`) is preceded by a save. Two tests pin this down. `testMarkerIsDurableBeforeVendorCodeRuns` reads the store from *inside* the vendor's `start()` and requires its marker to already be there. `testWithAStoreThatForgetsTheAppCrashLoopsForever` feeds in a store that forgets and asserts that the app *does* crash on all six launches, which shows containment rests on persistence and nothing in-process. If the marker can't be persisted at all, the vendor isn't started (fail closed: an unrecorded start is an undetectable crash). If a buffered event can't be persisted, `track` reports `.bufferedVolatile` instead of pretending.
*Rejected:* relying on MetricKit crash diagnostics alone. They arrive late (often the next day), so they can't stop a loop that repeats on every cold start. They make a good second signal, not the primary one.

**2. Ambiguity is resolved by isolation, not by guessing.** There are two naive designs. Blaming every vendor that was running quarantines innocent SDKs, which is a self-inflicted outage. "Blame whoever was inside `start()`" is wrong whenever another vendor's background thread is the one that died. Here, only unambiguous evidence (a crash with exactly one unproven vendor) can push a vendor over the threshold, and isolation is how that evidence gets collected. A crash with no clear culprit costs one extra launch to isolate. `testAmbiguousCrashConvergesOnTheTrueCulpritOnly` checks every attribution against the harness's ground truth over six launches. `testContentionCrashNeverQuarantinesTheVendorThatHappenedToBeStarting` injects a crash in vendor A that fires *while vendor B is inside `start()`*, and requires B never to be quarantined.
*Costs:* isolated vendors start up to `stabilityWindow` apart, which only affects vendors under suspicion. And a crash that needs *two* vendors running together (contention) is suppressed by isolation instead of being pinned on one of them, so it shows up as crashes on alternating launches. That's a signal to investigate, not something the client can resolve on its own.

**3. A stale policy may only restrict.** The last-known-good document survives a dead control plane (so yesterday's kill still holds today). But once it's older than `policyMaxStaleness`, or dated in the future because the clock moved, each rule is *met* with the compiled-in default: `enabled && enabled`, `min(rollout)`, and drop wins over buffer. Vendors named in neither document are off. `testStalenessPropertyCheckerCatchesABrokenCombiner` runs the property checker against both `meet` and a deliberately broken "remote wins" combiner, and requires the broken one to fail.
*Rejected:* "stale means compiled default". That would silently re-enable a vendor you killed remotely as soon as the user goes offline for a week.

**4. The policy document is versioned and immutable.** Rollbacks (`version < cached`) are rejected, and so is **reusing a version with a different body**, because that's a config change that skipped review. That was the class of change behind the original incident.

**5. Buffer-or-drop is a per-rule decision.** An operational pause buffers. A privacy or legal kill (`whenDisabled: .drop`) drops new events *and purges what was queued*. Events marked `.personal` are never written to disk at all: if they can't be sent live, they're dropped and counted. Capacity is **per vendor**, and overflow evicts that vendor's own oldest event, so one noisy quarantined SDK can't push out another vendor's data.

**6. Replay order survives actor reentrancy.** While any send to a vendor is suspended (live or replay), the vendor is marked in flight. A new `track` call appends behind the queue, so it can't overtake. A failed live send goes back to the *head* of the queue. A replayed event stays on disk until its send succeeds, so a crash mid-send replays it next launch instead of losing it. The ordering tests use a vendor callback that re-enters the runtime mid-send: `testReentrantTrackDuringReplayCannotOvertakeQueuedEvents`, `testFailedReplayKeepsOrderAcrossARetry` and `testFailedLiveSendIsRetriedBeforeNewerEvents`. `testCrashMidReplayKeepsTheHeadOnDisk` covers the crash case.

**7. Functional core, imperative shell.** All the decision logic (`LaunchSentinel.recover`, `PolicyResolver.resolve`, `PayloadValidator`, `RolloutBucketer`, `EventBuffer`) is pure value types with no I/O, so it's exhaustively testable without mocks. The single actor `ContainmentRuntime` owns ordering and persistence and nothing else.

**8. Rollout buckets use FNV-1a, never `Hasher`.** `Hasher` is randomly seeded per process, so a bucketer built on it would re-roll every user on every launch, and no single-process test would notice. The tests pin published FNV-1a vectors.

**What this does *not* do (honestly):**
- It can't validate a config that an SDK fetches internally. That's what the sentinel is for.
- A marker on disk means "the process died while this vendor was unproven". That also happens when the user force-quits inside the stability window, when the system kills the app (jetsam) after it's backgrounded inside the window, and when **the app's own code** crashes while a vendor is on probation. All of these can look like a vendor crash. The default threshold of 2, plus the rule that an ambiguous crash can never be the strike that quarantines, tolerates one false positive at the cost of a second crash.
- Each post-cooldown or post-upgrade probe of a still-broken vendor costs one more crash, by design (that's how you learn it's still broken). Cooldowns double up to `maxCooldown`.
- `FileContainmentStore` uses an atomic temp-file-and-rename write. That survives a process crash, but there's no `fsync`, so it doesn't promise durability across power loss.
- Health entries for vendors you've since removed aren't garbage-collected (they're tiny).

## Usage

```swift
import VendorContainment

struct AnalyticsAdapter: VendorAdapter {
    let id: VendorID = "analytics"
    let stage: StartupStage = .afterFirstFrame
    let payloadSchema = PayloadSchema(requiredNonEmptyStrings: ["flag_name"])
    func start(payload: VendorPayload) async throws { /* VendorSDK.configure(...) */ }
    func send(_ event: ContainedEvent) async throws { /* VendorSDK.log(event.name) */ }
}

let runtime = try ContainmentRuntime(
    adapters: [AnalyticsAdapter()],
    compiledPolicy: PolicyDocument(version: 0, rules: ["analytics": VendorRule()]),
    store: FileContainmentStore(url: containmentURL),
    installID: installID,
    appVersion: currentAppVersion
)
// Before the first frame: no network, no vendor code. `policyInbox` holds the
// document fetched in the background during the *previous* session (or nil;
// the cached last-known-good is used either way).
try await runtime.boot(policy: policyInbox.take(), payloads: vendorPayloads)
// ... first frame on screen ...
Task { try await runtime.runStartup() }
Task { policyInbox.store(try await fetchOwnPolicy()) }  // applied next launch
try await runtime.track("app_open")    // buffered until the vendor is up, then replayed
```

```swift
// Package.swift
.package(url: "https://github.com/rajatslakhina/vendor-sdk-containment-kit.git", from: "1.0.0")
```

`LaunchSimulator` (in the core module) is the fault-injection harness: repeated cold launches against one persistent store, with vendors that can crash on a null flag or during their stability window. The test suite and the demo app both run on it.

## Layout

```
Sources/VendorContainment/      Primitives, Saturating, Rollout, Payload, Policy,
                                Sentinel, EventBuffer, Store, Runtime, Harness
Sources/VendorContainmentUI/    ContainmentConsoleModel (@Observable, Linux-tested) + SwiftUI view
Tests/                          83 XCTest cases across both modules
```

## Verification

- **Local (Linux, Swift 6.1.2):** clean build (`rm -rf .build`) with `swift build --build-tests -Xswiftc -warnings-as-errors` gives 0 warnings. The XCTest bundle passes **83 / 83**.
- **CI:** see the [Actions tab](https://github.com/rajatslakhina/vendor-sdk-containment-kit/actions). The Linux job runs `swift build -Xswiftc -warnings-as-errors` + `swift test -Xlinker --allow-shlib-undefined` in `swift:6.1-noble` (the linker flag works around a missing Observation symbol in the Linux toolchain). The macOS job runs `swift test -Xswiftc -warnings-as-errors` and compiles the SwiftUI view for `generic/platform=iOS Simulator`.
- **Simulator:** see the companion demo repo for exactly what was and wasn't run.

## License

MIT
