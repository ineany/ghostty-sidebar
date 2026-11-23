import AppKit
import Carbon

/// Moves and resizes Ghostty windows through System Events.
///
/// Ghostty's own AppleScript dictionary has no window bounds, so this goes through
/// the Accessibility layer that System Events exposes. The responsible process
/// (the terminal that launched the sidebar, or the app bundle) needs Automation
/// permission for System Events and Accessibility permission.
public final class GhosttyWindowArranger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ghostty-sidebar.arranger", qos: .userInitiated)
    /// Confined to `queue`.
    private var compiled: NSAppleScript?

    public init() {}

    /// Moves every Ghostty window that overlaps `sidebar` beside it.
    /// Rectangles are in Accessibility coordinates (see `ArrangePlanner`).
    /// Returns the number of windows that were moved.
    @discardableResult
    public func arrange(avoiding sidebar: CGRect, within screen: CGRect) throws -> Int {
        guard AppleScriptGhosttyBridge.isGhosttyRunning() else { throw GhosttyBridgeError.ghosttyNotRunning }
        return try queue.sync {
            let frames = try Self.parseFrames(try run(handler: "ghostty_frames", arguments: []))
            let plan = ArrangePlanner.plan(windows: frames, sidebar: sidebar, screen: screen)
            for (i, target) in plan.sorted(by: { $0.key < $1.key }) {
                let args = [i + 1, Int(target.minX), Int(target.minY), Int(target.width), Int(target.height)]
                    .map(String.init)
                _ = try run(handler: "ghostty_set_frame", arguments: args)
            }
            return plan.count
        }
    }

    /// Parses "x,y,w,h;x,y,w,h;..." produced by `ghostty_frames`.
    static func parseFrames(_ output: String) throws -> [CGRect] {
        guard !output.isEmpty else { return [] }
        return try output.split(separator: ";").map { item in
            let n = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 4 else { throw GhosttyBridgeError.scriptFailed("bad frame: \(item)") }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
    }

    /// Must run on `queue`.
    private func run(handler: String, arguments: [String]) throws -> String {
        let script = try loadScript()
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, arg) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: arg), at: i + 1)
        }
        event.setDescriptor(list, forKeyword: AEKeyword(keyDirectObject))
        var errorInfo: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            if number == -1743 || number == -1719 || number == -25211 {
                throw GhosttyBridgeError.scriptFailed(
                    "창 정렬 권한 없음 (\(number)): 시스템 설정 > 개인정보 보호 및 보안에서 손쉬운 사용과 자동화를 허용하세요")
            }
            throw GhosttyBridgeError.scriptFailed("\(message) (\(number))")
        }
        return result.stringValue ?? ""
    }

    private func loadScript() throws -> NSAppleScript {
        if let compiled { return compiled }
        guard let script = NSAppleScript(source: Self.source) else {
            throw GhosttyBridgeError.scriptFailed("could not create arranger script")
        }
        var errorInfo: NSDictionary?
        guard script.compileAndReturnError(&errorInfo) else {
            throw GhosttyBridgeError.scriptFailed("arranger compile failed: \(errorInfo ?? [:])")
        }
        compiled = script
        return script
    }

    // Window order from System Events is front-to-back. Both handlers address
    // windows by that index; the two calls run back to back on one queue.
    private static let source = """
    on ghostty_frames()
        with timeout of 5 seconds
            tell application "System Events"
                if not (exists process "Ghostty") then return ""
                tell process "Ghostty"
                    set out to {}
                    repeat with w in (every window)
                        set p to position of w
                        set s to size of w
                        set end of out to ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
                    end repeat
                end tell
            end tell
        end timeout
        set AppleScript's text item delimiters to ";"
        set joined to out as text
        set AppleScript's text item delimiters to ""
        return joined
    end ghostty_frames

    on ghostty_set_frame(idx, x, y, w, h)
        with timeout of 5 seconds
            tell application "System Events"
                tell process "Ghostty"
                    set win to window (idx as integer)
                    set position of win to {x as integer, y as integer}
                    set size of win to {w as integer, h as integer}
                end tell
            end tell
        end timeout
        return "OK"
    end ghostty_set_frame
    """
}
