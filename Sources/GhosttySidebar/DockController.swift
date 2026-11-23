import AppKit
import Combine
import GhosttyBridge

/// Where the sidebar sits, how big it is, and how Ghostty windows relate to it:
/// pushed out from under it (arrange) or attached to its right edge (snap).
/// Menu actions in the SwiftUI view call into this; `AppDelegate` applies the frame.
@MainActor
final class DockController: ObservableObject {
    struct ScreenChoice: Identifiable, Equatable {
        let id: String          // localizedName, used as the persisted key
        let isPrimary: Bool
    }

    private enum Key {
        static let screen = "dockScreenName"
        static let autoArrange = "autoArrangeGhostty"
        static let snapOnSelect = "snapGhosttyOnSelect"
        static let snapFillWidth = "snapFillWidth"
        static let width = "panelWidth"
        static let height = "panelHeight"   // absent = down to the bottom of the screen
        static let offsetX = "panelOffsetX"   // from the visible frame's left edge
        static let offsetTop = "panelOffsetTop" // from the visible frame's top edge
        static let autoHide = "autoHideSidebar"
    }

    static let defaultWidth: CGFloat = 260
    static let widthRange: ClosedRange<CGFloat> = 200...480
    static let minimumHeight: CGFloat = 280
    /// Within this distance of the screen's left or top edge, a dragged panel sticks to it.
    static let edgeMagnet: CGFloat = 16

    @Published private(set) var screens: [ScreenChoice] = []
    @Published private(set) var selectedScreenName: String?
    @Published var autoArrange: Bool {
        didSet {
            defaults.set(autoArrange, forKey: Key.autoArrange)
            if autoArrange { arrangeNow() }
        }
    }
    /// Clicking a tab moves its Ghostty window next to the sidebar.
    @Published var snapOnSelect: Bool {
        didSet {
            defaults.set(snapOnSelect, forKey: Key.snapOnSelect)
            if !snapOnSelect { snapper?.detach() }
        }
    }
    /// Snapped windows fill the space right of the sidebar instead of keeping their width.
    @Published var snapFillWidth: Bool {
        didSet {
            defaults.set(snapFillWidth, forKey: Key.snapFillWidth)
            resnapAttached()
        }
    }
    @Published private(set) var panelWidth: CGFloat
    /// nil means from the panel's top down to the bottom of the visible frame.
    @Published private(set) var panelHeight: CGFloat?
    /// Panel position inside the screen's visible frame. 0,0 is the top-left corner.
    @Published private(set) var offsetX: CGFloat
    @Published private(set) var offsetTop: CGFloat
    @Published private(set) var lastArrangeMessage: String?
    /// Like the macOS Dock: the sidebar hides when the mouse leaves it and comes
    /// back when the mouse touches the screen edge. Snapped Ghostty windows then
    /// take the sidebar's space, and the sidebar slides in over them.
    @Published var autoHide: Bool {
        didSet {
            defaults.set(autoHide, forKey: Key.autoHide)
            onAutoHideChange?(autoHide)
            resnapAttached()
            if !autoHide, autoArrange { arrangeNow() }
        }
    }
    /// True while the user drags the header or an edge; the sidebar must not hide then.
    private(set) var isInteracting = false
    /// True while macOS has not granted Accessibility. The view shows a banner
    /// with a button to the settings pane; a watcher clears it once granted.
    @Published private(set) var needsAccessibility = false

    /// Called whenever the panel frame must change.
    var onFrameChange: ((NSRect) -> Void)?
    var onAutoHideChange: ((Bool) -> Void)?

    private let defaults = UserDefaults.standard
    private let arranger: GhosttyWindowArranger?
    private let snapper: GhosttyWindowSnapper?
    private let arrangeQueue = DispatchQueue(label: "ghostty-sidebar.arrange")
    private var lastWindowCount = 0
    private var askedForAccessibility = false
    private var resnapPending = false
    private var accessibilityWatch: Task<Void, Never>?
    /// The tab clicked while permission was missing; snapped once it is granted.
    private var pendingSnapTab: GhosttyTab?
    /// Mouse position and panel frame when a header drag started.
    private var moveStart: (mouse: NSPoint, frame: NSRect)?
    private var cancellables: Set<AnyCancellable> = []

