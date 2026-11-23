import Darwin
import Foundation

/// A running Codex CLI (TUI) session.
public struct CodexSession: Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let threadName: String?
    public let rollout: String
    /// Seconds since 1970.
    public let processStart: TimeInterval

    public init(pid: Int32, sessionId: String, cwd: String, threadName: String?,
                rollout: String, processStart: TimeInterval) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.threadName = threadName
        self.rollout = rollout
        self.processStart = processStart
    }
}

/// Codex keeps no per-process file like Claude Code's `~/.claude/sessions/<pid>.json`,
/// so running sessions are found in two steps:
/// 1. Running `codex` processes that own a terminal (the TUI), with their cwd and start time.
/// 2. Their rollout file `~/.codex/sessions/YYYY/MM/DD/rollout-<local start>-<id>.jsonl`.
///    A new session's rollout is created just after the process starts, in the same cwd.
///    Codex hides its arguments (ps shows only "codex") and a resumed session
///    writes nothing until the next prompt, so a resume is recognised two ways:
///    a `Hint` left by whoever typed `codex resume <id>` (the sidebar's restore),
///    or, once the session is used, the rollout in that cwd written to since the
///    process started.
public enum CodexSessions {
    public struct Process: Sendable, Equatable {
        public let pid: Int32
        public let cwd: String
        public let start: TimeInterval
        public let arguments: [String]

        public init(pid: Int32, cwd: String, start: TimeInterval, arguments: [String]) {
            self.pid = pid
            self.cwd = cwd
            self.start = start
            self.arguments = arguments
        }

        /// The id after `resume`, when the session was resumed by id.
        var resumedId: String? {
            guard let i = arguments.firstIndex(of: "resume"), i + 1 < arguments.count else { return nil }
            let candidate = arguments[i + 1]
            return UUID(uuidString: candidate) != nil ? candidate.lowercased() : nil
        }
    }

    public struct Rollout: Sendable, Equatable {
        public let path: String
        public let sessionId: String
        public let cwd: String
        /// Start time encoded in the file name.
        public let created: TimeInterval
        public let modified: TimeInterval

        public init(path: String, sessionId: String, cwd: String, created: TimeInterval, modified: TimeInterval) {
            self.path = path
            self.sessionId = sessionId
            self.cwd = cwd
            self.created = created
            self.modified = modified
        }
    }

    /// "`codex resume <sessionId>` was started in `cwd` at `time`."
    public struct Hint: Sendable, Equatable {
        public let sessionId: String
        public let cwd: String
        public let time: TimeInterval

