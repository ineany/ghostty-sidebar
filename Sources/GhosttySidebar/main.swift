import AppKit
import GhosttyBridge

// Entry point. `ghostty-sidebar --mock` runs against MockGhosttyBridge so the UI
// can be exercised without Ghostty; otherwise the real bridge is used.

let useMock = CommandLine.arguments.dropFirst().contains("--mock")

MainActor.assumeIsolated {
    let bridge: any GhosttyControlling = useMock ? MockGhosttyBridge() : makeDefaultBridge()
    let app = NSApplication.shared
    let delegate = AppDelegate(bridge: bridge, isMock: useMock)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `app.delegate` is weak; keep `delegate` alive for as long as run() blocks.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
