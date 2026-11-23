import Darwin
import Foundation

/// A Claude Code process as described by `~/.claude/sessions/<pid>.json`.
public struct ClaudeSession: Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    /// Claude Code's derived name, e.g. "wallet-05".
    public let name: String
    /// Milliseconds since 1970.
    public let startedAt: Double?

    public init(pid: Int32, sessionId: String, cwd: String, name: String, startedAt: Double?) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.startedAt = startedAt
    }
}

/// Locations of Claude Code's files. Overridable for tests.
public struct ClaudePaths: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.root = root
    }
    public var sessions: URL { root.appendingPathComponent("sessions") }
    public var projects: URL { root.appendingPathComponent("projects") }
}

public enum ClaudeSessions {
    /// Interactive sessions whose process is still alive, oldest first.
    public static func live(paths: ClaudePaths = ClaudePaths(),
                            isAlive: (Int32) -> Bool = processExists) -> [ClaudeSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessions,
                                                                   includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        var result: [ClaudeSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = parse(data), isAlive(session.pid),
                  seen.insert(session.sessionId).inserted else { continue }
            result.append(session)
        }
        return result.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    }

    static func parse(_ data: Data) -> ClaudeSession? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["kind"] as? String) == "interactive",
              let pid = (json["pid"] as? NSNumber)?.int32Value,
              let sid = json["sessionId"] as? String,
              let cwd = json["cwd"] as? String else { return nil }
        return ClaudeSession(pid: pid, sessionId: sid, cwd: cwd,
                             name: json["name"] as? String ?? "",
                             startedAt: (json["startedAt"] as? NSNumber)?.doubleValue)
    }

    public static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// `~/.claude/projects/<dir>/<sessionId>.jsonl`. The directory name encodes
    /// the cwd; instead of re-deriving that encoding, the first match is cached.
    public final class TranscriptLocator: @unchecked Sendable {
        private let paths: ClaudePaths
        private var cache: [String: String] = [:]
        private let lock = NSLock()

        public init(paths: ClaudePaths = ClaudePaths()) { self.paths = paths }

        public func transcript(for sessionId: String, cwd: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let hit = cache[sessionId], FileManager.default.fileExists(atPath: hit) { return hit }
            let name = sessionId + ".jsonl"
            // Claude Code replaces every non-alphanumeric character with "-".
            let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            var candidates = [paths.projects.appendingPathComponent(encoded).appendingPathComponent(name).path]
            let dirs = (try? FileManager.default.contentsOfDirectory(atPath: paths.projects.path)) ?? []
            candidates += dirs.map { paths.projects.appendingPathComponent($0).appendingPathComponent(name).path }
            guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
            cache[sessionId] = found
            return found
        }

        /// Subagent transcripts of a session: `<dir>/<sessionId>/subagents/*.jsonl`.
        public static func subagentTranscripts(of transcript: String) -> [String] {
            let dir = (transcript as NSString).deletingPathExtension + "/subagents"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return names.filter { $0.hasSuffix(".jsonl") }.map { dir + "/" + $0 }
        }
    }
}
