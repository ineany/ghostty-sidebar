// Command-line probe that exercises GhosttyBridge against the running Ghostty.
import Foundation
import GhosttyBridge

let usage = """
usage: ghostty-probe list            print windows and tabs with snapshot latency
       ghostty-probe select <tabId>  select a tab and bring Ghostty to the front
       ghostty-probe bench [n]       time n snapshots (default 10)
       ghostty-probe open <dir> [text]  open a tab in <dir>, typing text (\\n = Return)
       ghostty-probe sessions        live Claude sessions with cost and matched tab
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ghostty-probe: \(message)\n".utf8))
    exit(code)
}

func millis(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

func timedSnapshot(_ bridge: GhosttyControlling) throws -> ([GhosttyWindow], Double) {
    let start = DispatchTime.now()
    let windows = try bridge.snapshot()
    return (windows, millis(since: start))
}

let args = Array(CommandLine.arguments.dropFirst())
let bridge = makeDefaultBridge()

do {
    switch args.first {
    case "list" where args.count == 1:
        let (windows, coldMs) = try timedSnapshot(bridge)
        let (_, warmMs) = try timedSnapshot(bridge)
        for window in windows {
            print("window \(window.index)  id=\(window.id)  tabs=\(window.tabs.count)")
            for tab in window.tabs {
                let marker = tab.isSelected ? "*" : " "
                let status = tab.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
                print("  \(marker) \(tab.index)  \(tab.id)  \(status)  \(tab.title)  [\(tab.workingDirectory ?? "-")]")
            }
        }
        let tabCount = windows.reduce(0) { $0 + $1.tabs.count }
        print(String(format: "%d windows, %d tabs; snapshot %.1f ms (first, includes compile), %.1f ms (second)",
                     windows.count, tabCount, coldMs, warmMs))
    case "select" where args.count == 2:
        let start = DispatchTime.now()
        try bridge.select(tabId: args[1])
        print(String(format: "selected %@ in %.1f ms", args[1], millis(since: start)))
    case "bench" where args.count <= 2:
        let n = args.count == 2 ? (Int(args[1]) ?? 0) : 10
        guard n > 0 else { fail("bench count must be a positive integer", code: 64) }
        _ = try timedSnapshot(bridge) // warm-up and compile
        var samples: [Double] = []
        for _ in 0..<n { samples.append(try timedSnapshot(bridge).1) }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(n)
        print(String(format: "%d snapshots: min %.1f  median %.1f  max %.1f  mean %.1f ms",
                     n, samples.first!, samples[n / 2], samples.last!, mean))
    case "open" where args.count == 2 || args.count == 3:
        let text = args.count == 3 ? args[2].replacingOccurrences(of: "\\n", with: "\n") : nil
        try bridge.openTab(workingDirectory: args[1], input: text)
        print("opened a tab in \(args[1])")
    case "sessions" where args.count == 1:
        let windows = try bridge.snapshot()
        let locator = ClaudeSessions.TranscriptLocator()
        let scanner = TranscriptScanner()
        let start = DispatchTime.now()
        var candidates: [SessionMatcher.Candidate] = []
        var costs: [String: Double] = [:]
        for session in ClaudeSessions.live() {
            guard let path = locator.transcript(for: session.sessionId, cwd: session.cwd) else { continue }
            var summary = scanner.summary(of: path)
            for sub in ClaudeSessions.TranscriptLocator.subagentTranscripts(of: path) {
                summary.cost += scanner.summary(of: sub).cost
            }
            costs[session.sessionId] = summary.cost
            candidates.append(.init(sessionId: session.sessionId, cwd: session.cwd,
                                    titles: [summary.aiTitle, session.name].compactMap { $0 }))
            print(String(format: "%@  $%8.2f  %@  %@", String(session.sessionId.prefix(8)), summary.cost,
                         summary.aiTitle ?? "-", session.cwd))
        }
        print(String(format: "scanned in %.0f ms", millis(since: start)))
        let codexStart = DispatchTime.now()
        let codex = CodexSessions.live(index: CodexSessions.RolloutIndex())
        for session in codex {
            print("codex \(session.pid)  \(session.sessionId.prefix(8))  \(session.threadName ?? "-")  \(session.cwd)")
        }
        print(String(format: "codex: %d sessions in %.0f ms", codex.count, millis(since: codexStart)))
        let tabs = windows.flatMap(\.tabs)
        let matched = SessionMatcher.match(tabs: tabs, sessions: candidates)
        for tab in tabs {
            let sid = matched[tab.id].map { String($0.prefix(8)) } ?? "-"
            print("  \(tab.id)  \(sid)  \(tab.title)")
        }
    default:
        fail("invalid arguments\n\(usage)", code: 64)
    }
} catch let error as GhosttyBridgeError {
    fail(error.description)
} catch {
    fail("\(error)")
}
