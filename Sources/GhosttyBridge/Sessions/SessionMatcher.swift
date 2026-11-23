import Foundation

/// Pairs Ghostty tabs with Claude Code sessions.
///
/// Ghostty does not expose a tab's process, but Claude Code sets the terminal
/// title to its AI title ("✳ Sentry MCP URL"), and the same title is the latest
/// "ai-title" record in the session's transcript. Tabs are matched on that title,
/// with the working directory deciding between sessions that share a title.
public enum SessionMatcher {
    public struct Candidate: Sendable, Equatable {
        public let sessionId: String
        public let cwd: String
        public let titles: [String]   // ai title first, then the session name

        public init(sessionId: String, cwd: String, titles: [String]) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.titles = titles
        }
    }

    /// tab id -> session id. Each session is used for at most one tab.
    public static func match(tabs: [GhosttyTab], sessions: [Candidate]) -> [String: String] {
        var result: [String: String] = [:]
        var used = Set<String>()
        let claudeTabs = tabs.filter { $0.status != .unknown }
        // Exact title and same cwd first, then exact title anywhere, then a title
        // prefix (Ghostty may truncate very long titles).
        let passes: [(GhosttyTab, Candidate) -> Bool] = [
            { tab, s in s.titles.contains(tab.title) && sameDir(tab.workingDirectory, s.cwd) },
            { tab, s in s.titles.contains(tab.title) },
            { tab, s in tab.title.count >= 12 && s.titles.contains { $0.hasPrefix(tab.title) || tab.title.hasPrefix($0) } },
        ]
        for pass in passes {
            for tab in claudeTabs where result[tab.id] == nil {
                if let hit = sessions.first(where: { !used.contains($0.sessionId) && pass(tab, $0) }) {
                    result[tab.id] = hit.sessionId
                    used.insert(hit.sessionId)
                }
            }
        }
        return result
    }

    static func sameDir(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return a.trimmingTrailingSlash == b.trimmingTrailingSlash
    }
}

extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
