import ArgumentParser
import Foundation
import ServiceManagement

/// Register parrot to start at login.
///
/// Two mechanisms, chosen by how parrot was installed (see `LoginItem`):
/// `SMAppService` when running from `Parrot.app`, a LaunchAgent plist when
/// running as a bare binary. Installing either one clears the other, since two
/// live daemons would both install a hotkey tap and race to inject text.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login entry."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login entry.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        switch (LoginItem.current(), uninstall) {
        case (.appBundle, false):
            try registerBundleLoginItem()
        case (.appBundle, true):
            try unregisterBundleLoginItem()
        case (.launchAgent, false):
            try writeAgent()
        case (.launchAgent, true):
            try removeAgent()
        }
    }

    // MARK: - app bundle (SMAppService)

    private func registerBundleLoginItem() throws {
        // A leftover LaunchAgent from a previous CLI install would start a
        // second daemon alongside this one.
        removeAgent(quiet: true)
        removeLegacyAgents()

        let service = SMAppService.mainApp
        do {
            try service.register()
        } catch {
            // Already-registered is not a failure worth aborting on; anything
            // else is.
            guard service.status == .enabled else {
                FileHandle.standardError.write(Data(
                    "couldn't register the login item: \(error.localizedDescription)\n".utf8
                ))
                throw ExitCode(1)
            }
        }

        print("✓ launch-at-login installed")
        print("  mechanism: SMAppService (\(Bundle.main.bundlePath))")

        if service.status == .requiresApproval {
            print()
            print("  macOS needs you to approve it:")
            print("    System Settings › General › Login Items › Allow in the Background")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func unregisterBundleLoginItem() throws {
        removeAgent(quiet: true)
        removeLegacyAgents()

        let service = SMAppService.mainApp
        guard service.status != .notRegistered else {
            print("nothing to remove (login item is not registered)")
            return
        }
        do {
            try service.unregister()
            print("✓ launch-at-login removed")
        } catch {
            FileHandle.standardError.write(Data(
                "couldn't unregister the login item: \(error.localizedDescription)\n".utf8
            ))
            throw ExitCode(1)
        }
    }

    // MARK: -

    static let label = "io.github.by32.parroting"

    /// Labels this fork used to ship under. Removed on install so a user who
    /// upgrades from an older build does not end up with two agents both
    /// holding the hotkey tap.
    private static let legacyLabels = ["com.digimata.parrot"]

    private var plistURL: URL { Self.plistURL(for: Self.label) }

    private static func plistURL(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()
        removeLegacyAgents()

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/parrot.out.log",
            "StandardErrorPath": "/tmp/parrot.err.log",
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   /tmp/parrot.out.log, /tmp/parrot.err.log")
    }

    private func removeAgent() throws {
        let removedLegacy = removeLegacyAgents()
        let removed = removeAgent(quiet: false)
        if !removed, !removedLegacy {
            print("nothing to remove (no agent at \(plistURL.path))")
        }
    }

    /// Boots out and deletes this fork's LaunchAgent. Returns whether it existed.
    @discardableResult
    private func removeAgent(quiet: Bool) -> Bool {
        let url = plistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        try? FileManager.default.removeItem(at: url)
        print(quiet ? "✓ removed the bare-binary LaunchAgent" : "✓ launch-at-login removed")
        return true
    }

    /// Boots out and deletes agents from earlier label schemes. Returns whether
    /// anything was actually removed.
    @discardableResult
    private func removeLegacyAgents() -> Bool {
        var removed = false
        for label in Self.legacyLabels {
            let url = Self.plistURL(for: label)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try? FileManager.default.removeItem(at: url)
            print("✓ removed legacy agent \(label)")
            removed = true
        }
        return removed
    }

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/parrot is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/parrot"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "parrot"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/parrot not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the parrot binary. install it to /usr/local/bin/parrot first.\n".utf8
        ))
        throw ExitCode(1)
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
