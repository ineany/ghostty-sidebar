import XCTest
@testable import GhosttyBridge

final class PricingTests: XCTestCase {
    func testOpus55WithCacheSplit() {
        let usage = TokenUsage(json: [
            "input_tokens": 2, "output_tokens": 273, "cache_read_input_tokens": 28356,
            "cache_creation_input_tokens": 40067,
            "cache_creation": ["ephemeral_1h_input_tokens": 40067, "ephemeral_5m_input_tokens": 0],
        ])
        XCTAssertEqual(usage.cacheWrite1h, 40067)
        XCTAssertEqual(usage.cacheWrite5m, 0)
        let cost = Pricing.cost(usage, model: "claude-opus-5-5")!
        // 2*4 + 273*20 + 28356*0.20 + 40067*8 per million
        XCTAssertEqual(cost, (8 + 5460 + 5671.2 + 320536) / 1_000_000, accuracy: 1e-9)
    }

    func testOldTotalOnlyCountsAsFiveMinuteWrite() {
        let usage = TokenUsage(json: ["cache_creation_input_tokens": 1000])
        XCTAssertEqual(usage.cacheWrite5m, 1000)
        XCTAssertEqual(Pricing.cost(usage, model: "claude-sonnet-4-5")!, 1000 * 3.75 / 1_000_000, accuracy: 1e-12)
    }

    func testModelIdVariants() {
        XCTAssertEqual(Pricing.price(for: "claude-opus-4-5-20251101"), Pricing.price(for: "claude-opus-4-5"))
        XCTAssertEqual(Pricing.price(for: "claude-opus-5-5[1m]"), Pricing.price(for: "claude-opus-5-5"))
        XCTAssertEqual(Pricing.price(for: "anthropic.claude-sonnet-5-5"), Pricing.price(for: "claude-sonnet-5-5"))
        XCTAssertNil(Pricing.price(for: "<synthetic>"))
    }

    func testFastModeDoublesCost() {
        let normal = TokenUsage(output: 1_000_000)
        var fast = normal
        fast.fast = true
        XCTAssertEqual(Pricing.cost(fast, model: "claude-opus-5-5")!, 2 * Pricing.cost(normal, model: "claude-opus-5-5")!)
    }
}

