import Foundation

/// Personal vocabulary from `~/.config/parrot/dictionary.txt`.
///
/// Two mechanisms, because neither alone is enough:
///
/// - **Bias terms** (bare lines) are fed to Whisper as prompt tokens, which
///   makes the model *more likely* to produce that spelling. Probabilistic, and
///   the only lever that can affect decoding itself.
/// - **Corrections** (`heard -> wanted` lines) rewrite the transcript after the
///   fact. Deterministic, and the fallback for words Whisper stubbornly refuses
///   to spell the way you want.
///
/// The file is a line list rather than TOML because that is what it is; a
/// key/value schema would add quoting ceremony for no gain.
struct UserDictionary: Equatable {
    struct Correction: Equatable {
        let from: String
        let to: String
    }

    var terms: [String] = []
    var corrections: [Correction] = []

    static let empty = UserDictionary()

    var isEmpty: Bool { terms.isEmpty && corrections.isEmpty }

    static var defaultURL: URL {
        Config.directoryURL.appendingPathComponent("dictionary.txt")
    }

    static func load(from url: URL = defaultURL) throws -> UserDictionary {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, source: url.path)
    }

    static func parse(_ text: String, source: String? = nil) throws -> UserDictionary {
        var result = UserDictionary()

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let at = Location(source: source, line: index + 1)

            guard let arrow = line.range(of: "->") else {
                result.terms.append(line)
                continue
            }

            let from = String(line[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let to = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else {
                throw ConfigError.syntax(at, "correction is missing the text to replace, before '->'")
            }
            guard !to.isEmpty else {
                throw ConfigError.syntax(at, "correction is missing the replacement text, after '->'")
            }
            result.corrections.append(Correction(from: from, to: to))
        }

        return result
    }

    /// Comma-separated term list, which is the shape Whisper prompts expect.
    var promptText: String {
        terms.joined(separator: ", ")
    }

    /// Applies corrections in file order, matching case-insensitively but only
    /// on whole words, so a correction for "netes" cannot fire inside
    /// "kubernetes".
    func corrected(_ text: String) -> String {
        var out = text
        for correction in corrections {
            let pattern = #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: correction.from) + #"(?!\w)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: correction.to)
            )
        }
        return out
    }
}
