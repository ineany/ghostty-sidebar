import AppKit
import Combine
import GhosttyBridge

/// Follows Claude Code and Codex sessions next to the Ghostty tabs:
/// - cost of each Claude tab's session and of today, at API rates
/// - a list of the sessions that are open, so tabs can be reopened after a crash
///   or reboot. Claude Code and Codex save the conversations themselves; the
///   sidebar keeps only this list, in `~/Library/Application Support/Ghostty Sidebar/sessions/`.
/// - opening new tabs (plain shell or a new Claude session)
///
/// File reading runs on a background queue every few seconds; transcripts are
/// read incrementally, so only the first pass reads whole files.
@MainActor
final class SessionTracker: ObservableObject {
    enum Kind: String, Equatable, Sendable, Codable {
        case claude, codex

        /// What to type into the new tab's shell.
        func resumeCommand(_ sessionId: String) -> String {
            switch self {
            case .claude: return "claude --resume \(sessionId)\n"
            case .codex: return "codex resume \(sessionId)\n"
            }
        }
    }

    /// A session that was open before and can be resumed in a new tab.
    struct Restorable: Identifiable, Equatable {
        let kind: Kind
        let entry: SessionSnapshot.Entry
        /// When the sidebar saw it end; nil for sessions found in the saved list at launch.
        var closedAt: Date? = nil
        var id: String { entry.sessionId }

        /// When it was closed, else when it was last used; distantPast if unknown.
        var recency: Date {
            if let closedAt { return closedAt }
            return entry.lastActivity.flatMap { Self.activityParser.date(from: $0) } ?? .distantPast
        }

        /// Reads `lastActivity` ("2026-11-10 17:09").
        static let activityParser: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()
    }

    /// One snapshot file and what was last written to it.
    private struct SnapshotFile {
        let file: URL
        let history: URL
        var savedIds: Set<String> = []
        var lastSave = Date.distantPast
    }

    @Published private(set) var costByTab: [String: Double] = [:]
    @Published private(set) var todayCost: Double?
    /// Sessions that ended together (crash, reboot, Ghostty quit): meant to come back.
    @Published private(set) var restorable: [Restorable] = []
    /// Tabs closed one at a time, on purpose. Kept a week, newest first.
    @Published private(set) var recentlyClosed: [Restorable] = []

    var hasClosedSessions: Bool { !restorable.isEmpty || !recentlyClosed.isEmpty }
    @Published private(set) var lastSaved: Date?
    @Published private(set) var recentDirectories: [String] = []

    @Published var showCost: Bool {
        didSet { defaults.set(showCost, forKey: Key.showCost) }
    }
    @Published var autoSave: Bool {
        didSet {
            defaults.set(autoSave, forKey: Key.autoSave)
            if autoSave { saveNow() }
        }
    }

    private enum Key {
        static let showCost = "showSessionCost"
        static let autoSave = "autoSaveSessions"
        static let dismissed = "dismissedRestoreSessions"
    }

    static let pollInterval: Duration = .seconds(5)
    /// Today's total walks every transcript touched today; done less often.
    static let todayInterval: TimeInterval = 30
    /// Rewrite the snapshot at least this often so titles and branches stay fresh.
    static let refreshSaveInterval: TimeInterval = 300

    private let store: SidebarStore
    private let isMock: Bool
    private let defaults = UserDefaults.standard
    private let worker = Worker()
    private var pollTask: Task<Void, Never>?
    private var inFlight = false
    private var cancellables: Set<AnyCancellable> = []

    /// Latest background result.
    private var sessions: [Worker.SessionInfo] = []
    private var lastTodayScan = Date.distantPast
    private var codexSessions: [Worker.CodexInfo] = []
    private var snapshots: [Kind: SnapshotFile] = {
        let paths = SessionListPaths()
        return [
            .claude: SnapshotFile(file: paths.claude, history: paths.claudeHistory),
            .codex: SnapshotFile(file: paths.codex, history: paths.codexHistory),
        ]
    }()
    /// Live sessions seen in the previous poll.
    private var previousLive: [String: Restorable] = [:]
    private var dismissed: Set<String>
    /// Codex sessions this app resumed; Codex hides its arguments, so these tell
    /// the worker which process is which until the session writes again.
    private var codexHints: [CodexSessions.Hint] = []
    static let hintLifetime: TimeInterval = 12 * 3600
    private let closedFile = SessionListPaths().closed
    private var lastTranscriptCheck = Date.distantPast
    /// Closed sessions whose transcript was deleted are dropped; checked hourly.
    static let transcriptCheckInterval: TimeInterval = 3600

