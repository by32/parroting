import AppKit
import ArgumentParser
import Foundation

/// Owns the dictation lifecycle: hotkey monitoring, audio capture, transcription,
/// post-processing, and text injection. Extracted from `Run` so the daemon's
/// runtime state is a thing that can be inspected and updated (settings dropdown,
/// config-file watcher) rather than a 200-line closure inside a CLI command.
@MainActor
final class Daemon {
    private let transcriber: WhisperKitTranscriber
    private var processor: TranscriptProcessor
    private var refiner: (any Refiner)?
    private var refineMode: RefineMode
    private var refineStyle: String?
    private var styles: Styles
    private var sensitivity: CaptureGate.Sensitivity
    private var currentConfig: Config
    private let hotkey: Hotkey
    private let languageDisplayName: String
    private let dumpWav: Bool

    private let capture: AudioCapture
    private let monitor: HotkeyMonitor
    private let overlay: RecordingOverlay?
    private let menuBar: MenuBarController
    private var watcher: ConfigWatcher?

    init(
        transcriber: WhisperKitTranscriber,
        processor: TranscriptProcessor,
        refiner: (any Refiner)?,
        refineMode: RefineMode,
        refineStyle: String?,
        styles: Styles,
        sensitivity: CaptureGate.Sensitivity,
        hotkey: Hotkey,
        languageDisplayName: String,
        showOverlay: Bool,
        debugHotkey: Bool,
        dumpWav: Bool,
        modelID: String,
        config: Config
    ) {
        self.transcriber = transcriber
        self.processor = processor
        self.refiner = refiner
        self.refineMode = refineMode
        self.refineStyle = refineStyle
        self.styles = styles
        self.sensitivity = sensitivity
        self.currentConfig = config
        self.hotkey = hotkey
        self.languageDisplayName = languageDisplayName
        self.dumpWav = dumpWav

        self.capture = AudioCapture()
        self.monitor = HotkeyMonitor(hotkey: hotkey, debug: debugHotkey)
        self.overlay = showOverlay ? RecordingOverlay() : nil
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        self.menuBar = MenuBarController(modelID: modelID, hotkeyName: hotkey.displayName)
    }

    func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let capture = self.capture
        let monitor = self.monitor
        let overlay = self.overlay
        let menuBar = self.menuBar
        let transcriber = self.transcriber
        let dumpWav = self.dumpWav

        menuBar.onSettingChange = { [weak self] key, value in
            guard let self else { return }
            do {
                try self.updateConfig(key: key, value: value)
            } catch {
                FileHandle.standardError.write(Data("config write failed: \(error)\n".utf8))
            }
        }
        menuBar.updateSettings(
            refineMode: refineMode,
            sensitivity: sensitivity,
            refineStyle: refineStyle
        )

