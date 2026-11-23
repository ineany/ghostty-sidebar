import Foundation

// Shared contract between the bridge (feat/bridge) and the UI (feat/ui).
// Changing anything in this file requires agreement from both sides.

/// What Claude Code (or a plain shell) in a tab is doing, derived from the tab title.
public enum SessionStatus: String, Sendable, Equatable, CaseIterable {
    /// Claude Code is working (spinner glyph at the start of the title, e.g. "◐").
    case busy
    /// Claude Code is idle and waiting for the user (title starts with "✳").
    case idle
    /// Not a Claude Code title (plain shell, other program) or unrecognised.
    case unknown
}

public struct GhosttyTab: Identifiable, Sendable, Equatable {
    /// Ghostty's tab id, e.g. "tab-883f4b000". Stable while the tab lives.
    public let id: String
    /// Id of the window that owns this tab.
    public let windowId: String
    /// 1-based position inside its window.
    public let index: Int
    /// Raw tab title exactly as Ghostty reports it.
    public let rawTitle: String
    /// Title with the leading status glyph and surrounding whitespace removed.
    public let title: String
    public let status: SessionStatus
    /// Whether this tab is the selected tab of its window.
    public let isSelected: Bool
    /// Working directory of the focused terminal; nil when Ghostty reports an empty value.
    public let workingDirectory: String?

    public init(id: String, windowId: String, index: Int, rawTitle: String, title: String,
                status: SessionStatus, isSelected: Bool, workingDirectory: String?) {
        self.id = id
        self.windowId = windowId
        self.index = index
        self.rawTitle = rawTitle
        self.title = title
        self.status = status
        self.isSelected = isSelected
        self.workingDirectory = workingDirectory
    }
}

public struct GhosttyWindow: Identifiable, Sendable, Equatable {
    public let id: String
    /// 1-based position in Ghostty's window list (front-most first).
    public let index: Int
    public let tabs: [GhosttyTab]

    public init(id: String, index: Int, tabs: [GhosttyTab]) {
        self.id = id
        self.index = index
        self.tabs = tabs
    }
}

public enum GhosttyBridgeError: Error, Equatable, CustomStringConvertible {
    case ghosttyNotRunning
    case scriptFailed(String)
    case tabNotFound(String)
    case notImplemented

    public var description: String {
        switch self {
        case .ghosttyNotRunning: return "Ghostty is not running"
        case .scriptFailed(let m): return "AppleScript failed: \(m)"
        case .tabNotFound(let id): return "tab not found: \(id)"
        case .notImplemented: return "not implemented"
        }
    }
}

/// Everything the UI needs from Ghostty. Implementations must be safe to call
/// from a background thread; callers must never call them on the main thread.
public protocol GhosttyControlling: Sendable {
    /// All windows and their tabs, in Ghostty's order.
    func snapshot() throws -> [GhosttyWindow]
    /// Select the tab and bring its window (and Ghostty) to the front.
    func select(tabId: String) throws
    /// Open a new tab in the front window (or a new window when none is open).
    /// - Parameters:
    ///   - workingDirectory: the shell's starting directory; nil for Ghostty's default.
    ///   - input: text typed into the new shell after it starts, e.g. "claude\n".
    func openTab(workingDirectory: String?, input: String?) throws
}

/// Factory used by the app and the probe. The bridge branch replaces the body.
public func makeDefaultBridge() -> GhosttyControlling {
    AppleScriptGhosttyBridge()
}
