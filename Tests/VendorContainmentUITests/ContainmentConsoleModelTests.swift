import Foundation
import XCTest
import VendorContainment
@testable import VendorContainmentUI

@MainActor
final class ContainmentConsoleModelTests: XCTestCase {
    let vendors: [(id: VendorID, stage: StartupStage)] = [
        ("analytics", .afterFirstFrame), ("attribution", .afterFirstFrame), ("messaging", .idle),
    ]

    func makeModel() -> ContainmentConsoleModel {
        let policy = PolicyDocument(version: 0, rules: [
            "analytics": VendorRule(), "attribution": VendorRule(), "messaging": VendorRule(),
        ])
        return ContainmentConsoleModel(
            vendors: vendors,
            compiledPolicy: policy,
            initialFaults: ["attribution": .nullFlagCrashOnStart]
        )
    }

    /// The headline interaction for the default state: "Replay ×4" must
    /// visibly show two crashes followed by containment.
    func testDefaultReplayShowsCrashesThenContainment() async {
        let model = makeModel()
        await model.replayIncident()
        XCTAssertEqual(model.launches.count, 4)
        // Newest first.
        XCTAssertEqual(model.launches.map(\.crashedBy), [nil, nil, "attribution", "attribution"])
        XCTAssertEqual(model.launches.first?.headline, "Up: attribution contained")
        let row = model.vendorRows.first { $0.id == "attribution" }
        XCTAssertEqual(row?.quarantined, true)
        XCTAssertEqual(row?.isHealthy, false)
    }

    func testValidationToggleAvoidsTheCrashEntirely() async {
        let model = makeModel()
        model.validatesPayloads = true
        await model.launch()
        XCTAssertNil(model.launches.first?.crashedBy)
        XCTAssertTrue(model.vendorRows.first { $0.id == "attribution" }?.state.hasPrefix("payload rejected") ?? false)
    }

    func testReleaseBringsTheVendorBackAndTrackReportsDeliveries() async {
        let model = makeModel()
        await model.replayIncident(launches: 3)
        model.releaseQuarantine("attribution")
        XCTAssertEqual(model.faults["attribution"], SimulatedFault.none)
        await model.launch()
        XCTAssertNil(model.launches.first?.crashedBy)
        XCTAssertEqual(model.vendorRows.first { $0.id == "attribution" }?.state, "running · stable")
        await model.trackEvent("tap")
        XCTAssertEqual(model.lastMessage, "tap → analytics: sent, attribution: sent, messaging: sent")
    }

    func testKillSwitchBumpsPolicyVersionAndDisablesVendor() async {
        let model = makeModel()
        model.setFault(SimulatedFault.none, for: "attribution")
        model.toggleKillSwitch("messaging")
        XCTAssertEqual(model.policyVersion, 2)
        await model.launch()
        XCTAssertEqual(model.policySummary, "fresh policy v2")
        XCTAssertTrue(model.vendorRows.first { $0.id == "messaging" }?.state.hasPrefix("disabled by app policy") ?? false)
    }

    /// Shipping a new build gives a quarantined vendor one isolated probe;
    /// while the vendor is still broken, that probe crashes and it goes back
    /// in with a doubled cooldown.
    func testNewBuildProbesTheQuarantinedVendor() async {
        let model = makeModel()
        await model.replayIncident(launches: 3)
        model.upgradeApp()
        XCTAssertEqual(model.appVersion, "1.1")
        await model.launch()
        XCTAssertEqual(model.launches.first?.crashedBy, "attribution")
        await model.launch()
        XCTAssertNil(model.launches.first?.crashedBy)
        XCTAssertTrue(model.launches.first?.details.contains { $0.contains("failed its probe") } ?? false)
    }

    func testTrackWithNoLiveLaunchSaysSo() async {
        let model = makeModel()
        await model.launch() // crashes
        await model.trackEvent()
        XCTAssertEqual(model.lastMessage, "No live launch: the last one crashed. Launch again.")
    }
}
