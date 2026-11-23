import Foundation

/// Claude API list prices, used to show what a Claude Code session would cost at
/// API rates. With a Claude subscription nothing is billed per token; the number
/// is then an "API equivalent" for comparison.
///
/// Prices are USD per million tokens (first-party Claude API, cached 2026-11-03).
/// Cache writes cost 1.25x input for the 5-minute TTL and 2x for the 1-hour TTL.
public struct ModelPrice: Sendable, Equatable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double

    public init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * 0.1
    }

    public var cacheWrite5m: Double { input * 1.25 }
    public var cacheWrite1h: Double { input * 2 }
}

/// Token counts of one API response, as Claude Code writes them to the transcript.
public struct TokenUsage: Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var fast = false

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, fast: Bool = false) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.fast = fast
    }

    /// Reads the `message.usage` object of a transcript line.
    public init(json: [String: Any]) {
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        input = int(json["input_tokens"])
        output = int(json["output_tokens"])
        cacheRead = int(json["cache_read_input_tokens"])
        let created = int(json["cache_creation_input_tokens"])
        if let split = json["cache_creation"] as? [String: Any] {
            cacheWrite5m = int(split["ephemeral_5m_input_tokens"])
            cacheWrite1h = int(split["ephemeral_1h_input_tokens"])
            // Older transcripts have only the total.
            if cacheWrite5m + cacheWrite1h == 0 { cacheWrite5m = created }
        } else {
            cacheWrite5m = created
        }
        fast = (json["speed"] as? String) == "fast"
    }
}

public enum Pricing {
    /// Exact model ids. Older ids are matched after removing a date suffix.
    static let table: [String: ModelPrice] = [
        "claude-fable-5-2": ModelPrice(input: 8, output: 40, cacheRead: 0.20),
        "claude-mythos-5-2": ModelPrice(input: 8, output: 40, cacheRead: 0.20),
        "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1.0),
        "claude-mythos-5": ModelPrice(input: 10, output: 50, cacheRead: 1.0),
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": ModelPrice(input: 5, output: 25),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25),
        "claude-opus-4-5": ModelPrice(input: 5, output: 25),
        "claude-opus-4-1": ModelPrice(input: 15, output: 75),
        "claude-opus-4": ModelPrice(input: 15, output: 75),
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.10),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15),
        "claude-sonnet-4-5": ModelPrice(input: 3, output: 15),
        "claude-sonnet-4": ModelPrice(input: 3, output: 15),
        "claude-haiku-5-5": ModelPrice(input: 0.10, output: 0.50),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5),
    ]

    /// nil for unknown models (and Claude Code's "<synthetic>" placeholder).
    public static func price(for model: String) -> ModelPrice? {
        var id = model.lowercased()
        // Bedrock/Vertex style prefixes and suffixes: "anthropic.", "@2025...", "[1m]".
        if let dot = id.range(of: "anthropic.") { id = String(id[dot.upperBound...]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let exact = table[id] { return exact }
        // "claude-opus-4-5-20251101": drop the trailing date.
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            return table[parts.dropLast().joined(separator: "-")]
        }
        return nil
    }

    /// USD cost of one response. Fast mode is billed at twice the standard rate.
    public static func cost(_ usage: TokenUsage, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        let millions = (Double(usage.input) * p.input
            + Double(usage.output) * p.output
            + Double(usage.cacheRead) * p.cacheRead
            + Double(usage.cacheWrite5m) * p.cacheWrite5m
            + Double(usage.cacheWrite1h) * p.cacheWrite1h) / 1_000_000
        return usage.fast ? millions * 2 : millions
    }
}
