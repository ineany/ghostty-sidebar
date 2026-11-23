import AppKit
import ApplicationServices

/// Moves Ghostty's focused window with the Accessibility API, in process.
///
/// After `select(tabId:)` brings a tab's window to the front, that window is
/// Ghostty's focused window. The snapper grabs it, places it, and remembers it,
/// so every snapped window follows the sidebar when the sidebar moves or resizes.
/// Requires the Accessibility permission (`AXIsProcessTrusted()`).
public final class GhosttyWindowSnapper: @unchecked Sendable {
    public typealias Placement = @Sendable (CGRect) -> CGRect

    private let queue = DispatchQueue(label: "ghostty-sidebar.snapper", qos: .userInitiated)
    /// Every window snapped so far, most recent last. Confined to `queue`.
    private var attached: [AXUIElement] = []

    public init() {}

    /// Waits briefly until Ghostty's focused window shows `title`, then places it.
    /// Returns the frame that was applied.
    @discardableResult
    public func snapFocusedWindow(expectingTitle title: String?, place: Placement) throws -> CGRect {
        try queue.sync {
            let app = try ghosttyElement()
            var window: AXUIElement?
            // `select tab` returns before the window server finishes reordering.
            for attempt in 0..<12 {
                window = copyElement(app, kAXFocusedWindowAttribute)
                if let window, let title, !title.isEmpty {
                    if (copyString(window, kAXTitleAttribute) ?? "").contains(title) { break }
                } else if window != nil {
                    break
                }
                if attempt < 11 { usleep(25_000) }
            }
            guard let window else { throw GhosttyBridgeError.scriptFailed("Ghostty 앞 창을 찾지 못했습니다") }
            attached.removeAll { CFEqual($0, window) }
            attached.append(window)
            return try apply(place, to: window)
        }
    }

    /// Re-places every snapped window that still exists. Returns how many moved.
    @discardableResult
    public func resnapAttached(place: Placement) throws -> Int {
        try queue.sync {
            attached.removeAll { copyFrame($0) == nil }   // closed windows
            for window in attached { _ = try apply(place, to: window) }
            return attached.count
        }
    }

    public func detach() {
        queue.sync { attached.removeAll() }
    }

    // MARK: Accessibility helpers (run on `queue`)

    private func ghosttyElement() throws -> AXUIElement {
        guard AXIsProcessTrusted() else {
            throw GhosttyBridgeError.scriptFailed("창을 붙이려면 손쉬운 사용 권한이 필요합니다")
        }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: AppleScriptGhosttyBridge.bundleIdentifier).first else {
            throw GhosttyBridgeError.ghosttyNotRunning
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func apply(_ place: Placement, to window: AXUIElement) throws -> CGRect {
        guard let current = copyFrame(window) else {
            throw GhosttyBridgeError.scriptFailed("Ghostty 창 위치를 읽지 못했습니다")
        }
        let target = place(current)
        if target == current { return target }
        // Size, position, size: moving to another display can clamp the size to
        // the old display first, so the size is applied again after the move.
        set(window, kAXSizeAttribute, size: target.size)
        set(window, kAXPositionAttribute, point: target.origin)
        set(window, kAXSizeAttribute, size: target.size)
        return target
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func copyFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func set(_ window: AXUIElement, _ attribute: String, point: CGPoint) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(window, attribute as CFString, value)
        }
    }

    private func set(_ window: AXUIElement, _ attribute: String, size: CGSize) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(window, attribute as CFString, value)
        }
    }
}
