import Foundation

/// Where the sidebar keeps its own lists of open sessions.
///
/// Claude Code and Codex save the conversations themselves; the sidebar only
/// remembers which sessions were open, so it keeps that list in its own folder
/// instead of writing into `~/.claude` or `~/.codex`.
public struct SessionListPaths: Sendable {
    public let root: URL

    public init(root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ghostty Sidebar/sessions")) {
        self.root = root
    }

    public var claude: URL { root.appendingPathComponent("claude.json") }
    public var codex: URL { root.appendingPathComponent("codex.json") }
    /// Sessions closed on purpose, kept for a week so they can still be reopened.
    public var closed: URL { root.appendingPathComponent("closed.json") }
    public var claudeHistory: URL { root.appendingPathComponent("history/claude") }
    public var codexHistory: URL { root.appendingPathComponent("history/codex") }

    /// Lists written by earlier versions (and the old `cc-session` script),
    /// read once to carry restore candidates over.
    public static let legacyClaude = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/session-restore/snapshot.json")
    public static let legacyCodex = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/session-restore/snapshot.json")
}
