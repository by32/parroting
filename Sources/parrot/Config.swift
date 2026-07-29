import Foundation

/// Persistent settings read from `~/.config/parrot/config.toml`.
///
/// Every field is optional. `nil` means "not specified in the file", which lets
/// the caller layer CLI flags over file values over defaults without having to
/// guess whether a value was explicitly chosen.
struct Config: Equatable {
    var model: String?
    var hotkey: Hotkey?
    var language: LanguageSetting?
    var sensitivity: CaptureGate.Sensitivity?
    var overlay: Bool?

    static let empty = Config()

    /// Single source of truth for the schema, so the "unknown key" message
    /// cannot drift out of sync with what `parse` actually accepts.
    static let validKeys = ["model", "hotkey", "language", "sensitivity", "overlay"]

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parrot/config.toml")
    }

    /// Reads and parses the config file. A missing file yields an empty config;
    /// an unreadable or malformed one throws.
    static func load(from url: URL = defaultURL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, source: url.path)
    }

    /// Parses the flat subset of TOML the config schema needs: `key = value`
    /// lines where value is a quoted string or a bare `true`/`false`. Tables,
    /// arrays, and escape sequences are deliberately unsupported — the schema
    /// has three scalar keys, and rejecting the rest keeps a hand-rolled parser
    /// honest instead of pretending to be a TOML implementation.
    static func parse(_ text: String, source: String? = nil) throws -> Config {
        var config = Config()

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let at = Location(source: source, line: index + 1)

            if line.hasPrefix("[") {
                throw ConfigError.syntax(at, "tables are not supported; use a flat list of key = value")
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw ConfigError.syntax(at, "expected key = value")
            }

            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw ConfigError.syntax(at, "missing key before '='")
            }

            switch key {
            case "model":
                config.model = try string(value, key: key, at: at)
            case "hotkey":
                let name = try string(value, key: key, at: at)
                guard let parsed = Hotkey(rawValue: name) else {
                    throw ConfigError.syntax(
                        at,
                        "unknown hotkey \"\(name)\"; expected one of "
                            + Hotkey.allValueStrings.joined(separator: ", ")
                    )
                }
                config.hotkey = parsed
            case "language":
                let name = try string(value, key: key, at: at)
                guard let parsed = LanguageSetting(parsing: name) else {
                    throw ConfigError.syntax(
                        at,
                        "unknown language \"\(name)\"; expected auto or a Whisper language code like en, es, fr"
                    )
                }
                config.language = parsed
            case "sensitivity":
                let name = try string(value, key: key, at: at)
                guard let parsed = CaptureGate.Sensitivity(rawValue: name) else {
                    throw ConfigError.syntax(
                        at,
                        "unknown sensitivity \"\(name)\"; expected one of "
                            + CaptureGate.Sensitivity.allValueStrings.joined(separator: ", ")
                    )
                }
                config.sensitivity = parsed
            case "overlay":
                config.overlay = try bool(value, key: key, at: at)
            default:
                throw ConfigError.syntax(
                    at,
                    "unknown key \"\(key)\"; valid keys are " + Self.validKeys.joined(separator: ", ")
                )
            }
        }

        return config
    }

    /// Drops a trailing `#` comment without treating `#` inside a quoted value
    /// as a comment marker.
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var openQuote: Character?
        for ch in line {
            if let quote = openQuote {
                if ch == quote { openQuote = nil }
                out.append(ch)
            } else if ch == "\"" || ch == "'" {
                openQuote = ch
                out.append(ch)
            } else if ch == "#" {
                break
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func string(_ value: String, key: String, at: Location) throws -> String {
        guard let first = value.first, first == "\"" || first == "'" else {
            throw ConfigError.syntax(at, "\(key) must be quoted, e.g. \(key) = \"\(value)\"")
        }
        guard value.count >= 2, value.last == first else {
            throw ConfigError.syntax(at, "unterminated string for \(key)")
        }
        return String(value.dropFirst().dropLast())
    }

    private static func bool(_ value: String, key: String, at: Location) throws -> Bool {
        switch value {
        case "true": return true
        case "false": return false
        default:
            throw ConfigError.syntax(at, "\(key) must be true or false, got \"\(value)\"")
        }
    }
}

struct Location: Equatable {
    let source: String?
    let line: Int

    var description: String {
        guard let source else { return "line \(line)" }
        return "\(source):\(line)"
    }
}

enum ConfigError: Error, CustomStringConvertible, Equatable {
    case syntax(Location, String)

    var description: String {
        switch self {
        case .syntax(let at, let message):
            return "\(at.description): \(message)"
        }
    }
}