    init(store: SidebarStore, isMock: Bool) {
        // Never move real windows while showing mock data.
        self.arranger = isMock ? nil : GhosttyWindowArranger()
        self.snapper = isMock ? nil : GhosttyWindowSnapper()
        self.autoArrange = defaults.object(forKey: Key.autoArrange) as? Bool ?? true
        self.snapOnSelect = defaults.object(forKey: Key.snapOnSelect) as? Bool ?? true
        self.snapFillWidth = defaults.object(forKey: Key.snapFillWidth) as? Bool ?? true
        self.selectedScreenName = defaults.string(forKey: Key.screen)
        let savedWidth = defaults.object(forKey: Key.width) as? Double
        self.panelWidth = savedWidth.map { CGFloat($0) } ?? Self.defaultWidth
        self.panelHeight = (defaults.object(forKey: Key.height) as? Double).map { CGFloat($0) }
        self.offsetX = CGFloat(defaults.double(forKey: Key.offsetX))
        self.autoHide = defaults.bool(forKey: Key.autoHide)
        self.offsetTop = CGFloat(defaults.double(forKey: Key.offsetTop))
        reloadScreens()

        // A new Ghostty window appeared: push it out from under the sidebar.
        store.$windows
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                guard let self else { return }
                defer { self.lastWindowCount = count }
                if count > self.lastWindowCount, self.autoArrange { self.arrangeNow() }
            }
            .store(in: &cancellables)

