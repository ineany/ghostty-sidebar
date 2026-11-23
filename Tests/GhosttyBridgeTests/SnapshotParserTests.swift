import XCTest
@testable import GhosttyBridge

final class SnapshotParserTests: XCTestCase {
    private let us = "\u{1F}"
    private let rs = "\u{1E}"

    private func record(_ fields: String...) -> String { fields.joined(separator: us) }

    func testParsesWindowsAndTabs() throws {
        let output = [
            record("W", "tab-group-885ed6440", "1"),
            record("T", "tab-883f4b000", "1", "false", "◐ Ghostty 작업 세션 재개", "/Users/me/wallet"),
            record("T", "tab-881356e00", "2", "true", "✳ 팀 Slack 스레드 요약", ""),
            record("W", "tab-group-886330e60", "2"),
            record("T", "tab-885b1e400", "1", "true", "문서 초안 검토 | 2026-메모", "/Users/me/2026-메모"),
        ].joined(separator: rs)

        let windows = try SnapshotParser.parse(output)

        XCTAssertEqual(windows.map(\.id), ["tab-group-885ed6440", "tab-group-886330e60"])
        XCTAssertEqual(windows.map(\.index), [1, 2])
        XCTAssertEqual(windows[0].tabs.count, 2)
        XCTAssertEqual(windows[0].tabs[0], GhosttyTab(
            id: "tab-883f4b000", windowId: "tab-group-885ed6440", index: 1,
            rawTitle: "◐ Ghostty 작업 세션 재개", title: "Ghostty 작업 세션 재개",
            status: .busy, isSelected: false, workingDirectory: "/Users/me/wallet"))
        XCTAssertEqual(windows[0].tabs[1].status, .idle)
        XCTAssertTrue(windows[0].tabs[1].isSelected)
        XCTAssertNil(windows[0].tabs[1].workingDirectory)
        let plain = windows[1].tabs[0]
        XCTAssertEqual(plain.windowId, "tab-group-886330e60")
        XCTAssertEqual(plain.status, .unknown)
        XCTAssertEqual(plain.title, "문서 초안 검토 | 2026-메모")
        XCTAssertEqual(plain.workingDirectory, "/Users/me/2026-메모")
    }

    func testTitleWithNewlineAndPipeSurvives() throws {
        let output = [
            record("W", "w1", "1"),
            record("T", "t1", "1", "true", "a | b\nc", "/tmp"),
        ].joined(separator: rs)
        let tab = try XCTUnwrap(SnapshotParser.parse(output).first?.tabs.first)
        XCTAssertEqual(tab.rawTitle, "a | b\nc")
        XCTAssertEqual(tab.workingDirectory, "/tmp")
    }

    func testEmptyOutputMeansNoWindows() throws {
        XCTAssertEqual(try SnapshotParser.parse(""), [])
    }

    func testWindowWithoutTabs() throws {
        let windows = try SnapshotParser.parse(record("W", "w1", "1"))
        XCTAssertEqual(windows, [GhosttyWindow(id: "w1", index: 1, tabs: [])])
    }

    func testEmptyTitleBecomesPlaceholder() throws {
        let output = [record("W", "w1", "1"), record("T", "t1", "1", "false", "", "")].joined(separator: rs)
        let tab = try XCTUnwrap(SnapshotParser.parse(output).first?.tabs.first)
        XCTAssertEqual(tab.rawTitle, "")
        XCTAssertEqual(tab.title, "(untitled)")
        XCTAssertNil(tab.workingDirectory)
    }

    func testTabBeforeWindowIsRejected() {
        let output = record("T", "t1", "1", "false", "x", "")
        XCTAssertThrowsError(try SnapshotParser.parse(output))
    }

    func testMalformedRecordsAreRejected() {
        XCTAssertThrowsError(try SnapshotParser.parse(record("W", "w1")))
        XCTAssertThrowsError(try SnapshotParser.parse(record("W", "w1", "x")))
        XCTAssertThrowsError(try SnapshotParser.parse(record("X", "w1", "1")))
        let shortTab = [record("W", "w1", "1"), record("T", "t1", "1", "true")].joined(separator: rs)
        XCTAssertThrowsError(try SnapshotParser.parse(shortTab))
    }
}
