import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let modelID: String
    private let idleTitle: String

    private var refineItems: [NSMenuItem] = []
    private var sensitivityItems: [NSMenuItem] = []
    private var refineStyleItems: [NSMenuItem] = []

    /// Called with (key, value) when the user picks a setting from the menu.
    var onSettingChange: ((String, String) -> Void)?

    init(modelID: String, hotkeyName: String = "fn") {
        self.modelID = modelID
        self.idleTitle = "idle · hold \(hotkeyName) to dictate"
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: idleTitle, action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        menu.addItem(.separator())

        menu.addItem(buildSettingsMenu())

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton()
    }

    func setRecording(_ recording: Bool) {
        stateLabel.title = recording ? "● recording" : idleTitle
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    /// Updates checkmarks to reflect the current settings. Called by the daemon
    /// when settings change (from the file watcher or from the menu itself).
    func updateSettings(
        refineMode: RefineMode,
        sensitivity: CaptureGate.Sensitivity,
        refineStyle: String?
    ) {
        markSelected(in: refineItems, matching: refineMode.rawValue)
        markSelected(in: sensitivityItems, matching: sensitivity.rawValue)
        markSelected(in: refineStyleItems, matching: refineStyle ?? "")
    }

    // MARK: - Settings menu

    private func buildSettingsMenu() -> NSMenuItem {
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(buildRefineSubmenu())
        submenu.addItem(buildSensitivitySubmenu())
        submenu.addItem(buildRefineStyleSubmenu())

        settingsItem.submenu = submenu
        return settingsItem
    }

    private func buildRefineSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Refine", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        for mode in RefineMode.allCases {
            let item = NSMenuItem(
                title: mode.rawValue.capitalized,
                action: #selector(refineModeSelected),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            sub.addItem(item)
            refineItems.append(item)
        }

        parent.submenu = sub
        return parent
    }

    private func buildSensitivitySubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        for level in CaptureGate.Sensitivity.allCases {
            let item = NSMenuItem(
                title: level.rawValue.capitalized,
                action: #selector(sensitivitySelected),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level.rawValue
            sub.addItem(item)
            sensitivityItems.append(item)
        }

        parent.submenu = sub
        return parent
    }

    private func buildRefineStyleSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Refine Style", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let presets: [(label: String, value: String)] = [
            ("None", ""),
            ("Formal", "formal"),
            ("Casual", "casual"),
            ("Concise", "concise"),
            ("Confident", "confident"),
        ]

        for preset in presets {
            let item = NSMenuItem(
                title: preset.label,
                action: #selector(refineStyleSelected),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.value
            sub.addItem(item)
            refineStyleItems.append(item)
        }

        parent.submenu = sub
        return parent
    }

    private func markSelected(in items: [NSMenuItem], matching value: String) {
        for item in items {
            let itemValue = item.representedObject as? String ?? ""
            item.state = itemValue == value ? .on : .off
        }
    }

    @objc private func refineModeSelected(_ sender: NSMenuItem) {
        onSettingChange?("refine", sender.representedObject as? String ?? "off")
    }

    @objc private func sensitivitySelected(_ sender: NSMenuItem) {
        onSettingChange?("sensitivity", sender.representedObject as? String ?? "normal")
    }

    @objc private func refineStyleSelected(_ sender: NSMenuItem) {
        onSettingChange?("refine-style", sender.representedObject as? String ?? "")
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
