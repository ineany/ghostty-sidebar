import Foundation
import GhosttyBridge
import os

/// Fake Ghostty used by `--mock`. Statuses cycle over time and `select` really changes
/// the selected tab (and brings its window to the front, like the real bridge).
final class MockGhosttyBridge: GhosttyControlling {
    private struct MockTab {
        let id: String
        let title: String
        let cwd: String?
        /// nil = never a Claude session (always `.unknown`).
        let period: Double?
        let phase: Double
    }

    private struct MockWindow {
        let id: String
        let tabs: [MockTab]
        var selected: Int
    }

    private struct State {
        /// Front-most first.
        var windows: [MockWindow]
    }

    private let start = Date()
    private let state: OSAllocatedUnfairLock<State>

    /// The mock folders are not on disk, so the project view gets fake git roots.
    static let projects = ProjectResolver(home: "/Users/me") { path in
        ["/Users/me/Project/work/shop/.git", "/Users/me/Project/github/ghostty-sidebar/.git"].contains(path)
    }

    init() {
        let home = "/Users/me/Project"
        let windows = [
            MockWindow(id: "win-a1", tabs: [
                MockTab(id: "tab-a11", title: "로그인 API에 요청 제한 추가", cwd: "\(home)/work/shop", period: 7, phase: 0),
                MockTab(id: "tab-a12", title: "주문 API 타임아웃 원인 분석", cwd: "\(home)/work/shop/apps/api", period: 5, phase: 2),
                MockTab(id: "tab-a13", title: "zsh", cwd: "\(home)/work/shop", period: nil, phase: 0),
                MockTab(id: "tab-a14", title: "사이드바 UI 구현과 스크린샷 검증", cwd: "\(home)/github/ghostty-sidebar", period: 9, phase: 4),
            ], selected: 0),
            MockWindow(id: "win-b2", tabs: [
                MockTab(id: "tab-b21", title: "주간 보고서 작성", cwd: "\(home)/work/reports", period: 11, phase: 1),
                MockTab(id: "tab-b22", title: "vim Models.swift", cwd: "\(home)/github/ghostty-sidebar/Sources", period: nil, phase: 0),
            ], selected: 1),
            MockWindow(id: "win-c3", tabs: [
                MockTab(id: "tab-c31", title: "DB 커넥션 풀 크기 조정 리뷰", cwd: "\(home)/work/shop/apps/worker", period: 6, phase: 3),
                MockTab(id: "tab-c32", title: "htop", cwd: nil, period: nil, phase: 0),
                MockTab(id: "tab-c33", title: "배포 계획서 초안", cwd: "\(home)/work/deploy", period: 8, phase: 5),
            ], selected: 0),
        ]
        state = OSAllocatedUnfairLock(initialState: State(windows: windows))
    }

    func snapshot() throws -> [GhosttyWindow] {
        // Simulate AppleScript latency so the off-main path is exercised.
        Thread.sleep(forTimeInterval: 0.08)
        let elapsed = Date().timeIntervalSince(start)
        let windows = state.withLock { $0.windows }
        return windows.enumerated().map { offset, window in
            GhosttyWindow(
                id: window.id,
                index: offset + 1,
                tabs: window.tabs.enumerated().map { tabOffset, tab in
                    let status = Self.status(of: tab, elapsed: elapsed)
                    let glyph: String
                    switch status {
                    case .busy: glyph = "◐ "
                    case .idle: glyph = "✳ "
                    case .unknown: glyph = ""
                    }
                    return GhosttyTab(
                        id: tab.id, windowId: window.id, index: tabOffset + 1,
                        rawTitle: glyph + tab.title, title: tab.title, status: status,
                        isSelected: tabOffset == window.selected, workingDirectory: tab.cwd)
                })
        }
    }

    func openTab(workingDirectory: String?, input: String?) throws {
        // Mock mode never touches the real Ghostty.
    }

    func select(tabId: String) throws {
        Thread.sleep(forTimeInterval: 0.05)
        let found = state.withLock { state -> Bool in
            for (w, window) in state.windows.enumerated() {
                guard let t = window.tabs.firstIndex(where: { $0.id == tabId }) else { continue }
                var moved = state.windows.remove(at: w)
                moved.selected = t
                state.windows.insert(moved, at: 0)
                return true
            }
            return false
        }
        if !found { throw GhosttyBridgeError.tabNotFound(tabId) }
    }

    private static func status(of tab: MockTab, elapsed: Double) -> SessionStatus {
        guard let period = tab.period else { return .unknown }
        return Int((elapsed + tab.phase) / period) % 2 == 0 ? .busy : .idle
    }
}