final class TranscriptScannerTests: XCTestCase {
    var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).jsonl")
        try Data().write(to: file)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: file) }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func assistant(id: String, output: Int, time: String = "2026-11-15T03:00:00.000Z") -> String {
        """
        {"type":"assistant","timestamp":"\(time)","gitBranch":"main","message":{"id":"\(id)","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":\(output)}}}

        """
    }

    func testCountsEachResponseOnceAcrossBlocks() throws {
        try append(assistant(id: "m1", output: 1_000_000) + assistant(id: "m1", output: 1_000_000))
        let summary = TranscriptScanner().summary(of: file.path)
        XCTAssertEqual(summary.cost, 20, accuracy: 1e-9)
        XCTAssertEqual(summary.gitBranch, "main")
        XCTAssertEqual(summary.lastModel, "claude-opus-5-5")
    }

    func testReadsOnlyAppendedBytesAndWaitsForWholeLines() throws {
        let scanner = TranscriptScanner(timeZone: TimeZone(identifier: "Asia/Seoul")!)
        try append(assistant(id: "m1", output: 1_000_000))
        XCTAssertEqual(scanner.summary(of: file.path).cost, 20, accuracy: 1e-9)

        let line = assistant(id: "m2", output: 500_000)
        let cut = line.index(line.startIndex, offsetBy: 40)
        try append(String(line[..<cut]))
        XCTAssertEqual(scanner.summary(of: file.path).cost, 20, accuracy: 1e-9, "half a line is not parsed")
        try append(String(line[cut...]))
        try append(#"{"type":"ai-title","aiTitle":"제목","sessionId":"s"}"# + "\n")
        try append(#"{"type":"user","message":{"role":"user","content":"hi"}}"# + "\n")
        try append(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}"# + "\n")
        let summary = scanner.summary(of: file.path)
        XCTAssertEqual(summary.cost, 30, accuracy: 1e-9)
        XCTAssertEqual(summary.aiTitle, "제목")
        XCTAssertEqual(summary.turns, 1)
        // 03:00 UTC is noon in Seoul.
        XCTAssertEqual(summary.costByDay["2026-11-15"] ?? 0, 30, accuracy: 1e-9)
    }

    func testDayFollowsLocalTimeZone() throws {
        try append(assistant(id: "late", output: 1_000_000, time: "2026-11-15T16:00:00Z"))
        let summary = TranscriptScanner(timeZone: TimeZone(identifier: "Asia/Seoul")!).summary(of: file.path)
        XCTAssertNotNil(summary.costByDay["2026-11-16"])
    }
}

final class SessionMatcherTests: XCTestCase {
    private func tab(_ id: String, _ title: String, _ cwd: String?, _ status: SessionStatus = .idle) -> GhosttyTab {
        GhosttyTab(id: id, windowId: "w", index: 1, rawTitle: "✳ " + title, title: title,
                   status: status, isSelected: false, workingDirectory: cwd)
    }

    func testMatchesByTitleAndPrefersSameDirectory() {
        let tabs = [tab("t1", "같은 제목", "/b"), tab("t2", "같은 제목", "/a"), tab("t3", "셸", "/a", .unknown)]
        let sessions = [
            SessionMatcher.Candidate(sessionId: "sA", cwd: "/a", titles: ["같은 제목"]),
            SessionMatcher.Candidate(sessionId: "sB", cwd: "/b/", titles: ["같은 제목"]),
            SessionMatcher.Candidate(sessionId: "sC", cwd: "/a", titles: ["셸"]),
        ]
        XCTAssertEqual(SessionMatcher.match(tabs: tabs, sessions: sessions), ["t1": "sB", "t2": "sA"])
    }

    func testFallsBackToSessionNameAndTruncatedTitle() {
        let tabs = [tab("t1", "wallet-05", "/x"), tab("t2", "아주 긴 제목이 잘려서 보이는", "/y")]
        let sessions = [
            SessionMatcher.Candidate(sessionId: "s1", cwd: "/x", titles: ["wallet-05"]),
            SessionMatcher.Candidate(sessionId: "s2", cwd: "/y", titles: ["아주 긴 제목이 잘려서 보이는 경우의 전체 제목"]),
        ]
        XCTAssertEqual(SessionMatcher.match(tabs: tabs, sessions: sessions), ["t1": "s1", "t2": "s2"])
    }
}

final class SessionSnapshotTests: XCTestCase {
    func testReadsCcSessionFormatAndRoundTrips() throws {
        let json = """
        {"savedAt": "2026-11-10 17:09:30", "count": 1, "sessions": [
          {"sessionId": "248baf4f", "cwd": "/Users/me/wallet", "pid": 33677, "name": "wallet-11",
           "title": "Sentry MCP URL", "branch": "main", "turns": 540, "startedAt": 1793174831669,
           "lastActivity": "2026-11-10 17:09", "transcriptBytes": 13682262}]}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.sessions.first?.displayTitle, "Sentry MCP URL")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SessionListPaths(root: root)
        // The folder does not exist yet: save creates it.
        try SessionSnapshotStore.save(snapshot, to: paths.claude, history: paths.claudeHistory)
        try SessionSnapshotStore.save(snapshot, to: paths.claude, history: paths.claudeHistory)   // keeps a history copy
        try SessionSnapshotStore.save(snapshot, to: paths.claude, history: paths.claudeHistory)   // too soon for another
        XCTAssertEqual(SessionSnapshotStore.load(from: paths.claude), snapshot)
        let history = try FileManager.default.contentsOfDirectory(atPath: paths.claudeHistory.path)
        XCTAssertEqual(history.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codex.path))
    }

    func testLiveSessionsSkipDeadAndNonInteractive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ClaudePaths(root: root)
        try FileManager.default.createDirectory(at: paths.sessions, withIntermediateDirectories: true)
        let files = [
            "1.json": #"{"pid":1,"sessionId":"a","cwd":"/a","kind":"interactive","startedAt":2}"#,
            "2.json": #"{"pid":2,"sessionId":"b","cwd":"/b","kind":"interactive","startedAt":1}"#,
            "3.json": #"{"pid":3,"sessionId":"c","cwd":"/c","kind":"sdk"}"#,
            "4.json": #"{"pid":4,"sessionId":"d","cwd":"/d","kind":"interactive"}"#,
        ]
        for (name, body) in files {
            try Data(body.utf8).write(to: paths.sessions.appendingPathComponent(name))
        }
        let live = ClaudeSessions.live(paths: paths, isAlive: { $0 != 4 })
        XCTAssertEqual(live.map(\.sessionId), ["b", "a"])
    }
}

final class ClosedSessionStoreTests: XCTestCase {
    private func record(_ id: String, hoursAgo: Double, now: Date) -> ClosedSessionRecord {
        ClosedSessionRecord(kind: "claude", entry: .init(sessionId: id, cwd: "/w"),
                            closedAt: now.addingTimeInterval(-hoursAgo * 3600))
    }

    func testPruneKeepsAWeekNewestFirstAndOncePerSession() {
        let now = Date()
        let records = [
            record("old", hoursAgo: 24 * 8, now: now),
            record("a", hoursAgo: 5, now: now),
            record("b", hoursAgo: 1, now: now),
            record("a", hoursAgo: 2, now: now),   // closed again later: the newer one wins
        ]
        let kept = ClosedSessionStore.pruned(records, now: now)
        XCTAssertEqual(kept.map(\.entry.sessionId), ["b", "a"])
        XCTAssertEqual(kept.last!.closedAt.timeIntervalSince1970, now.addingTimeInterval(-7200).timeIntervalSince1970, accuracy: 1)
    }

    func testPruneCapsCount() {
        let now = Date()
        let records = (0..<50).map { record("s\($0)", hoursAgo: Double($0), now: now) }
        XCTAssertEqual(ClosedSessionStore.pruned(records, now: now).count, ClosedSessionStore.maxCount)
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("closed-\(UUID().uuidString)/closed.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_794_700_000)
        let records = [record("x", hoursAgo: 1, now: now)]
        try ClosedSessionStore.save(records, to: url)
        XCTAssertEqual(ClosedSessionStore.load(from: url), records)
    }

    func testCodexRolloutIdsAcrossDays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexSessions.Paths(root: root)
        let dir = paths.sessions.appendingPathComponent("2025/01/02")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "01a1b929-024b-71f2-88bb-4293479c58b0"
        try Data().write(to: dir.appendingPathComponent("rollout-2025-01-02T10-00-00-\(id).jsonl"))
        XCTAssertEqual(CodexSessions.sessionIdsWithRollouts(paths: paths), [id])
    }
}
