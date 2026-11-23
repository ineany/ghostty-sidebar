import Foundation

/// The sidebar's list of open sessions. The format is the one the old
/// `cc-session` script wrote, so its files can still be read.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: String { sessionId }
        public var sessionId: String
        public var cwd: String
        public var pid: Int32?
        public var name: String?
        public var title: String?
        public var branch: String?
        public var turns: Int?
        public var startedAt: Double?
        public var lastActivity: String?
        public var transcriptBytes: Int?

        public init(sessionId: String, cwd: String, pid: Int32? = nil, name: String? = nil,
                    title: String? = nil, branch: String? = nil, turns: Int? = nil,
                    startedAt: Double? = nil, lastActivity: String? = nil, transcriptBytes: Int? = nil) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.pid = pid
            self.name = name
            self.title = title
            self.branch = branch
            self.turns = turns
            self.startedAt = startedAt
            self.lastActivity = lastActivity
            self.transcriptBytes = transcriptBytes
        }

        public var displayTitle: String {
            if let title, !title.isEmpty { return title }
            if let name, !name.isEmpty { return name }
            return String(sessionId.prefix(8))
        }
    }

    public var savedAt: String
    public var count: Int
    public var sessions: [Entry]

    public init(savedAt: String, sessions: [Entry]) {
        self.savedAt = savedAt
        self.count = sessions.count
        self.sessions = sessions
    }
}

public enum SessionSnapshotStore {
    public static let historyLimit = 10
    /// At most one history copy per this interval, so a burst of saves (tabs
    /// opening and closing) does not push the older copies out.
    public static let historyInterval: TimeInterval = 600

    public static func load(from file: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Writes the snapshot. The previous one is copied to `history` first and only
    /// the newest `historyLimit` copies are kept.
    public static func save(_ snapshot: SessionSnapshot, to file: URL, history: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        let copies = ((try? fm.contentsOfDirectory(atPath: history.path)) ?? [])
            .filter { $0.hasPrefix("snapshot-") && $0.hasSuffix(".json") }
            .sorted()
        let newestCopy = copies.last
            .flatMap { stampFormatter.date(from: String($0.dropFirst("snapshot-".count).dropLast(".json".count))) }
        let due = newestCopy.map { Date().timeIntervalSince($0) >= historyInterval } ?? true
        if due, let attrs = try? fm.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date {
            let stamp = stampFormatter.string(from: modified)
            let copy = history.appendingPathComponent("snapshot-\(stamp).json")
            try? fm.removeItem(at: copy)
            try? fm.copyItem(at: file, to: copy)
            let old = ((try? fm.contentsOfDirectory(atPath: history.path)) ?? [])
                .filter { $0.hasPrefix("snapshot-") && $0.hasSuffix(".json") }
                .sorted()
            for name in old.dropLast(historyLimit) {
                try? fm.removeItem(at: history.appendingPathComponent(name))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    public static let savedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
