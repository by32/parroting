import Foundation

/// Per-app refine styles from `~/.config/parrot/styles.toml`:
///
/// ```toml
/// "com.apple.mail" = "formal"
/// "com.apple.MobileSMS" = "casual"
/// "com.tinyspeck.slack.macgap" = "concise"
/// ```
///
/// When a transcript is about to be injected, the frontmost app's bundle
/// identifier is looked up here. A match overrides the global `refine-style`;
/// a miss falls back to whatever the CLI or config file specified.
struct Styles: Equatable {
    private var byBundleID: [String: String] = [:]

    static let empty = Styles()

    var isEmpty: Bool { byBundleID.isEmpty }
    var count: Int { byBundleID.count }

    static var defaultURL: URL {
        Config.directoryURL.appendingPathComponent("styles.toml")
    }

    static func load(from url: URL = defaultURL) throws -> Styles {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, source: url.path)
    }

    static func parse(_ text: String, source: String? = nil) throws -> Styles {
        var styles = Styles()

        for pair in try FlatTOML.parse(text, source: source) {
            guard !pair.key.isEmpty else {
                throw ConfigError.syntax(pair.at, "style key cannot be empty")
            }
            if styles.byBundleID[pair.key] != nil {
                throw ConfigError.syntax(pair.at, "duplicate style for \"\(pair.key)\"")
            }
            styles.byBundleID[pair.key] = try pair.stringValue()
        }

        return styles
    }

    /// Returns the style for a bundle id, or nil to let the caller fall back to
    /// the global default.
    func style(for bundleID: String) -> String? {
        byBundleID[bundleID]
    }

    /// All configured bundle IDs, for diagnostics.
    var bundleIDs: [String] { Array(byBundleID.keys) }
}
