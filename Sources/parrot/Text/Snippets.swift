import Foundation

/// Voice shortcuts from `~/.config/parrot/snippets.toml`:
///
/// ```toml
/// "my calendar link" = "https://cal.example/me"
/// "standup intro" = "Morning! Quick update:"
/// ```
///
/// Say the cue and the expansion is injected instead of the transcript.
///
/// Only a whole utterance can trigger a snippet. Matching cues mid-sentence
/// would make it impossible to ever say the phrase literally, and a dictated
/// sentence that happens to contain "my calendar link" should stay as typed.
struct Snippets: Equatable {
    private var byNormalizedCue: [String: String] = [:]

    static let empty = Snippets()

    var isEmpty: Bool { byNormalizedCue.isEmpty }
    var count: Int { byNormalizedCue.count }

    static var defaultURL: URL {
        Config.directoryURL.appendingPathComponent("snippets.toml")
    }

    static func load(from url: URL = defaultURL) throws -> Snippets {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, source: url.path)
    }

    static func parse(_ text: String, source: String? = nil) throws -> Snippets {
        var snippets = Snippets()

        for pair in try FlatTOML.parse(text, source: source) {
            let cue = normalize(pair.key)
            guard !cue.isEmpty else {
                throw ConfigError.syntax(pair.at, "snippet cue cannot be empty")
            }
            if snippets.byNormalizedCue[cue] != nil {
                throw ConfigError.syntax(pair.at, "duplicate snippet cue \"\(pair.key)\"")
            }
            snippets.byNormalizedCue[cue] = try pair.stringValue()
        }

        return snippets
    }

    /// The expansion for an utterance, or nil to leave the transcript alone.
    func expansion(for transcript: String) -> String? {
        byNormalizedCue[Self.normalize(transcript)]
    }

    /// Cues are spoken, so matching ignores the things speech-to-text decides on
    /// its own: capitalization, surrounding whitespace, trailing sentence
    /// punctuation, and internal spacing.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let unpunctuated = lowered.trimmingCharacters(
            in: CharacterSet(charactersIn: ".!?,;: \t")
        )
        return unpunctuated.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
