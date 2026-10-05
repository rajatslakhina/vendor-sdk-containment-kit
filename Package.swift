// swift-tools-version: 6.0
import PackageDescription

// Platforms are exactly the ones CI builds: macOS (`swift test`) and the iOS
// Simulator (`xcodebuild build`). Linux is covered by its own CI job; the core
// module is Foundation-only and the SwiftUI views are behind `canImport(SwiftUI)`.
let package = Package(
    name: "VendorContainment",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "VendorContainment", targets: ["VendorContainment"]),
        .library(name: "VendorContainmentUI", targets: ["VendorContainmentUI"]),
    ],
    targets: [
        .target(name: "VendorContainment"),
        .target(name: "VendorContainmentUI", dependencies: ["VendorContainment"]),
        .testTarget(name: "VendorContainmentTests", dependencies: ["VendorContainment"]),
        .testTarget(
            name: "VendorContainmentUITests",
            dependencies: ["VendorContainmentUI", "VendorContainment"]
        ),
    ]
)
