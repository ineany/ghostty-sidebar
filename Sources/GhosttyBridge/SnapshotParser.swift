import Foundation

/// Converts the delimited string produced by the snapshot AppleScript into models.
///
/// Format: records separated by RS (U+001E), fields separated by US (U+001F).
/// - Window record: `W US <window id> US <1-based index>`
/// - Tab record:    `T US <tab id> US <index> US <true|false> US <name> US <working directory>`
///
/// Tab records belong to the most recent window record before them.
public enum SnapshotParser {
    public static let recordSeparator: Character = "\u{1E}"
    public static let unitSeparator: Character = "\u{1F}"

    public static func parse(_ output: String) throws -> [GhosttyWindow] {
        var windows: [GhosttyWindow] = []
        var current: (id: String, index: Int)?
        var tabs: [GhosttyTab] = []

        func flush() {
            if let current {
                windows.append(GhosttyWindow(id: current.id, index: current.index, tabs: tabs))
            }
            tabs = []
        }

        for record in output.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            let fields = record.split(separator: unitSeparator, omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "W":
                guard fields.count == 3, !fields[1].isEmpty, let index = Int(fields[2]) else {
                    throw malformed(record)
                }
                flush()
                current = (fields[1], index)
            case "T":
                guard let window = current else { throw malformed(record) }
                guard fields.count >= 6, !fields[1].isEmpty, let index = Int(fields[2]) else {
                    throw malformed(record)
                }
                // The name sits between the fixed leading fields and the trailing directory,
                // so a stray separator inside a title cannot shift the other fields.
                let rawTitle = fields[4..<(fields.count - 1)].joined(separator: String(unitSeparator))
                let cwd = fields[fields.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = TitleParser.parse(rawTitle)
                tabs.append(GhosttyTab(
                    id: fields[1],
                    windowId: window.id,
                    index: index,
                    rawTitle: rawTitle,
                    title: parsed.title,
                    status: parsed.status,
                    isSelected: fields[3] == "true",
                    workingDirectory: cwd.isEmpty ? nil : cwd
                ))
            default:
                throw malformed(record)
            }
        }
        flush()
        return windows
    }

    private static func malformed(_ record: Substring) -> GhosttyBridgeError {
        let printable = record
            .replacingOccurrences(of: String(unitSeparator), with: "|")
        return .scriptFailed("malformed snapshot record: \(printable.prefix(200))")
    }
}
