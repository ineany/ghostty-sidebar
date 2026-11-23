import Foundation

/// Derives a display title and a `SessionStatus` from a raw Ghostty tab title.
///
/// Claude Code writes its state as the first character of the terminal title:
/// "✳" when idle (waiting for the user) and a spinner glyph while busy.
public enum TitleParser {
    public static let untitled = "(untitled)"

    /// Glyph Claude Code shows when idle.
    static let idleScalars: Set<Unicode.Scalar> = ["\u{2733}"] // ✳

    /// Spinner glyphs Claude Code shows while busy (besides the Braille range).
    static let busyScalars: Set<Unicode.Scalar> = [
        "\u{25D0}", "\u{25D3}", "\u{25D1}", "\u{25D2}", // ◐ ◓ ◑ ◒
        "\u{00B7}", // ·
        "\u{2722}", // ✢
        "\u{2736}", // ✶
        "\u{273B}", // ✻
        "\u{273D}", // ✽
    ]

    static let brailleRange: ClosedRange<UInt32> = 0x2800...0x28FF

    public static func status(of scalar: Unicode.Scalar) -> SessionStatus {
        if idleScalars.contains(scalar) { return .idle }
        if busyScalars.contains(scalar) || brailleRange.contains(scalar.value) { return .busy }
        return .unknown
    }

    public static func parse(_ raw: String) -> (title: String, status: SessionStatus) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let scalar = first.unicodeScalars.first else {
            return (untitled, .unknown)
        }
        let status = status(of: scalar)
        guard status != .unknown else {
            return (trimmed, .unknown)
        }
        // Dropping the whole Character also drops a trailing variation selector (e.g. "✳️").
        let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest.isEmpty ? trimmed : rest, status)
    }
}
