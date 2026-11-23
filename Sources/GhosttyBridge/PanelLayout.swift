import CoreGraphics

/// Where the sidebar panel sits inside a screen's visible frame (AppKit coordinates,
/// bottom-left origin). Pure, so it can be unit-tested.
public enum PanelLayout {
    /// - Parameters:
    ///   - height: nil means from the panel's top down to the bottom of `visible`.
    ///   - offsetX: distance from the left edge of `visible`.
    ///   - offsetTop: distance from the top edge of `visible`.
    /// The result always lies inside `visible`.
    public static func frame(in visible: CGRect, width: CGFloat, height: CGFloat?,
                             offsetX: CGFloat, offsetTop: CGFloat,
                             widthRange: ClosedRange<CGFloat>, minimumHeight: CGFloat) -> CGRect {
        let w = min(max(width, widthRange.lowerBound), widthRange.upperBound, visible.width)
        let x = min(max(offsetX, 0), visible.width - w)
        let top = min(max(offsetTop, 0), max(visible.height - minimumHeight, 0))
        let room = visible.height - top
        let h = min(max(height ?? room, minimumHeight), room)
        return CGRect(x: visible.minX + x, y: visible.maxY - top - h, width: w, height: h)
    }
}
