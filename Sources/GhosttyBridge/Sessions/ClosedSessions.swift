import Foundation

/// A session whose tab was closed on purpose while the sidebar was running.
/// The conversation is still on disk, so it can be resumed for a while.
public struct ClosedSessionRecord: Codable, Sendable, Equatable {
    /// "claude" or "codex".
    public var kind: String
    public var entry: SessionSnapshot.Entry
    public var closedAt: Date

    public init(kind: String, entry: SessionSnapshot.Entry, closedAt: Date) {
        self.kind = kind
        self.entry = entry
        self.closedAt = closedAt
    }
}

public enum ClosedSessionStore {
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    public static let maxCount = 30

    private struct File: Codable {
        var sessions: [ClosedSessionRecord]
    }

    public static func load(from url: URL) -> [ClosedSessionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data))?.sessions ?? []
    }

    public static func save(_ records: [ClosedSessionRecord], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(File(sessions: records)).write(to: url, options: .atomic)
    }

    /// Newest first, one record per session, at most `maxCount`, none older than `maxAge`.
    public static func pruned(_ records: [ClosedSessionRecord], now: Date = Date()) -> [ClosedSessionRecord] {
        var seen = Set<String>()
        return records
            .filter { now.timeIntervalSince($0.closedAt) <= maxAge }
            .sorted { $0.closedAt > $1.closedAt }
            .filter { seen.insert($0.entry.sessionId).inserted }
            .prefix(maxCount)
            .map { $0 }
    }
}

extension CodexSessions {
    /// Session ids that still have a rollout file, across all days.
    /// Walks `~/.codex/sessions`; called rarely (pruning), not on every poll.
    public static func sessionIdsWithRollouts(paths: Paths = Paths()) -> Set<String> {
        var ids = Set<String>()
        guard let walker = FileManager.default.enumerator(atPath: paths.sessions.path) else { return ids }
        for case let file as String in walker where file.hasSuffix(".jsonl") {
            let name = (file as NSString).lastPathComponent
            // rollout-2026-11-12T12-58-31-<uuid>.jsonl: the uuid is the last 36 characters.
            let stem = (name as NSString).deletingPathExtension
            if stem.count > 36 { ids.insert(String(stem.suffix(36))) }
        }
        return ids
    }
}