        do {
            try monitor.start { [weak self] event in
                guard let self else { return }
                switch event {
                case .pressed:
                    do {
                        try capture.start()
                        FileHandle.standardError.write(Data("● recording\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.recording)
                            menuBar.setRecording(true)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                    }
                case .released:
                    let samples = capture.stop()
                    let frontmostBundleID = MainActor.assumeIsolated {
                        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    }
                    MainActor.assumeIsolated {
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    FileHandle.standardError.write(Data(
                        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                    ))
                    if dumpWav, !samples.isEmpty {
                        let path = "/tmp/parrot-last.wav"
                        do {
                            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                            FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                        } catch {
                            FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                        }
                    }
                    let currentSensitivity = MainActor.assumeIsolated { self.sensitivity }
                    let verdict = CaptureGate.evaluate(
                        sampleCount: samples.count,
                        rms: rms,
                        sensitivity: currentSensitivity
                    )
                    if let reason = verdict.rejectionReason {
                        FileHandle.standardError.write(Data("  skipped · \(reason)\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setRecording(false)
                        }
                        return
                    }
                    Task {
                        let started = Date()
                        do {
                            let raw = try await transcriber.transcribe(samples)
                            let snapshot = await MainActor.run {
                                DaemonSnapshot(
                                    text: self.processor.process(raw),
                                    refiner: self.refiner,
                                    styles: self.styles,
                                    refineStyle: self.refineStyle
                                )
                            }
                            var text = snapshot.text

                            if let refiner = snapshot.refiner, !text.isEmpty {
                                let style = frontmostBundleID.flatMap { snapshot.styles.style(for: $0) }
                                    ?? snapshot.refineStyle
                                do {
                                    let refined = try await refiner.refine(text, style: style)
                                    if !refined.isEmpty { text = refined }
                                } catch {
                                    FileHandle.standardError.write(Data(
                                        "refine failed: \(error) — using raw transcript\n".utf8
                                    ))
                                }
                            }

                            let elapsed = Date().timeIntervalSince(started)
                            FileHandle.standardError.write(Data(
                                String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                            ))
                            let final = text
                            await MainActor.run {
                                TextInjector.inject(final)
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        } catch {
                            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                            await MainActor.run {
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        watcher = ConfigWatcher(url: Config.defaultURL) { [weak self] config in
            MainActor.assumeIsolated {
                self?.applyConfig(config)
            }
        }
        watcher?.start()

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        let banner = "listening on \(hotkey.displayName) hold"
            + " · model: \(transcriber.modelID)"
            + " · lang: \(languageDisplayName)"
            + " · refine: \(refineMode.rawValue) · ^C to quit\n"
        FileHandle.standardError.write(Data(banner.utf8))
        app.run()
    }

    // MARK: - Live config updates

    /// Applies a reloaded config to the running daemon. Only settings that can
    /// change without a restart are updated; the rest are logged as requiring a
    /// restart.
    func applyConfig(_ config: Config) {
        if config == currentConfig { return }

        if let newSensitivity = config.sensitivity, newSensitivity != sensitivity {
            sensitivity = newSensitivity
            log("sensitivity -> \(newSensitivity.rawValue)")
        }

        let newRefineMode = config.refine ?? .off
        if newRefineMode != refineMode {
            refineMode = newRefineMode
            do {
                refiner = try makeRefiner(mode: newRefineMode)
                log("refine -> \(newRefineMode.rawValue)")
            } catch {
                refiner = nil
                log("refine -> failed: \(error)")
            }
        }

        let newRefineStyle = config.refineStyle
        if newRefineStyle != refineStyle {
            refineStyle = newRefineStyle
            log("refine-style -> \(newRefineStyle ?? "(none)")")
        }

        do {
            let newStyles = try Styles.load()
            if newStyles != styles {
                styles = newStyles
                log("styles reloaded (\(newStyles.count) apps)")
            }
        } catch {
            log("styles reload failed: \(error)")
        }

        if let newHotkey = config.hotkey, newHotkey != hotkey {
            log("hotkey change requires restart")
        }
        if config.model != nil, config.model != currentConfig.model {
            log("model change requires restart")
        }
        if config.language != nil, config.language != currentConfig.language {
            log("language change requires restart")
        }

        currentConfig = config
        menuBar.updateSettings(
            refineMode: refineMode,
            sensitivity: sensitivity,
            refineStyle: refineStyle
        )
    }

    /// Updates a single config key, applies it live, and writes the config back
    /// to disk. Called by the menu bar settings dropdown.
    func updateConfig(key: String, value: String) throws {
        var config = currentConfig
        switch key {
        case "sensitivity":
            guard let parsed = CaptureGate.Sensitivity(rawValue: value) else { return }
            config.sensitivity = parsed
        case "refine":
            guard let parsed = RefineMode(rawValue: value) else { return }
            config.refine = parsed
        case "refine-style":
            config.refineStyle = value.isEmpty ? nil : value
        default:
            return
        }
        currentConfig = config
        applyConfig(config)
        try config.write()
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("config: \(message)\n".utf8))
    }
}

/// Immutable snapshot of the mutable daemon state, captured on the main actor
/// so the transcription Task can read it without further main-actor hops.
private struct DaemonSnapshot: Sendable {
    let text: String
    let refiner: (any Refiner)?
    let styles: Styles
    let refineStyle: String?
}
