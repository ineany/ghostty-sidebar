import CoreGraphics

/// Where a Ghostty window goes when it "snaps" to the right of the sidebar.
/// Accessibility coordinates (top-left origin, y down), like `ArrangePlanner`.
public enum SnapPlanner {
    public static let minimumWidth: CGFloat = 400

    /// - Parameters:
    ///   - current: the window's current frame.
    ///   - sidebar: the sidebar panel frame.
    ///   - screen: visible frame of the sidebar's screen.
    ///   - fillWidth: true fills the space right of the sidebar; false keeps the
    ///     current width as long as it fits.
    public static func target(current: CGRect, sidebar: CGRect, screen: CGRect, fillWidth: Bool) -> CGRect {
        let x = sidebar.maxX
        let available = max(screen.maxX - x, minimumWidth)
        let width = fillWidth ? available : min(max(current.width, minimumWidth), available)
        return CGRect(x: x, y: sidebar.minY, width: width, height: sidebar.height).integral
    }
}