        public init(sessionId: String, cwd: String, time: TimeInterval) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.time = time
        }
    }

    /// Rollouts created this long before the process still count as its own
    /// (clock rounding; the file name has whole seconds).
    static let createdSlack: TimeInterval = 5

    /// Pairs processes with rollouts. Each rollout is used once.
    /// - Parameters:
    ///   - owners: session id -> pid from the previous match. A process keeps its session.
    ///   - released: session id -> when its process ended. Another process in the same
    ///     folder may only take that session once the rollout is written again, i.e.
    ///     after it really was resumed there. Without this, closing one of two Codex
    ///     tabs in a folder hands the closed session to the other one.
    ///   - locked: session ids with a lock in `~/.codex/thread-writer-locks`. Codex
    ///     holds one per open thread and deletes it on exit, so a guessed match
    ///     (the picker-resume fallback) must name a locked session. nil skips the check.
    public static func match(processes: [Process], rollouts: [Rollout],
                             hints: [Hint] = [],
                             owners: [String: Int32] = [:],
                             released: [String: TimeInterval] = [:],
                             locked: Set<String>? = nil) -> [(Process, Rollout)] {
        var used = Set<String>()
        var result: [(Process, Rollout)] = []
        // Explicit ids first, then sessions a process already had, then resume
        // hints, then new sessions oldest first, then picker resumes.
        var pending = processes.sorted { $0.start < $1.start }
        for process in pending {
            guard let id = process.resumedId,
                  let rollout = rollouts.first(where: { $0.sessionId == id }) else { continue }
            used.insert(rollout.path)
            result.append((process, rollout))
        }
        pending.removeAll { p in result.contains { $0.0.pid == p.pid } }

        // A guessed match must name a session that is still open (writer lock)
        // and that was not seen closing, unless it was written to since.
        func available(_ rollout: Rollout) -> Bool {
            guard !used.contains(rollout.path) else { return false }
            if let locked, !locked.contains(rollout.sessionId) { return false }
            if let closedAt = released[rollout.sessionId], rollout.modified <= closedAt { return false }
            return true
        }

        for (sessionId, pid) in owners {
            guard let process = pending.first(where: { $0.pid == pid }),
                  !result.contains(where: { $0.1.sessionId == sessionId }),
                  let rollout = rollouts.first(where: { $0.sessionId == sessionId && available($0) })
            else { continue }
            used.insert(rollout.path)
            result.append((process, rollout))
            pending.removeAll { $0.pid == pid }
        }

        for hint in hints.sorted(by: { $0.time < $1.time }) {
            guard !result.contains(where: { $0.1.sessionId == hint.sessionId }),
                  let process = pending.first(where: { $0.cwd == hint.cwd && $0.start >= hint.time - createdSlack })
            else { continue }
            let rollout = rollouts.first { $0.sessionId == hint.sessionId }
                ?? Rollout(path: "", sessionId: hint.sessionId, cwd: hint.cwd, created: hint.time, modified: hint.time)
            if !rollout.path.isEmpty { used.insert(rollout.path) }
            result.append((process, rollout))
            pending.removeAll { $0.pid == process.pid }
        }

        // New sessions: each rollout belongs to the process in its folder that
        // started last before the rollout was created (Codex creates it at the
        // first prompt, which can be minutes after the start).
        for rollout in rollouts.sorted(by: { $0.created < $1.created }) where available(rollout) {
            guard let process = pending
                .filter({ $0.cwd == rollout.cwd && $0.start <= rollout.created + createdSlack })
                .max(by: { $0.start < $1.start }) else { continue }
            used.insert(rollout.path)
            result.append((process, rollout))
            pending.removeAll { $0.pid == process.pid }
        }

        // Resumed from the picker: the rollout written to most recently since the start.
        for process in pending {
            let resumed = rollouts
                .filter { available($0) && $0.cwd == process.cwd && $0.modified >= process.start }
                .max { $0.modified < $1.modified }
            if let resumed {
                used.insert(resumed.path)
                result.append((process, resumed))
            }
        }
        return result
    }

    // MARK: Processes

    /// Subcommands that are not an interactive session.
    static let nonInteractive: Set<String> = [
        "app-server", "exec", "e", "mcp", "mcp-server", "login", "logout", "apply", "a",
        "completion", "sandbox", "debug", "cloud", "proto", "features", "help",
    ]

    public static func runningProcesses() -> [Process] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [Process] = []
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 && name(of: pid) == "codex" {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.e_tdev != UInt32.max else { continue }   // no terminal: daemon or IDE helper
            let args = arguments(of: pid)
            if args.count > 1, nonInteractive.contains(args[1]) { continue }
            guard let cwd = workingDirectory(of: pid) else { continue }
            result.append(Process(pid: pid, cwd: cwd, start: TimeInterval(info.pbi_start_tvsec), arguments: args))
        }
        return result
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// argv via `KERN_PROCARGS2`: argc, the executable path, padding, then argv.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    // MARK: Files

    /// Locations of Codex's files. Overridable for tests.
    public struct Paths: Sendable {
        public let root: URL
        public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
            self.root = root
        }
        public var sessions: URL { root.appendingPathComponent("sessions") }
        public var index: URL { root.appendingPathComponent("session_index.jsonl") }
        public var threadLocks: URL { root.appendingPathComponent("thread-writer-locks") }
    }

    /// Reads rollout headers, caching each file's first line.
    public final class RolloutIndex: @unchecked Sendable {
        private struct Header { let sessionId: String; let cwd: String; let isSubagent: Bool }
        private let paths: Paths
        private var headers: [String: Header] = [:]
        private var names: [String: String] = [:]
        private var indexModified: Date?
        private let lock = NSLock()

        public init(paths: Paths = Paths()) { self.paths = paths }

        /// Top-level session rollouts from the last `days` days.
        public func rollouts(days: Int = 30, now: Date = Date()) -> [Rollout] {
            lock.lock()
            defer { lock.unlock() }
            let fm = FileManager.default
            let calendar = Calendar.current
            var result: [Rollout] = []
            for offset in 0..<days {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                let dir = paths.sessions
                    .appendingPathComponent(String(format: "%04d", c.year!))
                    .appendingPathComponent(String(format: "%02d", c.month!))
                    .appendingPathComponent(String(format: "%02d", c.day!)).path
                let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                for file in files where file.hasPrefix("rollout-") && file.hasSuffix(".jsonl") {
                    let path = dir + "/" + file
                    guard let header = header(of: path), !header.isSubagent,
                          let created = RolloutIndex.created(fromFileName: file),
                          let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                    else { continue }
                    result.append(Rollout(path: path, sessionId: header.sessionId, cwd: header.cwd,
                                          created: created, modified: modified.timeIntervalSince1970))
                }
            }
            return result
        }

        /// thread_name per session id from `session_index.jsonl` (last entry wins).
        public func threadNames() -> [String: String] {
            lock.lock()
            defer { lock.unlock() }
            let modified = (try? FileManager.default.attributesOfItem(atPath: paths.index.path))?[.modificationDate] as? Date
            guard modified != indexModified else { return names }
            indexModified = modified
            var result: [String: String] = [:]
            let text = (try? String(contentsOf: paths.index, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = json["id"] as? String,
                      let name = json["thread_name"] as? String, !name.isEmpty else { continue }
                result[id] = name
            }
            names = result
            return result
        }

        private func header(of path: String) -> Header? {
            if let cached = headers[path] { return cached }
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            // The first line carries the base instructions; 256 KB is plenty.
            let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            let line = data.split(separator: 0x0A, maxSplits: 1).first ?? Data()
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let id = (payload["id"] as? String) ?? (payload["session_id"] as? String),
                  let cwd = payload["cwd"] as? String else { return nil }
            let isSubagent = payload["source"] is [String: Any]   // {"subagent": {...}}
            let header = Header(sessionId: id, cwd: cwd, isSubagent: isSubagent)
            headers[path] = header
            return header
        }

        /// "rollout-2026-11-12T12-58-31-<uuid>.jsonl": local time of the session start.
        static func created(fromFileName name: String) -> TimeInterval? {
            let stamp = name.dropFirst("rollout-".count).prefix(19)
            return stampFormatter.date(from: String(stamp))?.timeIntervalSince1970
        }

        static let stampFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            return f
        }()
    }

    /// Which process had which session, kept between polls.
    public final class Ownership: @unchecked Sendable {
        public private(set) var owners: [String: Int32] = [:]
        public private(set) var released: [String: TimeInterval] = [:]
        private let lock = NSLock()

        public init() {}

        /// Releases the sessions of processes that are gone, before matching, so
        /// the same poll cannot hand them to another process.
        func prepare(alive: Set<Int32>, now: TimeInterval) -> ([String: Int32], [String: TimeInterval]) {
            lock.lock(); defer { lock.unlock() }
            for (sessionId, pid) in owners where !alive.contains(pid) {
                released[sessionId] = now
                owners[sessionId] = nil
            }
            released = released.filter { now - $0.value < 7 * 24 * 3600 }
            return (owners, released)
        }

        /// Records who has which session now.
        func record(pairs: [(Process, Rollout)]) {
            lock.lock(); defer { lock.unlock() }
            owners = Dictionary(pairs.map { ($0.1.sessionId, $0.0.pid) }, uniquingKeysWith: { a, _ in a })
            for sessionId in owners.keys { released[sessionId] = nil }
        }
    }

    /// Session ids that a running Codex holds a writer lock for.
    /// nil when the folder is missing (older Codex versions): no check then.
    public static func lockedSessionIds(paths: Paths = Paths()) -> Set<String>? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.threadLocks.path) else { return nil }
        return Set(names.filter { $0.hasSuffix(".lock") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) })
    }

    /// Running Codex sessions with their ids.
    /// - Parameter alsoReleased: sessions known to have ended earlier (e.g. the
    ///   "recently closed" list), for when this process has no memory of them.
    public static func live(index: RolloutIndex, hints: [Hint] = [],
                            ownership: Ownership = Ownership(),
                            alsoReleased: [String: TimeInterval] = [:],
                            processes: [Process] = runningProcesses(),
                            locked: Set<String>? = lockedSessionIds(),
                            now: TimeInterval = Date().timeIntervalSince1970) -> [CodexSession] {
        let (owners, released) = ownership.prepare(alive: Set(processes.map(\.pid)), now: now)
        let pairs = processes.isEmpty ? [] : match(
            processes: processes, rollouts: index.rollouts(), hints: hints, owners: owners,
            released: released.merging(alsoReleased) { max($0, $1) }, locked: locked)
        ownership.record(pairs: pairs)
        guard !pairs.isEmpty else { return [] }
        let names = index.threadNames()
        return pairs.map { process, rollout in
            CodexSession(pid: process.pid, sessionId: rollout.sessionId, cwd: process.cwd,
                         threadName: names[rollout.sessionId], rollout: rollout.path,
                         processStart: process.start)
        }
    }
}
