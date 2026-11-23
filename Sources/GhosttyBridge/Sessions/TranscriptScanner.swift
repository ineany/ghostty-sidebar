import Foundation

/// What one transcript file adds up to so far.
public struct TranscriptSummary: Sendable, Equatable {
    /// Total cost at API rates, every response counted once.
    public var cost: Double = 0
    /// Cost per local calendar day ("2026-11-15").
    public var costByDay: [String: Double] = [:]
    /// Latest "ai-title" record: the one-line title Claude Code also puts in the tab title.
    public var aiTitle: String?
    public var gitBranch: String?
    public var lastModel: String?
    /// Number of user prompts (lines of type "user" that are not tool results).
    public var turns = 0

    public init() {}
}

/// Reads Claude Code transcripts (`~/.claude/projects/<dir>/<session>.jsonl`)
/// incrementally: each call only parses the bytes appended since the last call,
/// so polling a 15 MB transcript costs almost nothing after the first pass.
///
/// Claude Code writes one line per content block, and every line of a response
/// repeats the same `usage`. Responses are therefore counted once per `message.id`.
public final class TranscriptScanner: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64 = 0
        var summary = TranscriptSummary()
        var seen: Set<String> = []
        /// Bytes after the last newline, kept until the line is complete.
        var partial = Data()
    }

    private var files: [String: FileState] = [:]
    private let lock = NSLock()
    private let dayFormatter: DateFormatter
    private let isoFractional = ISO8601DateFormatter()
    private let isoPlain = ISO8601DateFormatter()

    public init(timeZone: TimeZone = .current) {
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain.formatOptions = [.withInternetDateTime]
    }

    public func day(of date: Date) -> String { dayFormatter.string(from: date) }

    static let chunkSize = 1 << 20

    /// Summary of `path` including everything written so far. Safe from any thread.
    public func summary(of path: String) -> TranscriptSummary {
        lock.lock()
        defer { lock.unlock() }
        var state = files[path] ?? FileState()
        guard let handle = FileHandle(forReadingAtPath: path) else { return state.summary }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() }   // file was replaced
        if size > state.offset {
            try? handle.seek(toOffset: state.offset)
            // Read in chunks: a first pass over a 15 MB transcript must not hold
            // the whole file (and every parsed line) in memory at once.
            while state.offset < size {
                let chunk: Data? = autoreleasepool { try? handle.read(upToCount: Self.chunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                state.offset += UInt64(chunk.count)
                autoreleasepool {
                    var data = state.partial
                    data.append(chunk)
                    consume(data, into: &state)
                }
            }
        }
        files[path] = state
        return state.summary
    }

    /// Forgets files that are no longer polled.
    public func retain(only paths: Set<String>) {
        lock.lock()
        files = files.filter { paths.contains($0.key) }
        lock.unlock()
    }

    private func consume(_ data: Data, into state: inout FileState) {
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            parse(line: data[start..<newline], into: &state)
            start = data.index(after: newline)
        }
        state.partial = Data(data[start...])
    }

    // Cheap byte checks first: most lines are tool output and need no JSON parse.
    private static let usageKey = Data("\"usage\"".utf8)
    private static let titleKey = Data("\"ai-title\"".utf8)
    private static let userKey = Data("\"type\":\"user\"".utf8)

    private func parse(line: Data, into state: inout FileState) {
        let hasUsage = line.range(of: Self.usageKey) != nil
        let hasTitle = !hasUsage && line.range(of: Self.titleKey) != nil
        let isUser = !hasUsage && !hasTitle && line.range(of: Self.userKey) != nil
        guard hasUsage || hasTitle || isUser,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        if hasTitle {
            if let title = object["aiTitle"] as? String, !title.isEmpty { state.summary.aiTitle = title }
            return
        }
        if let branch = object["gitBranch"] as? String, !branch.isEmpty { state.summary.gitBranch = branch }
        if isUser {
            // Tool results are also "user" lines; a typed prompt has string content.
            if let message = object["message"] as? [String: Any], message["content"] is String {
                state.summary.turns += 1
            }
            return
        }
        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usageJSON = message["usage"] as? [String: Any],
              let model = message["model"] as? String else { return }
        let id = (message["id"] as? String) ?? (object["requestId"] as? String) ?? (object["uuid"] as? String) ?? ""
        guard state.seen.insert(id).inserted else { return }
        state.summary.lastModel = model
        guard let cost = Pricing.cost(TokenUsage(json: usageJSON), model: model) else { return }
        state.summary.cost += cost
        if let stamp = object["timestamp"] as? String,
           let date = isoFractional.date(from: stamp) ?? isoPlain.date(from: stamp) {
            state.summary.costByDay[day(of: date), default: 0] += cost
        }
    }
}