    init(store: SidebarStore, isMock: Bool) {
        self.store = store
        self.isMock = isMock
        self.showCost = defaults.object(forKey: Key.showCost) as? Bool ?? true
        self.autoSave = defaults.object(forKey: Key.autoSave) as? Bool ?? true
        self.dismissed = Set(defaults.stringArray(forKey: Key.dismissed) ?? [])

        // Sessions in the saved snapshot are the restore candidates at launch;
        // the ones still running are filtered out on the first poll.
        if !isMock {
            Self.migrateLegacyLists(into: snapshots)
            for kind in [Kind.claude, .codex] {
                guard let file = snapshots[kind], let snapshot = SessionSnapshotStore.load(from: file.file) else { continue }
                restorable += snapshot.sessions
                    .filter { !dismissed.contains($0.sessionId) }
                    .map { Restorable(kind: kind, entry: $0) }
                snapshots[kind]?.savedIds = Set(snapshot.sessions.map(\.sessionId))
            }
            // A session in both lists was closed on purpose after the snapshot
            // was written, so "recently closed" wins over "ended abnormally".
            recentlyClosed = ClosedSessionStore.pruned(ClosedSessionStore.load(from: closedFile))
                .compactMap { record in
                    guard let kind = Kind(rawValue: record.kind) else { return nil }
                    return Restorable(kind: kind, entry: record.entry, closedAt: record.closedAt)
                }
            let closedIds = Set(recentlyClosed.map(\.id))
            restorable.removeAll { closedIds.contains($0.id) }
        }

        store.$windows
            .removeDuplicates()
            .sink { [weak self] _ in self?.rematch() }
            .store(in: &cancellables)
    }

