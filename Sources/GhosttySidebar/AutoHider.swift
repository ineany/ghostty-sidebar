import AppKit

/// Auto-hide for the sidebar panel, like the macOS Dock.
///
/// While enabled it checks the mouse ten times a second (a cheap call, and no
/// Accessibility or input-monitoring permission is needed):
/// - shown: hides after the mouse has been away from the panel for `hideDelay`.
/// - hidden: shows when the mouse touches the screen's left edge beside the
///   panel, or, for a panel placed away from the edge, enters the panel's area.
/// A panel at the left edge slides out; a panel elsewhere fades out.
/// All panel frame changes go through `apply(_:)` so a hidden panel stays hidden.
@MainActor
final class AutoHider {
    private weak var panel: NSPanel?
    private let dock: DockController
    private var timer: Timer?
    private(set) var isHidden = false
    private var lastNearby = Date()
    private var menuOpen = false
    private var observers: [NSObjectProtocol] = []

    static let hideDelay: TimeInterval = 0.6
    static let edgeHotZone: CGFloat = 2

    init(panel: NSPanel, dock: DockController) {
        self.panel = panel
        self.dock = dock
        // A menu (settings button, right click) may reach outside the panel.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuOpen = false
                self?.lastNearby = Date()
            }
        })
        setEnabled(dock.autoHide)
    }

    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        if enabled {
            lastNearby = Date()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.03
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if isHidden {
            show()
        }
    }

    /// The docked frame changed (resize, move, monitor change).
    func apply(_ frame: NSRect) {
        guard let panel else { return }
        if isHidden {
            panel.setFrame(hiddenFrame(for: frame), display: false)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func tick() {
        guard let panel, panel.isVisible || isHidden else { return }
        let mouse = NSEvent.mouseLocation
        let frame = dock.dockedFrame()
        if isHidden {
            if trigger(for: frame).contains(mouse) { show() }
            return
        }
        if dock.isInteracting || menuOpen || frame.insetBy(dx: -6, dy: -6).contains(mouse) {
            lastNearby = Date()
        } else if Date().timeIntervalSince(lastNearby) > Self.hideDelay {
            hide()
        }
    }

    private var screenVisible: NSRect? { dock.currentScreen?.visibleFrame }

    private func isAtLeftEdge(_ frame: NSRect) -> Bool {
        guard let visible = screenVisible else { return false }
        return abs(frame.minX - visible.minX) < 1
    }

    /// Where the mouse must go to bring the panel back.
    private func trigger(for frame: NSRect) -> NSRect {
        guard isAtLeftEdge(frame), let visible = screenVisible else { return frame }
        // The cursor stops at the screen's edge, so a thin strip there is enough.
        return NSRect(x: visible.minX - 1, y: frame.minY,
                      width: Self.edgeHotZone + 1, height: frame.height)
    }

    private func hiddenFrame(for frame: NSRect) -> NSRect {
        isAtLeftEdge(frame) ? frame.offsetBy(dx: -frame.width, dy: 0) : frame
    }

    private func hide() {
        guard let panel, !isHidden else { return }
        isHidden = true
        panel.ignoresMouseEvents = true
        let target = hiddenFrame(for: dock.dockedFrame())
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }
    }

    private func show() {
        guard let panel, isHidden else { return }
        isHidden = false
        lastNearby = Date()
        panel.ignoresMouseEvents = false
        let frame = dock.dockedFrame()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }
}