        store.onSelected = { [weak self] tab in self?.snapAfterSelect(tab) }
        if !isMock, !AXIsProcessTrusted() { markAccessibilityMissing() }
    }

    // MARK: Screens

    func reloadScreens() {
        screens = NSScreen.screens.enumerated().map { i, s in
            ScreenChoice(id: s.localizedName, isPrimary: i == 0)
        }
    }

    /// The screen the sidebar should be on: the saved one if still attached, else the primary.
    var currentScreen: NSScreen? {
        if let name = selectedScreenName,
           let match = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return match
        }
        return NSScreen.screens.first
    }

    var effectiveScreenName: String? { currentScreen?.localizedName }

    func moveTo(screenName: String) {
        selectedScreenName = screenName
        defaults.set(screenName, forKey: Key.screen)
        redock()
    }

    /// Re-applies the frame (screen added/removed, or a new choice) and re-arranges.
    func redock() {
        reloadScreens()
        onFrameChange?(dockedFrame())
        if autoArrange { arrangeNow() }
        resnapAttached()
    }

    private var visibleFrame: NSRect {
        currentScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The panel frame on the chosen screen: saved offset from the top-left corner,
    /// saved width and height, all clamped so the panel stays on the screen.
    func dockedFrame() -> NSRect {
        PanelLayout.frame(in: visibleFrame, width: panelWidth, height: panelHeight,
                          offsetX: offsetX, offsetTop: offsetTop,
                          widthRange: Self.widthRange, minimumHeight: Self.minimumHeight)
    }

    // MARK: Moving (drag on the header)

    /// `translation` is how far the gesture had already moved (top-left origin)
    /// before it was recognised, so the panel does not lag behind the cursor.
    func beginMove(translation: CGSize) {
        let now = NSEvent.mouseLocation
        let mouse = NSPoint(x: now.x - translation.width, y: now.y + translation.height)
        moveStart = (mouse, dockedFrame())
        isInteracting = true
    }

    /// The panel follows the mouse. It may cross to another monitor, and it
    /// sticks to the left or top edge when it comes close.
    func move(toMouse mouse: NSPoint) {
        guard let start = moveStart else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? currentScreen
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: start.frame.minX + mouse.x - start.mouse.x,
                             y: start.frame.minY + mouse.y - start.mouse.y)
        var x = origin.x - visible.minX
        var top = visible.maxY - (origin.y + start.frame.height)
        if abs(x) < Self.edgeMagnet { x = 0 }
        if abs(top) < Self.edgeMagnet { top = 0 }
        if screen.localizedName != selectedScreenName { selectedScreenName = screen.localizedName }
        offsetX = max(x, 0)
        offsetTop = max(top, 0)
        onFrameChange?(dockedFrame())
        scheduleResnap()
    }

    func endMove() {
        moveStart = nil
        // Store the clamped values, so the saved position is the one on screen.
        let frame = dockedFrame()
        offsetX = frame.minX - visibleFrame.minX
        offsetTop = visibleFrame.maxY - frame.maxY
        if let name = selectedScreenName { defaults.set(name, forKey: Key.screen) }
        defaults.set(Double(offsetX), forKey: Key.offsetX)
        defaults.set(Double(offsetTop), forKey: Key.offsetTop)
        endResize()
    }

    // MARK: Resizing (drag handles in the view)

    /// Drag on the right edge: width follows the mouse.
    func resizeWidth(toMouseX x: CGFloat) {
        isInteracting = true
        let newWidth = min(max(x - dockedFrame().minX, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        guard abs(newWidth - panelWidth) >= 1 else { return }
        panelWidth = newWidth
        onFrameChange?(dockedFrame())
        scheduleResnap()
    }

    /// Drag on the bottom edge: height follows the mouse (panel stays anchored at the top).
    func resizeHeight(toMouseY y: CGFloat) {
        isInteracting = true
        let top = dockedFrame().maxY
        let room = top - visibleFrame.minY
        let newHeight = min(max(top - y, Self.minimumHeight), room)
        // Within a few points of the bottom: reach down to the bottom again.
        let snapped: CGFloat? = newHeight >= room - 8 ? nil : newHeight
        guard snapped != panelHeight else { return }
        panelHeight = snapped
        onFrameChange?(dockedFrame())
        scheduleResnap()
    }

    func endResize() {
        isInteracting = false
        defaults.set(Double(panelWidth), forKey: Key.width)
        if let panelHeight { defaults.set(Double(panelHeight), forKey: Key.height) }
        else { defaults.removeObject(forKey: Key.height) }
        resnapAttached()
        if autoArrange { arrangeNow() }
    }

    /// Back to the top-left corner, default width, full height.
    func resetSize() {
        panelWidth = Self.defaultWidth
        panelHeight = nil
        offsetX = 0
        offsetTop = 0
        defaults.removeObject(forKey: Key.offsetX)
        defaults.removeObject(forKey: Key.offsetTop)
        endResize()
        onFrameChange?(dockedFrame())
    }

    // MARK: Snapping a Ghostty window to the sidebar

    /// Geometry captured on the main actor for the background queue.
    private func snapPlacement() -> GhosttyWindowSnapper.Placement? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        var panel = dockedFrame()
        // Auto-hide: the window takes the sidebar's place; the sidebar overlays it.
        if autoHide { panel.size.width = 0 }
        let sidebar = ArrangePlanner.toAccessibility(panel, primaryHeight: primaryHeight)
        let screen = ArrangePlanner.toAccessibility(visibleFrame, primaryHeight: primaryHeight)
        let fill = snapFillWidth
        return { current in
            SnapPlanner.target(current: current, sidebar: sidebar, screen: screen, fillWidth: fill)
        }
    }

    private func snapAfterSelect(_ tab: GhosttyTab) {
        guard snapOnSelect, let snapper else { return }
        guard ensureAccessibility() else {
            pendingSnapTab = tab
            return
        }
        guard let place = snapPlacement() else { return }
        let title = tab.title
        arrangeQueue.async { [weak self] in
            do {
                try snapper.snapFocusedWindow(expectingTitle: title, place: place)
            } catch {
                let message = SidebarStore.describe(error)
                Task { @MainActor in self?.flash(message) }
            }
        }
    }

    /// Coalesces resnaps while a resize drag is in progress (at most ~20 per second).
    private func scheduleResnap() {
        guard !resnapPending else { return }
        resnapPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            resnapPending = false
            resnapAttached()
        }
    }

    private func resnapAttached() {
        guard snapOnSelect, let snapper, AXIsProcessTrusted(), let place = snapPlacement() else { return }
        arrangeQueue.async { _ = try? snapper.resnapAttached(place: place) }
    }

    // MARK: Arranging Ghostty windows

    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Moving another app's windows needs Accessibility. Ask macOS once per launch.
        if !askedForAccessibility {
            askedForAccessibility = true
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        markAccessibilityMissing()
        return false
    }

    /// Shows the banner and polls until the user turns the permission on.
    private func markAccessibilityMissing() {
        needsAccessibility = true
        guard accessibilityWatch == nil else { return }
        accessibilityWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.accessibilityGranted()
                    return
                }
            }
        }
    }

    private func accessibilityGranted() {
        accessibilityWatch = nil
        needsAccessibility = false
        flash("손쉬운 사용 권한이 켜졌습니다")
        if autoArrange { arrangeNow() }
        if let tab = pendingSnapTab {
            pendingSnapTab = nil
            snapAfterSelect(tab)
        }
    }

    /// System Settings > Privacy & Security > Accessibility.
    func openAccessibilitySettings() {
        if !askedForAccessibility {
            askedForAccessibility = true
            // Adds this app to the list so the user only has to flip the switch.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func arrangeNow() {
        // An auto-hiding sidebar is meant to overlay windows, so nothing to push away.
        if autoHide { return }
        guard let arranger, let primaryHeight = NSScreen.screens.first?.frame.height,
              ensureAccessibility() else { return }
        let sidebar = ArrangePlanner.toAccessibility(dockedFrame(), primaryHeight: primaryHeight)
        let area = ArrangePlanner.toAccessibility(visibleFrame, primaryHeight: primaryHeight)
        arrangeQueue.async { [weak self] in
            let message: String?
            do {
                let moved = try arranger.arrange(avoiding: sidebar, within: area)
                message = moved > 0 ? "Ghostty 창 \(moved)개 정렬" : nil
            } catch GhosttyBridgeError.ghosttyNotRunning {
                message = nil
            } catch {
                message = SidebarStore.describe(error)
            }
            if let message { Task { @MainActor in self?.flash(message) } }
        }
    }

    private func flash(_ message: String) {
        lastArrangeMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if lastArrangeMessage == message { lastArrangeMessage = nil }
        }
    }
}
