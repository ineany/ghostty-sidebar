import AppKit
import Carbon

/// `GhosttyControlling` backed by Ghostty's AppleScript dictionary.
///
/// One `NSAppleScript` holding both handlers is compiled lazily and then reused.
/// `NSAppleScript` is not thread-safe, so every compile and execute runs on a
/// private serial queue. Callers may use any thread but should avoid the main
/// thread, because each call blocks until Ghostty answers.
public final class AppleScriptGhosttyBridge: GhosttyControlling, @unchecked Sendable {
    public static let bundleIdentifier = "com.mitchellh.ghostty"

    private let queue = DispatchQueue(label: "ghostty-sidebar.bridge.applescript", qos: .userInitiated)
    /// Confined to `queue`.
    private var compiled: NSAppleScript?

    public init() {}

    // MARK: GhosttyControlling

    public func snapshot() throws -> [GhosttyWindow] {
        try ensureRunning()
        let output = try call(handler: "ghostty_snapshot", arguments: [])
        if output == Self.notRunningResult { throw GhosttyBridgeError.ghosttyNotRunning }
        return try SnapshotParser.parse(output)
    }

    public func select(tabId: String) throws {
        try ensureRunning()
        let output = try call(handler: "ghostty_select", arguments: [tabId])
        switch output {
        case "OK": return
        case Self.notFoundResult: throw GhosttyBridgeError.tabNotFound(tabId)
        case Self.notRunningResult: throw GhosttyBridgeError.ghosttyNotRunning
        default: throw GhosttyBridgeError.scriptFailed("unexpected select result: \(output)")
        }
    }

    public func openTab(workingDirectory: String?, input: String?) throws {
        try ensureRunning()
        let output = try call(handler: "ghostty_open_tab",
                              arguments: [workingDirectory ?? "", input ?? ""])
        switch output {
        case "OK": return
        case Self.notRunningResult: throw GhosttyBridgeError.ghosttyNotRunning
        default: throw GhosttyBridgeError.scriptFailed("unexpected open result: \(output)")
        }
    }

    // MARK: Internals

    public static func isGhosttyRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Checked before any scripting, because sending events with `tell application`
    /// would launch Ghostty. The script repeats the check to cover a quit in between.
    private func ensureRunning() throws {
        guard Self.isGhosttyRunning() else { throw GhosttyBridgeError.ghosttyNotRunning }
    }

    private func call(handler: String, arguments: [String]) throws -> String {
        try queue.sync {
            let script = try loadScript()
            let event = Self.subroutineEvent(handler: handler, arguments: arguments)
            var errorInfo: NSDictionary?
            let result = script.executeAppleEvent(event, error: &errorInfo)
            if let errorInfo { throw Self.mapError(errorInfo) }
            return result.stringValue ?? ""
        }
    }

    /// Must run on `queue`.
    private func loadScript() throws -> NSAppleScript {
        if let compiled { return compiled }
        guard let script = NSAppleScript(source: Self.source) else {
            throw GhosttyBridgeError.scriptFailed("could not create NSAppleScript")
        }
        var errorInfo: NSDictionary?
        if !script.compileAndReturnError(&errorInfo) {
            throw Self.mapError(errorInfo ?? [:])
        }
        compiled = script
        return script
    }

