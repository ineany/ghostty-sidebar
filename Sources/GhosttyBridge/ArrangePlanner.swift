import CoreGraphics

/// Decides where Ghostty windows go so the sidebar does not cover them.
///
/// All rectangles use the Accessibility coordinate space: origin at the top-left
/// of the primary screen, y grows downward. This is what System Events reports.
public enum ArrangePlanner {
    /// Windows narrower than this after shrinking are still kept at this width.
    public static let minimumWidth: CGFloat = 400

    /// Returns new frames keyed by window position in `windows` (0-based).
    /// Windows that do not overlap the sidebar, or that live on another screen,
    /// are left out of the result and must not be touched.
    ///
    /// - Parameters:
    ///   - windows: current Ghostty window frames.
    ///   - sidebar: the sidebar panel frame.
    ///   - screen: the usable area (visible frame) of the screen the sidebar is on.
    public static func plan(windows: [CGRect], sidebar: CGRect, screen: CGRect) -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        for (i, frame) in windows.enumerated() {
            guard frame.width > 0, frame.height > 0 else { continue }
            // Only windows whose centre is on the sidebar's screen.
            guard screen.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            guard frame.intersects(sidebar) else { continue }

            let sidebarOnLeft = sidebar.midX < screen.midX
            var target = frame
            if sidebarOnLeft {
                let maxX = min(frame.maxX, screen.maxX)
                target.origin.x = sidebar.maxX
                target.size.width = max(maxX - sidebar.maxX, minimumWidth)
            } else {
                let minX = max(frame.minX, screen.minX)
                target.size.width = max(sidebar.minX - minX, minimumWidth)
                target.origin.x = sidebar.minX - target.size.width
            }
            // Keep the window vertically inside the usable area.
            if target.minY < screen.minY { target.origin.y = screen.minY }
            if target.maxY > screen.maxY {
                target.size.height = max(screen.maxY - target.minY, 200)
            }
            target = target.integral
            if target != frame.integral { result[i] = target }
        }
        return result
    }

    /// Converts an AppKit rectangle (origin bottom-left of the primary screen,
    /// y up) to the Accessibility space. `primaryHeight` is the height of
    /// `NSScreen.screens[0].frame`.
    public static func toAccessibility(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