    func start() {
        guard !isMock, pollTask == nil else { return }
        poll()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Polling

    private func poll() {
        guard !inFlight else { return }
        inFlight = true
        let scanToday = Date().timeIntervalSince(lastTodayScan) >= Self.todayInterval
        let worker = self.worker
        let now = Date().timeIntervalSince1970
        codexHints.removeAll { now - $0.time > Self.hintLifetime }
        let hints = codexHints
        let checkTranscripts = Date().timeIntervalSince(lastTranscriptCheck) >= Self.transcriptCheckInterval
            && !recentlyClosed.isEmpty
        let closedItems = recentlyClosed.map { ($0.kind == .codex, $0.id, $0.entry.cwd) }
        // Closed Codex sessions must not be handed to another Codex in the same folder.
        let codexReleased = Dictionary(
            recentlyClosed.filter { $0.kind == .codex }.compactMap { item in
                item.closedAt.map { (item.id, $0.timeIntervalSince1970) }
            }, uniquingKeysWith: { a, _ in a })
        if checkTranscripts { lastTranscriptCheck = Date() }
        Task {
            let result = await Task.detached(priority: .utility) {
                worker.collect(includeToday: scanToday, codexHints: hints, codexReleased: codexReleased,
                               checkClosed: checkTranscripts ? closedItems : [])
            }.value
            inFlight = false
            if scanToday { lastTodayScan = Date() }
            apply(result)
        }
    }

    private func apply(_ result: Worker.Result) {
        sessions = result.sessions
        codexSessions = result.codex
        if let today = result.todayCost { todayCost = today }
        let liveItems = result.sessions.map { Restorable(kind: .claude, entry: $0.entry) }
            + result.codex.map { Restorable(kind: .codex, entry: $0.entry) }
        let live = Dictionary(liveItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Several sessions ending in one poll looks like a crash or a closed
        // window: they go to "ended abnormally". One session ending is a tab
        // closed on purpose: it goes to "recently closed".
        let now = Date()
        let ended = previousLive.values.filter { live[$0.id] == nil }
        var closedChanged = false
        for var item in ended {
            item.closedAt = now
            if ended.count >= 2 {
                if !restorable.contains(where: { $0.id == item.id }) { restorable.append(item) }
            } else {
                recentlyClosed.removeAll { $0.id == item.id }
                recentlyClosed.insert(item, at: 0)
                closedChanged = true
            }
        }
        previousLive = live
        restorable.removeAll { live[$0.id] != nil || dismissed.contains($0.id) }
        let before = recentlyClosed.count
        recentlyClosed.removeAll { live[$0.id] != nil || result.missingTranscripts.contains($0.id) }
        if recentlyClosed.count != before { closedChanged = true }
        if closedChanged { saveClosed() }

        recentDirectories = Self.directories(live: liveItems, restorable: restorable,
                                             tabs: store.windows.flatMap(\.tabs))
        rematch()
        saveIfNeeded(.claude, live: result.sessions.map(\.entry))
        saveIfNeeded(.codex, live: result.codex.map(\.entry))
    }

    private func rematch() {
        let tabs = store.windows.flatMap(\.tabs)
        let candidates = sessions.map {
            SessionMatcher.Candidate(sessionId: $0.session.sessionId, cwd: $0.session.cwd,
                                     titles: [$0.summary.aiTitle, $0.session.name].compactMap { $0 })
        }
        let matched = SessionMatcher.match(tabs: tabs, sessions: candidates)
        let costs = Dictionary(sessions.map { ($0.session.sessionId, $0.summary.cost) }, uniquingKeysWith: { a, _ in a })
        let byTab = matched.compactMapValues { costs[$0] }
        if byTab != costByTab { costByTab = byTab }
    }

    // MARK: Snapshot

    /// The snapshot holds the sessions that should be open: the running ones plus
    /// the restorable ones not yet reopened or dismissed.
    ///
    /// It is written even when no session of this kind runs. A crash or Ghostty
    /// quit ends several sessions at once, and those stay in `restorable`, so
    /// they are still in the list. A reboot kills the sidebar too, so nothing is
    /// written. Skipping the write when the list is empty (the old rule) left the
    /// last tab closed on purpose in the file, and the next launch showed it as
    /// an abnormal end.
    private func saveIfNeeded(_ kind: Kind, live: [SessionSnapshot.Entry]) {
        guard autoSave, var file = snapshots[kind] else { return }
        let entries = live + restorable.filter { $0.kind == kind }.map(\.entry)
        let ids = Set(entries.map(\.sessionId))
        let stale = Date().timeIntervalSince(file.lastSave) >= Self.refreshSaveInterval
        guard ids != file.savedIds || stale else { return }
        let snapshot = SessionSnapshot(savedAt: SessionSnapshotStore.savedAtFormatter.string(from: Date()),
                                       sessions: entries)
        do {
            try SessionSnapshotStore.save(snapshot, to: file.file, history: file.history)
            file.savedIds = ids
            file.lastSave = Date()
            snapshots[kind] = file
            lastSaved = Date()
        } catch {
            store.reportError("세션 저장 실패: \(error.localizedDescription)")
        }
    }

    func saveNow() {
        for kind in snapshots.keys {
            snapshots[kind]?.savedIds = []
            snapshots[kind]?.lastSave = .distantPast
        }
        poll()
    }

    /// Writes "recently closed", trimmed to a week and 30 entries.
    private func saveClosed() {
        let records = recentlyClosed.compactMap { item -> ClosedSessionRecord? in
            guard let closedAt = item.closedAt else { return nil }
            return ClosedSessionRecord(kind: item.kind.rawValue, entry: item.entry, closedAt: closedAt)
        }
        let kept = ClosedSessionStore.pruned(records)
        if kept.count != recentlyClosed.count {
            let ids = Set(kept.map(\.entry.sessionId))
            recentlyClosed.removeAll { !ids.contains($0.id) }
        }
        do {
            try ClosedSessionStore.save(kept, to: closedFile)
        } catch {
            store.reportError("닫힌 세션 저장 실패: \(error.localizedDescription)")
        }
    }

    /// Earlier versions kept the lists in `~/.claude/session-restore` and
    /// `~/.codex/session-restore`. Copies them once, when the new file is missing.
    private static func migrateLegacyLists(into files: [Kind: SnapshotFile]) {
        let legacy: [Kind: URL] = [.claude: SessionListPaths.legacyClaude, .codex: SessionListPaths.legacyCodex]
        for (kind, old) in legacy {
            guard let target = files[kind],
                  !FileManager.default.fileExists(atPath: target.file.path),
                  let snapshot = SessionSnapshotStore.load(from: old) else { continue }
            try? SessionSnapshotStore.save(snapshot, to: target.file, history: target.history)
        }
    }

    // MARK: Actions

    /// Reopens a saved session in a new Ghostty tab (`claude --resume` or `codex resume`).
    func restore(_ item: Restorable) {
        guard previousLive[item.id] == nil else { return }   // already running
        if item.kind == .codex {
            codexHints.append(.init(sessionId: item.id, cwd: item.entry.cwd, time: Date().timeIntervalSince1970))
        }
        store.openTab(workingDirectory: item.entry.cwd, input: item.kind.resumeCommand(item.id))
        restorable.removeAll { $0.id == item.id }
        if recentlyClosed.contains(where: { $0.id == item.id }) {
            recentlyClosed.removeAll { $0.id == item.id }
            saveClosed()
        }
    }

    func restoreAll() {
        let items = restorable
        Task {
            for item in items {
                restore(item)
                // Ghostty needs a moment between tabs, or some open in the wrong window.
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func dismiss(_ item: Restorable) {
        if recentlyClosed.contains(where: { $0.id == item.id }) {
            recentlyClosed.removeAll { $0.id == item.id }
            saveClosed()
            return
        }
        restorable.removeAll { $0.id == item.id }
        dismissed.insert(item.id)
        defaults.set(Array(dismissed.suffix(200)), forKey: Key.dismissed)
        saveNow()
    }

    func clearRecentlyClosed() {
        recentlyClosed.removeAll()
        saveClosed()
    }

    func newClaudeSession(in directory: String) {
        store.openTab(workingDirectory: directory, input: "claude\n")
    }

    func newShell(in directory: String?) {
        store.openTab(workingDirectory: directory, input: nil)
    }

    /// Lets the user pick a folder, then opens a Claude session there.
    func chooseDirectoryForClaude() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "여기서 Claude 시작"
        panel.message = "새 Claude 세션을 시작할 폴더를 고르세요"
        panel.directoryURL = recentDirectories.first.map { URL(fileURLWithPath: $0) }
        // An accessory app must come forward for the panel to take keyboard focus.
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            newClaudeSession(in: url.path)
        }
    }

    // MARK: Helpers

    /// Folders for the "new tab" menu: where sessions and tabs run, most used first.
    static func directories(live: [Restorable], restorable: [Restorable],
                            tabs: [GhosttyTab]) -> [String] {
        var counts: [String: Int] = [:]
        for s in live { counts[s.entry.cwd, default: 0] += 2 }
        for r in restorable { counts[r.entry.cwd, default: 0] += 1 }
        for t in tabs { if let dir = t.workingDirectory, !dir.isEmpty { counts[dir, default: 0] += 1 } }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return counts.keys
            .filter { $0 != home && $0 != "/" }
            .sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
            .prefix(8)
            .map { $0 }
    }
}

// MARK: - Background work

extension SessionTracker {
    /// Reads Claude's files off the main thread. Holds the incremental scanner state.
    final class Worker: @unchecked Sendable {
        struct SessionInfo: Sendable {
            let session: ClaudeSession
            let summary: TranscriptSummary
            let entry: SessionSnapshot.Entry
        }

        struct CodexInfo: Sendable {
            let session: CodexSession
            let entry: SessionSnapshot.Entry
        }

        struct Result: Sendable {
            let sessions: [SessionInfo]
            let codex: [CodexInfo]
            let todayCost: Double?
            /// Closed sessions whose conversation file no longer exists.
            var missingTranscripts: Set<String> = []
        }

        private let paths = ClaudePaths()
        private let locator: ClaudeSessions.TranscriptLocator
        private let scanner = TranscriptScanner()
        private let lock = NSLock()
        private let activityFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()

        private let codexIndex = CodexSessions.RolloutIndex()
        private let codexOwnership = CodexSessions.Ownership()

        init() { locator = ClaudeSessions.TranscriptLocator(paths: paths) }

        /// Last Codex match, reused while the same processes run with the same hints.
        private var codexCache: (key: String, time: Date, sessions: [CodexSession])?
        static let codexRefreshInterval: TimeInterval = 60

        private func codex(hints: [CodexSessions.Hint], released: [String: TimeInterval]) -> [CodexInfo] {
            // Listing processes is cheap; walking 30 days of rollout files is not.
            let processes = CodexSessions.runningProcesses()
            let key = processes.map { "\($0.pid)" }.sorted().joined(separator: ",")
                + "|" + hints.map(\.sessionId).joined(separator: ",")
            let sessions: [CodexSession]
            if let cache = codexCache, cache.key == key,
               Date().timeIntervalSince(cache.time) < Self.codexRefreshInterval {
                // A process without a rollout yet (no prompt sent) is retried every minute.
                sessions = cache.sessions
            } else {
                sessions = CodexSessions.live(index: codexIndex, hints: hints, ownership: codexOwnership,
                                              alsoReleased: released, processes: processes)
                codexCache = (key, Date(), sessions)
            }
            return sessions.map { session in
                let modified = session.rollout.isEmpty ? nil
                    : (try? FileManager.default.attributesOfItem(atPath: session.rollout))?[.modificationDate] as? Date
                let entry = SessionSnapshot.Entry(
                    sessionId: session.sessionId, cwd: session.cwd, pid: session.pid,
                    name: "codex", title: session.threadName, startedAt: session.processStart * 1000,
                    lastActivity: modified.map { activityFormatter.string(from: $0) })
                return CodexInfo(session: session, entry: entry)
            }
        }

        /// (isCodex, sessionId, cwd) of closed sessions to check for a transcript.
        typealias ClosedItem = (Bool, String, String)

        private func missing(_ items: [ClosedItem]) -> Set<String> {
            guard !items.isEmpty else { return [] }
            let codexIds = items.contains { $0.0 } ? CodexSessions.sessionIdsWithRollouts() : []
            var gone = Set<String>()
            for (isCodex, id, cwd) in items {
                let exists = isCodex ? codexIds.contains(id) : locator.transcript(for: id, cwd: cwd) != nil
                if !exists { gone.insert(id) }
            }
            return gone
        }

        func collect(includeToday: Bool, codexHints: [CodexSessions.Hint] = [],
                     codexReleased: [String: TimeInterval] = [:],
                     checkClosed: [ClosedItem] = []) -> Result {
            lock.lock()
            defer { lock.unlock() }
            var infos: [SessionInfo] = []
            var livePaths: [String] = []
            for session in ClaudeSessions.live(paths: paths) {
                guard let path = locator.transcript(for: session.sessionId, cwd: session.cwd) else { continue }
                var summary = scanner.summary(of: path)
                livePaths.append(path)
                for sub in ClaudeSessions.TranscriptLocator.subagentTranscripts(of: path) {
                    livePaths.append(sub)
                    let part = scanner.summary(of: sub)
                    summary.cost += part.cost
                    for (day, cost) in part.costByDay { summary.costByDay[day, default: 0] += cost }
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let modified = attrs?[.modificationDate] as? Date
                let entry = SessionSnapshot.Entry(
                    sessionId: session.sessionId, cwd: session.cwd, pid: session.pid,
                    name: session.name, title: summary.aiTitle ?? session.name,
                    branch: summary.gitBranch, turns: summary.turns, startedAt: session.startedAt,
                    lastActivity: modified.map { activityFormatter.string(from: $0) },
                    transcriptBytes: (attrs?[.size] as? NSNumber)?.intValue)
                infos.append(SessionInfo(session: session, summary: summary, entry: entry))
            }
            return Result(sessions: infos, codex: codex(hints: codexHints, released: codexReleased),
                          todayCost: includeToday ? today(live: livePaths) : nil,
                          missingTranscripts: missing(checkClosed))
        }

        /// Transcripts written today, from the last full walk of `projects/`.
        private var todayFiles: Set<String> = []
        private var todayFilesDay = ""
        private var lastFullWalk = Date.distantPast
        static let fullWalkInterval: TimeInterval = 300

        /// Cost of every response written today, across all transcripts touched today.
        /// Walking every project folder is done every five minutes; in between only
        /// the files already known to be from today (plus live sessions) are read.
        private func today(live: [String]) -> Double {
            let day = scanner.day(of: Date())
            if day != todayFilesDay || Date().timeIntervalSince(lastFullWalk) >= Self.fullWalkInterval {
                todayFiles = walkToday()
                todayFilesDay = day
                lastFullWalk = Date()
            }
            todayFiles.formUnion(live)
            return todayFiles.reduce(0) { $0 + (scanner.summary(of: $1).costByDay[day] ?? 0) }
        }

        private func walkToday() -> Set<String> {
            let fm = FileManager.default
            let midnight = Calendar.current.startOfDay(for: Date())
            func touchedToday(_ file: String) -> Bool {
                guard let modified = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date else { return false }
                return modified >= midnight
            }
            var files: Set<String> = []
            let projects = (try? fm.contentsOfDirectory(atPath: paths.projects.path)) ?? []
            for project in projects {
                let dir = paths.projects.appendingPathComponent(project).path
                let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                // A subagent writes while its parent session runs, so a parent
                // transcript untouched today has no subagent output today either.
                for name in names where name.hasSuffix(".jsonl") && touchedToday(dir + "/" + name) {
                    let path = dir + "/" + name
                    for file in [path] + ClaudeSessions.TranscriptLocator.subagentTranscripts(of: path)
                        where touchedToday(file) {
                        files.insert(file)
                    }
                }
            }
            return files
        }
    }
}