    private static func subroutineEvent(handler: String, arguments: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        // AppleScript matches handler names in lower case.
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()),
                            forKeyword: AEKeyword(keyASSubroutineName))
        let params = NSAppleEventDescriptor.list()
        for (offset, argument) in arguments.enumerated() {
            params.insert(NSAppleEventDescriptor(string: argument), at: offset + 1)
        }
        event.setParam(params, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    static func mapError(_ info: NSDictionary) -> GhosttyBridgeError {
        let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "unknown error"
        switch number {
        case -600, -609: // procNotFound, connectionInvalid
            return .ghosttyNotRunning
        case -1743: // errAEEventNotPermitted
            return .scriptFailed("not allowed to control Ghostty (-1743). Allow it in System Settings > Privacy & Security > Automation.")
        case -1744: // errAEEventWouldRequireUserConsent
            return .scriptFailed("controlling Ghostty needs user consent (-1744); the Automation prompt was not answered.")
        case -1712: // errAETimeout
            return .scriptFailed("Ghostty did not answer in time (-1712)")
        default:
            return .scriptFailed("\(message) (\(number))")
        }
    }

    static let notRunningResult = "NOT_RUNNING"
    static let notFoundResult = "NOT_FOUND"

    /// Both handlers in one script. `ghostty_snapshot` returns the format parsed by
    /// `SnapshotParser`. Ghostty answers each Apple event slowly (several ms), so the
    /// snapshot reads every property for all windows at once: six events in total,
    /// independent of the number of tabs.
    static let source = """
    on ghostty_snapshot()
        if application id "com.mitchellh.ghostty" is not running then return "NOT_RUNNING"
        set US to character id 31
        set RS to character id 30
        set out to {}
        with timeout of 5 seconds
            tell application id "com.mitchellh.ghostty"
                -- Each line below is one Apple event that returns a list per window.
                set wids to id of every window
                set tids to id of every tab of every window
                set tidx to index of every tab of every window
                set tsel to selected of every tab of every window
                set tnames to name of every tab of every window
                set cwds to {}
                try
                    set cwds to working directory of focused terminal of every tab of every window
                end try
                set bulkCwd to ((count of cwds) is (count of wids))
                repeat with wi from 1 to count of wids
                    set wid to item wi of wids
                    set end of out to "W" & US & wid & US & (wi as text)
                    set wtids to item wi of tids
                    set wcwds to {}
                    if bulkCwd then set wcwds to item wi of cwds
                    repeat with ti from 1 to count of wtids
                        set tid to item ti of wtids
                        set cwd to ""
                        if (count of wcwds) is (count of wtids) then
                            set cwd to item ti of wcwds
                        else
                            try
                                set cwd to working directory of focused terminal of tab id tid of window id wid
                            end try
                        end if
                        if cwd is missing value then set cwd to ""
                        set nm to item ti of item wi of tnames
                        if nm is missing value then set nm to ""
                        set end of out to "T" & US & tid & US & ((item ti of item wi of tidx) as text) & US & ((item ti of item wi of tsel) as text) & US & nm & US & cwd
                    end repeat
                end repeat
            end tell
        end timeout
        set saved to AppleScript's text item delimiters
        set AppleScript's text item delimiters to RS
        set s to out as text
        set AppleScript's text item delimiters to saved
        return s
    end ghostty_snapshot

    on ghostty_select(tid)
        if application id "com.mitchellh.ghostty" is not running then return "NOT_RUNNING"
        with timeout of 5 seconds
            tell application id "com.mitchellh.ghostty"
                -- Fetch the ids first: "repeat with x in (id of every window)" would
                -- iterate an unresolved reference that Ghostty cannot evaluate.
                set wids to id of every window
                repeat with wid in wids
                    set w to window id (contents of wid)
                    if (count of (every tab of w whose id is tid)) > 0 then
                        select tab (tab id tid of w)
                        activate window w
                        activate
                        return "OK"
                    end if
                end repeat
            end tell
        end timeout
        return "NOT_FOUND"
    end ghostty_select

    on ghostty_open_tab(cwd, inputText)
        if application id "com.mitchellh.ghostty" is not running then return "NOT_RUNNING"
        with timeout of 5 seconds
            tell application id "com.mitchellh.ghostty"
                set cfg to new surface configuration
                if cwd is not "" then set initial working directory of cfg to cwd
                if inputText is not "" then set initial input of cfg to inputText
                -- "new tab" reports -1708 even when the tab opens, so errors are ignored.
                try
                    if (count of windows) > 0 then
                        new tab in front window with configuration cfg
                    else
                        new window with configuration cfg
                    end if
                end try
                activate
            end tell
        end timeout
        return "OK"
    end ghostty_open_tab
    """
}
