import XCTest
@testable import GhosttyBridge

final class CodexSessionsTests: XCTestCase {
    typealias P = CodexSessions.Process
    typealias R = CodexSessions.Rollout

    func testNewSessionTakesFirstRolloutCreatedAfterStart() {
        let p = P(pid: 1, cwd: "/a", start: 1000, arguments: ["codex"])
        let rollouts = [
            R(path: "old", sessionId: "old", cwd: "/a", created: 500, modified: 900),
            R(path: "mine", sessionId: "mine", cwd: "/a", created: 1003, modified: 2000),
            R(path: "later", sessionId: "later", cwd: "/a", created: 1500, modified: 1600),
            R(path: "other", sessionId: "other", cwd: "/b", created: 1001, modified: 1100),
        ]
        let pairs = CodexSessions.match(processes: [p], rollouts: rollouts)
        XCTAssertEqual(pairs.map(\.1.sessionId), ["mine"])
    }

    func testTwoProcessesInOneFolderGetTheirOwnRollouts() {
        let first = P(pid: 1, cwd: "/a", start: 1000, arguments: ["codex"])
        let second = P(pid: 2, cwd: "/a", start: 1200, arguments: ["codex"])
        let rollouts = [
            R(path: "r2", sessionId: "s2", cwd: "/a", created: 1201, modified: 3000),
            R(path: "r1", sessionId: "s1", cwd: "/a", created: 1002, modified: 3000),
        ]
        let pairs = CodexSessions.match(processes: [second, first], rollouts: rollouts)
        let byPid = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.pid, $0.1.sessionId) })
        XCTAssertEqual(byPid, [1: "s1", 2: "s2"])
    }

    func testResumeByIdAndFromPicker() {
        let byId = P(pid: 1, cwd: "/a", start: 5000,
                     arguments: ["codex", "resume", "01A1CDE8-3BDB-7322-BF52-7A3FCBF7C849"])
        let picker = P(pid: 2, cwd: "/b", start: 5000, arguments: ["codex", "resume"])
        let rollouts = [
            R(path: "x", sessionId: "01a1cde8-3bdb-7322-bf52-7a3fcbf7c849", cwd: "/a", created: 100, modified: 5100),
            R(path: "y", sessionId: "stale", cwd: "/b", created: 100, modified: 4000),
            R(path: "z", sessionId: "picked", cwd: "/b", created: 200, modified: 5200),
        ]
        let pairs = CodexSessions.match(processes: [byId, picker], rollouts: rollouts)
        let byPid = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.pid, $0.1.sessionId) })
        XCTAssertEqual(byPid, [1: "01a1cde8-3bdb-7322-bf52-7a3fcbf7c849", 2: "picked"])
    }

    func testProcessWithoutRolloutIsSkipped() {
        let p = P(pid: 1, cwd: "/a", start: 1000, arguments: ["codex"])
        XCTAssertTrue(CodexSessions.match(processes: [p], rollouts: []).isEmpty)
    }

    func testCwdComparisonIgnoresUnicodeNormalization() {
        // macOS paths can come back decomposed (NFD) from one API and composed from another.
        let composed = "/Users/me/2026-메모"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        let p = P(pid: 1, cwd: composed, start: 1000, arguments: ["codex"])
        let r = R(path: "r", sessionId: "s", cwd: decomposed, created: 1001, modified: 1100)
        XCTAssertEqual(CodexSessions.match(processes: [p], rollouts: [r]).count, 1)
    }

    func testRolloutIndexReadsHeadersAndSkipsSubagents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexSessions.Paths(root: root)
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let dir = paths.sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = CodexSessions.RolloutIndex.stampFormatter.string(from: now)
        let main = #"{"type":"session_meta","payload":{"id":"main-id","cwd":"/w","source":"vscode"}}"#
        let sub = #"{"type":"session_meta","payload":{"id":"sub-id","cwd":"/w","source":{"subagent":{}}}}"#
        try Data((main + "\n{}\n").utf8).write(to: dir.appendingPathComponent("rollout-\(stamp)-main-id.jsonl"))
        try Data((sub + "\n").utf8).write(to: dir.appendingPathComponent("rollout-\(stamp)-sub-id.jsonl"))
        try Data((#"{"id":"main-id","thread_name":"첫 이름"}"# + "\n" + #"{"id":"main-id","thread_name":"바뀐 이름"}"# + "\n").utf8)
            .write(to: paths.index)

        let index = CodexSessions.RolloutIndex(paths: paths)
        let rollouts = index.rollouts(now: now)
        XCTAssertEqual(rollouts.map(\.sessionId), ["main-id"])
        XCTAssertEqual(rollouts.first?.created ?? 0, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(index.threadNames()["main-id"], "바뀐 이름")
    }
}

final class CodexHintTests: XCTestCase {
    typealias P = CodexSessions.Process
    typealias R = CodexSessions.Rollout

    func testHintIdentifiesResumedProcessBeforeItWritesAnything() {
        // Codex shows only "codex" as its arguments and the old rollout is untouched.
        let resumed = P(pid: 7, cwd: "/w", start: 10_001, arguments: ["codex"])
        let old = R(path: "old", sessionId: "s-old", cwd: "/w", created: 100, modified: 200)
        let hint = CodexSessions.Hint(sessionId: "s-old", cwd: "/w", time: 10_000)
        let pairs = CodexSessions.match(processes: [resumed], rollouts: [old], hints: [hint])
        XCTAssertEqual(pairs.map(\.1.sessionId), ["s-old"])
        XCTAssertEqual(pairs.first?.1.path, "old")
    }

    func testHintIgnoresProcessesStartedBeforeTheResume() {
        let earlier = P(pid: 1, cwd: "/w", start: 5_000, arguments: ["codex"])
        let hint = CodexSessions.Hint(sessionId: "s", cwd: "/w", time: 10_000)
        XCTAssertTrue(CodexSessions.match(processes: [earlier], rollouts: [], hints: [hint]).isEmpty)
    }

    func testHintWithoutKnownRolloutStillMatches() {
        let resumed = P(pid: 7, cwd: "/w", start: 10_002, arguments: ["codex"])
        let hint = CodexSessions.Hint(sessionId: "s-very-old", cwd: "/w", time: 10_000)
        let pairs = CodexSessions.match(processes: [resumed], rollouts: [], hints: [hint])
        XCTAssertEqual(pairs.first?.1.sessionId, "s-very-old")
        XCTAssertEqual(pairs.first?.1.path, "")
    }
}

final class CodexOwnershipTests: XCTestCase {
    typealias P = CodexSessions.Process
    typealias R = CodexSessions.Rollout

    // Two Codex processes in one folder; the older one has no rollout of its own.
    let other = P(pid: 1, cwd: "/w", start: 1_000, arguments: ["codex"])
    let closedTab = P(pid: 2, cwd: "/w", start: 2_000, arguments: ["codex"])
    let rollout = R(path: "r", sessionId: "s", cwd: "/w", created: 2_001, modified: 5_000)

    func testClosedSessionIsNotHandedToAnotherProcessInTheFolder() {
        let ownership = CodexSessions.Ownership()
        // Both alive: the tab started later owns the rollout created after its start.
        var (owners, released) = ownership.prepare(alive: [1, 2], now: 6_000)
        var pairs = CodexSessions.match(processes: [other, closedTab], rollouts: [rollout],
                                        owners: owners, released: released)
        XCTAssertEqual(pairs.map(\.0.pid), [2])
        ownership.record(pairs: pairs)

        // The tab closes. In the same poll the session must not move to process 1.
        (owners, released) = ownership.prepare(alive: [1], now: 7_000)
        XCTAssertEqual(released["s"], 7_000)
        pairs = CodexSessions.match(processes: [other], rollouts: [rollout], owners: owners, released: released)
        XCTAssertTrue(pairs.isEmpty)
        ownership.record(pairs: pairs)

        // Resumed in process 1 later: the rollout is written again, so it may move.
        let written = R(path: "r", sessionId: "s", cwd: "/w", created: 2_001, modified: 8_000)
        (owners, released) = ownership.prepare(alive: [1], now: 8_500)
        pairs = CodexSessions.match(processes: [other], rollouts: [written], owners: owners, released: released)
        XCTAssertEqual(pairs.first?.1.sessionId, "s")
    }

    func testLockFilesBlockGuessesAfterARestart() {
        // A fresh sidebar has no memory, but the closed session has no writer lock.
        let pairs = CodexSessions.match(processes: [other], rollouts: [rollout], locked: ["another-thread"])
        XCTAssertTrue(pairs.isEmpty)
        let oldRollout = R(path: "o", sessionId: "s", cwd: "/w", created: 500, modified: 5_000)
        let picker = CodexSessions.match(processes: [other], rollouts: [oldRollout], locked: ["another-thread"])
        XCTAssertTrue(picker.isEmpty, "picker-resume guess also needs the lock")
        XCTAssertTrue(pairs.isEmpty)
        let resumedThere = CodexSessions.match(processes: [other], rollouts: [rollout], locked: ["s"])
        XCTAssertEqual(resumedThere.first?.1.sessionId, "s")
    }

    func testOwnerKeepsItsSessionEvenIfAnotherRuleWouldPickDifferently() {
        let newer = R(path: "n", sessionId: "newer", cwd: "/w", created: 1_001, modified: 9_000)
        let pairs = CodexSessions.match(processes: [other], rollouts: [rollout, newer], owners: ["s": 1])
        XCTAssertEqual(pairs.first?.1.sessionId, "s")
    }

    func testLockedIdsFromFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexSessions.Paths(root: root)
        XCTAssertNil(CodexSessions.lockedSessionIds(paths: paths))
        try FileManager.default.createDirectory(at: paths.threadLocks, withIntermediateDirectories: true)
        for name in [".coordination.lock", "abc.lock"] {
            try Data().write(to: paths.threadLocks.appendingPathComponent(name))
        }
        XCTAssertEqual(CodexSessions.lockedSessionIds(paths: paths), ["abc"])
    }
}
