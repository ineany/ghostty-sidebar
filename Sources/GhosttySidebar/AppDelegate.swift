import AppKit
import GhosttyBridge
import SwiftUI

/// Owns the sidebar panel and the store, and wires up termination signals.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: SidebarStore
    private let dock: DockController
    private let sessions: SessionTracker
    private let isMock: Bool
    private var panel: SidebarPanel?
    private var statusMenu: StatusMenu?
    private var autoHider: AutoHider?
    private var signalSources: [DispatchSourceSignal] = []

    init(bridge: any GhosttyControlling, isMock: Bool) {
        let store = SidebarStore(bridge: bridge, projects: isMock ? MockGhosttyBridge.projects : ProjectResolver())
        self.store = store
        self.dock = DockController(store: store, isMock: isMock)
        self.sessions = SessionTracker(store: store, isMock: isMock)
        self.isMock = isMock
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()

        let panel = SidebarPanel(contentRect: dock.dockedFrame())
        // Always dark: the panel sits beside a Catppuccin Mocha terminal.
        panel.appearance = NSAppearance(named: .darkAqua)
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        // The panel never becomes key/main, so force the active look.
        effect.state = .active
        effect.autoresizingMask = [.width, .height]

        let hosting = FirstMouseHostingView(rootView: SidebarView(isMock: isMock)
            .environmentObject(store)
            .environmentObject(dock)
            .environmentObject(sessions))
        // The panel frame is fixed by DockController; never let content changes
        // push size constraints up to the window (that forces window layout).
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        panel.contentView = effect
        panel.orderFrontRegardless()
        self.panel = panel

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let autoHider = AutoHider(panel: panel, dock: dock)
        self.autoHider = autoHider
        dock.onFrameChange = { [weak autoHider] frame in autoHider?.apply(frame) }
        dock.onAutoHideChange = { [weak autoHider] enabled in autoHider?.setEnabled(enabled) }
        statusMenu = StatusMenu(dock: dock, sessions: sessions, panel: panel) { [weak store] in store?.refresh(force: true) }
        store.start()
        sessions.start()
        if dock.autoArrange { dock.arrangeNow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        sessions.stop()
    }

    @objc private func screensChanged() {
        dock.redock()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// Floating, non-activating panel that never takes keyboard focus from Ghostty.
final class SidebarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive panel reach SwiftUI controls.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
