// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ghostty-sidebar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ghostty-sidebar", targets: ["GhosttySidebar"]),
        .executable(name: "ghostty-probe", targets: ["GhosttyProbe"]),
    ],
    targets: [
        // Talks to Ghostty.app via AppleScript. No UI code here.
        .target(name: "GhosttyBridge"),
        // Floating vertical-tab sidebar (SwiftUI + AppKit).
        .executableTarget(name: "GhosttySidebar", dependencies: ["GhosttyBridge"]),
        // Command-line probe used to verify the bridge against the real Ghostty.
        .executableTarget(name: "GhosttyProbe", dependencies: ["GhosttyBridge"]),
        .testTarget(name: "GhosttyBridgeTests", dependencies: ["GhosttyBridge"]),
    ]
)
