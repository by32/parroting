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
    var refine: RefineMode?
    var refineStyle: String?

    static let empty = Config()

    /// Single source of truth for the schema, so the "unknown key" message
    /// cannot drift out of sync with what `parse` actually accepts.
    static let validKeys = [
        "model", "hotkey", "language", "sensitivity", "overlay",
        "refine", "refine-style",
    ]

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parrot")
    }

    static var defaultURL: URL {
        directoryURL.appendingPathComponent("config.toml")
    }

    /// Reads and parses the config file. A missing file yields an empty config;
    /// an unreadable or malformed one throws.
    static func load(from url: URL = defaultURL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, source: url.path)
    }

    /// Later assignments of the same key win, matching how a hand-edited file
    /// reads top to bottom.
    static func parse(_ text: String, source: String? = nil) throws -> Config {
        var config = Config()

        for pair in try FlatTOML.parse(text, source: source) {
            switch pair.key {
            case "model":
                config.model = try pair.stringValue()

            case "hotkey":
                let name = try pair.stringValue()
                guard let parsed = Hotkey(rawValue: name) else {
                    throw ConfigError.syntax(
                        pair.at,
                        "unknown hotkey \"\(name)\"; expected one of "
                            + Hotkey.allValueStrings.joined(separator: ", ")
                    )
                }
                config.hotkey = parsed

            case "language":
                let name = try pair.stringValue()
                guard let parsed = LanguageSetting(parsing: name) else {
                    throw ConfigError.syntax(
                        pair.at,
                        "unknown language \"\(name)\"; expected auto or a Whisper language code like en, es, fr"
                    )
                }
                config.language = parsed

            case "sensitivity":
                let name = try pair.stringValue()
                guard let parsed = CaptureGate.Sensitivity(rawValue: name) else {
                    throw ConfigError.syntax(
                        pair.at,
                        "unknown sensitivity \"\(name)\"; expected one of "
                            + CaptureGate.Sensitivity.allValueStrings.joined(separator: ", ")
                    )
                }
                config.sensitivity = parsed

            case "overlay":
                config.overlay = try pair.boolValue()

            case "refine":
                let name = try pair.stringValue()
                guard let parsed = RefineMode(rawValue: name) else {
                    throw ConfigError.syntax(
                        pair.at,
                        "unknown refine mode \"\(name)\"; expected one of "
                            + RefineMode.allValueStrings.joined(separator: ", ")
                    )
                }
                config.refine = parsed

            case "refine-style":
                config.refineStyle = try pair.stringValue()

            default:
                throw ConfigError.syntax(
                    pair.at,
                    "unknown key \"\(pair.key)\"; valid keys are "
                        + Self.validKeys.joined(separator: ", ")
                )
            }
        }

        return config
    }
}
