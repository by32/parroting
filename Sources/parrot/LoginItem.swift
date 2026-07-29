import Foundation

/// How parrot should register itself to start at login.
///
/// The two distribution channels need different mechanisms, and picking the
/// wrong one is worse than doing nothing: a LaunchAgent that execs the binary
/// inside an .app bundle starts the daemon as a bare process, which means macOS
/// attributes its Accessibility grant to the executable's cdhash instead of the
/// bundle's stable signed identity — reintroducing exactly the
/// breaks-on-every-upgrade problem the bundle exists to solve.
enum LoginItemMechanism: Equatable {
    /// Running from inside `Parrot.app`. Register via `SMAppService`, so the
    /// item appears in System Settings › General › Login Items and inherits the
    /// bundle's code-signing identity.
    case appBundle

    /// Running as a bare binary (Homebrew formula, curl installer, dev build).
    /// A LaunchAgent plist is the only option, so use it.
    case launchAgent
}

enum LoginItem {
    /// Decide which mechanism applies. Split out from the side-effecting code so
    /// the detection rule is testable without an actual bundle on disk.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: `Bundle.main.bundleIdentifier`. `nil` for a bare
    ///     SwiftPM executable, since there is no Info.plist to read it from.
    ///   - bundlePath: `Bundle.main.bundlePath`. For a bare executable this is
    ///     the containing directory (e.g. `/usr/local/bin`), not a bundle.
    static func mechanism(
        bundleIdentifier: String?,
        bundlePath: String
    ) -> LoginItemMechanism {
        // Both conditions matter. A bare binary has no identifier, but a
        // directory that merely ends in ".app" is not a bundle either, and
        // SMAppService would fail confusingly rather than fall back.
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              bundlePath.hasSuffix(".app")
        else {
            return .launchAgent
        }
        return .appBundle
    }

    static func current() -> LoginItemMechanism {
        mechanism(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundlePath: Bundle.main.bundlePath
        )
    }
}
