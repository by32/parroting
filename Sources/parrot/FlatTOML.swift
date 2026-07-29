import Foundation

/// The flat subset of TOML parrot's config files use: `key = value` lines where
/// value is a quoted string or a bare `true`/`false`.
///
/// Deliberately not a TOML implementation. Tables, arrays, multi-line strings,
/// and escape sequences are rejected rather than half-supported, which keeps a
/// hand-rolled parser honest and avoids taking on a dependency for what is a
/// handful of scalar settings.
///
/// Pairs are returned in file order, and duplicate keys are preserved rather
/// than collapsed, so callers can decide whether last-wins or duplicate-is-an-
/// error is the right rule for their file.
enum FlatTOML {
    struct Pair: Equatable {
        let key: String
        let value: Value
        let at: Location
    }

    enum Value: Equatable {
        case string(String)
        case bool(Bool)
        /// An unquoted token that is not `true`/`false`. Never valid on its own,
        /// but carried through so the schema layer can report the mismatch in
        /// terms of the type that key actually expects.
        case bare(String)
    }

    static func parse(_ text: String, source: String? = nil) throws -> [Pair] {
        var pairs: [Pair] = []

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
            let rawValue = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw ConfigError.syntax(at, "missing key before '='")
            }

            pairs.append(Pair(key: unquoteKey(key), value: try value(rawValue, key: key, at: at), at: at))
        }

        return pairs
    }

    /// Keys may be quoted so they can contain spaces and dots, which snippet
    /// cues and app bundle ids both need.
    private static func unquoteKey(_ key: String) -> String {
        guard let first = key.first, first == "\"" || first == "'",
              key.count >= 2, key.last == first
        else { return key }
        return String(key.dropFirst().dropLast())
    }

    private static func value(_ raw: String, key: String, at: Location) throws -> Value {
        switch raw {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            guard let first = raw.first, first == "\"" || first == "'" else {
                return .bare(raw)
            }
            guard raw.count >= 2, raw.last == first else {
                throw ConfigError.syntax(at, "unterminated string for \(key)")
            }
            return .string(String(raw.dropFirst().dropLast()))
        }
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

}

extension FlatTOML.Pair {
    /// String value, or a syntax error phrased for a key that expects a string.
    func stringValue() throws -> String {
        switch value {
        case .string(let s):
            return s
        case .bare(let raw):
            throw ConfigError.syntax(at, "\(key) must be quoted, e.g. \(key) = \"\(raw)\"")
        case .bool(let b):
            throw ConfigError.syntax(at, "\(key) must be quoted, e.g. \(key) = \"\(b)\"")
        }
    }

    /// Bool value, or a syntax error phrased for a key that expects a bool.
    func boolValue() throws -> Bool {
        switch value {
        case .bool(let b):
            return b
        case .bare(let raw):
            throw ConfigError.syntax(at, "\(key) must be true or false, got \"\(raw)\"")
        case .string(let s):
            throw ConfigError.syntax(at, "\(key) must be true or false, got \"\(s)\"")
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
