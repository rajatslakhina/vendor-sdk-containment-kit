import Foundation
import XCTest
@testable import VendorContainment

final class RolloutTests: XCTestCase {
    /// Published FNV-1a 64 test vectors. Comparing against fixed constants
    /// (not a second call) is what catches a switch to the per-process
    /// seeded `Hasher`, which would re-bucket every user on every launch.
    func testFNV1aMatchesPublishedVectors() {
        XCTAssertEqual(StableHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testBucketsAreInRangeAndRoughlyUniform() {
        var deciles = [Int](repeating: 0, count: 10)
        for i in 0..<10_000 {
            let bucket = RolloutBucketer(installID: "install-\(i)").bucket(for: "analytics")
            XCTAssertTrue((0..<100).contains(bucket))
            deciles[bucket / 10] += 1
        }
        for (index, count) in deciles.enumerated() {
            XCTAssertTrue((850...1_150).contains(count), "decile \(index) had \(count)")
        }
    }

    func testRaisingRolloutNeverRemovesAnInstall() {
        for i in 0..<500 {
            let bucketer = RolloutBucketer(installID: "u\(i)")
            for percent in 0..<100 where bucketer.isIncluded("attribution", percent: percent) {
                XCTAssertTrue(bucketer.isIncluded("attribution", percent: percent + 1))
            }
        }
    }

    func testOutOfRangePercentagesClamp() {
        let bucketer = RolloutBucketer(installID: "x")
        XCTAssertFalse(bucketer.isIncluded("a", percent: 0))
        XCTAssertFalse(bucketer.isIncluded("a", percent: -5))
        XCTAssertTrue(bucketer.isIncluded("a", percent: 100))
        XCTAssertTrue(bucketer.isIncluded("a", percent: 250))
    }

    /// If the vendor id weren't mixed in, every vendor would roll out to the
    /// same users and this would be 100%.
    func testDifferentVendorsBucketIndependently() {
        var same = 0
        for i in 0..<5_000 {
            let bucketer = RolloutBucketer(installID: "i\(i)")
            if bucketer.bucket(for: "analytics") == bucketer.bucket(for: "attribution") { same += 1 }
        }
        XCTAssertLessThan(same, 150, "≈1% expected by chance, got \(same) of 5000")
    }
}

final class SaturatingTests: XCTestCase {
    func testAddClampsAtBothEnds() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(2, 3), 5)
        XCTAssertEqual(Saturating.increment(UInt64.max), UInt64.max)
    }

    func testDoubledHandlesNonFiniteAndCaps() {
        XCTAssertEqual(Saturating.doubled(10, cap: 100), 20)
        XCTAssertEqual(Saturating.doubled(60, cap: 100), 100)
        XCTAssertEqual(Saturating.doubled(.infinity, cap: 100), 100)
        XCTAssertEqual(Saturating.doubled(.nan, cap: 100), 100)
        XCTAssertEqual(Saturating.doubled(-5, cap: 100), 0)
        XCTAssertEqual(Saturating.doubled(5, cap: .nan), 0)
    }

    func testNanosecondsNeverTraps() {
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: .nan), 0)
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: -1), 0)
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: .infinity), 0)
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: 1e30), UInt64.max)
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: 1.5), 1_500_000_000)
    }
}

final class PayloadTests: XCTestCase {
    let schema = PayloadSchema(requiredNonEmptyStrings: ["flag_name"])

    /// The shape of the 28 Sep 2026 incident: a null flag name.
    func testNullFlagNameIsRejected() {
        XCTAssertEqual(PayloadValidator.validate(["flag_name": .null], against: schema), [.nullValue("flag_name")])
    }

    func testMissingEmptyAndWrongTypeAreRejected() {
        XCTAssertEqual(PayloadValidator.validate([:], against: schema), [.missingKey("flag_name")])
        XCTAssertEqual(PayloadValidator.validate(["flag_name": .string("")], against: schema), [.emptyString("flag_name")])
        XCTAssertEqual(PayloadValidator.validate(["flag_name": .number(1)], against: schema), [.wrongType("flag_name")])
    }

    func testValidPayloadPasses() {
        let payload: VendorPayload = ["flag_name": .string("x"), "nested": .object(["a": .array([.bool(true)])])]
        XCTAssertEqual(PayloadValidator.validate(payload, against: schema), [])
    }

    func testDeepNestingIsBoundedAndStopsEarly() {
        var value = PayloadValue.null
        for _ in 0..<5_000 { value = .array([value]) }
        let violations = PayloadValidator.validate(["flag_name": .string("x"), "deep": value], against: schema)
        XCTAssertEqual(violations, [.tooDeep(limit: 8)])
    }

    func testNodeAndStringLimits() {
        let wide = PayloadValue.array(Array(repeating: .bool(true), count: 3_000))
        XCTAssertEqual(PayloadValidator.validate(["w": wide], against: .permissive), [.tooManyNodes(limit: 2_000)])
        let long = PayloadValue.string(String(repeating: "x", count: 5_000))
        XCTAssertEqual(PayloadValidator.validate(["s": long], against: .permissive), [.stringTooLong(limit: 4_096)])
    }

    func testNonPositiveSchemaLimitsAreRejected() {
        let bad = PayloadSchema(maxDepth: 0)
        XCTAssertEqual(PayloadValidator.validate([:], against: bad), [.invalidSchema])
    }
}
