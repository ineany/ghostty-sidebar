import Foundation
import GhosttyBridge

/// Runs blocking bridge calls on one serial background queue.
///
/// A dedicated serial queue (rather than the Swift concurrency pool) is used because
/// AppleScript calls block for a while, and serialising them keeps `snapshot()` and
/// `select(tabId:)` from racing inside Ghostty.
final class BridgeWorker: Sendable {
    private let queue = DispatchQueue(label: "ghostty-sidebar.bridge", qos: .userInitiated)

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// UI state. All mutation happens on the main actor; bridge calls go through `BridgeWorker`.
@MainActor
final class SidebarStore: ObservableObject {
    @Published private(set) var windows: [GhosttyWindow] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var ghosttyRunning = true
    @Published private(set) var hasLoaded = false

    static let pollInterval: Duration = .seconds(1)

    /// Maps a working directory to its project folder for the project view.
    let projects: ProjectResolver

    private let bridge: any GhosttyControlling
    private let worker = BridgeWorker()
    private var pollTask: Task<Void, Never>?
    private var isRefreshing = false
    /// Set when an explicit refresh is requested while one is already in flight.
    private var refreshQueued = false

    init(bridge: any GhosttyControlling, projects: ProjectResolver = ProjectResolver()) {
        self.bridge = bridge
        self.projects = projects
    }

    /// Window ids in the order they were first seen; see `StableOrder`.
    private var windowOrder: [String] = []

    /// Windows in the order they opened, for views that must not reshuffle
    /// when another window comes to the front.
    var windowsInOpenOrder: [GhosttyWindow] {
        let rank = Dictionary(uniqueKeysWithValues: windowOrder.enumerated().map { ($1, $0) })
        return windows.sorted { (rank[$0.id] ?? .max, $0.index) < (rank[$1.id] ?? .max, $1.index) }
    }

    var idleCount: Int { count(.idle) }
    var busyCount: Int { count(.busy) }

    private func count(_ status: SessionStatus) -> Int {
        windows.reduce(0) { $0 + $1.tabs.filter { $0.status == status }.count }
    }

    func start() {
        guard pollTask == nil else { return }
        refresh(force: true)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                // Timer tick: skipped if the previous snapshot is still running.
                self?.refresh(force: false)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Starts a snapshot off-main. `force` queues one more refresh if one is in flight;
    /// a plain timer tick just skips.
    func refresh(force: Bool) {
        guard !isRefreshing else {
            if force { refreshQueued = true }
            return
        }
        isRefreshing = true
        let bridge = self.bridge
        Task {
            let result: Result<[GhosttyWindow], any Error>
            do {
                result = .success(try await worker.run { try bridge.snapshot() })
            } catch {
                result = .failure(error)
            }
            apply(result)
            isRefreshing = false
            if refreshQueued {
                refreshQueued = false
                refresh(force: false)
            }
        }
    }

    /// Called on the main actor after a tab was selected successfully.
    var onSelected: ((GhosttyTab) -> Void)?

    func select(_ tab: GhosttyTab) {
        let bridge = self.bridge
        let tabId = tab.id
        Task {
            do {
                try await worker.run { try bridge.select(tabId: tabId) }
                onSelected?(tab)
            } catch {
                lastError = "탭 전환 실패: \(Self.describe(error))"
            }
            refresh(force: true)
        }
    }

    /// Opens a Ghostty tab; the next snapshot picks it up.
    func openTab(workingDirectory: String?, input: String?) {
        let bridge = self.bridge
        Task {
            do {
                try await worker.run { try bridge.openTab(workingDirectory: workingDirectory, input: input) }
            } catch {
                lastError = "새 탭 열기 실패: \(Self.describe(error))"
            }
            try? await Task.sleep(for: .milliseconds(400))
            refresh(force: true)
        }
    }

    /// Shows a message in the footer until the next successful refresh.
    func reportError(_ message: String) {
        lastError = message
    }

    private func apply(_ result: Result<[GhosttyWindow], any Error>) {
        hasLoaded = true
        lastRefresh = Date()
        switch result {
        case .success(let windows):
            windowOrder = StableOrder.update(known: windowOrder, current: windows.map(\.id))
            if self.windows != windows { self.windows = windows }
            ghosttyRunning = true
            lastError = nil
        case .failure(GhosttyBridgeError.ghosttyNotRunning):
            windows = []
            ghosttyRunning = false
            lastError = nil
        case .failure(let error):
            // Keep the last known list so a transient failure does not blank the sidebar.
            ghosttyRunning = true
            lastError = Self.describe(error)
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case GhosttyBridgeError.notImplemented:
            return "브리지 미구현 (not implemented)"
        case GhosttyBridgeError.ghosttyNotRunning:
            return "Ghostty가 실행 중이 아닙니다"
        case GhosttyBridgeError.tabNotFound:
            return "탭을 찾을 수 없습니다"
        case GhosttyBridgeError.scriptFailed(let message):
            return "AppleScript 오류: \(message)"
        default:
            return String(describing: error)
        }
    }
}
