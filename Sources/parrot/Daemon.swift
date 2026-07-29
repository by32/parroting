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
    private let refiner: (any Refiner)?
    private let refineMode: RefineMode
    private var refineStyle: String?
    private var styles: Styles
    private var sensitivity: CaptureGate.Sensitivity
    private let hotkey: Hotkey
    private let languageDisplayName: String
    private let dumpWav: Bool

    private let capture: AudioCapture
    private let monitor: HotkeyMonitor
    private let overlay: RecordingOverlay?
    private let menuBar: MenuBarController

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
        modelID: String
    ) {
        self.transcriber = transcriber
        self.processor = processor
        self.refiner = refiner
        self.refineMode = refineMode
        self.refineStyle = refineStyle
        self.styles = styles
        self.sensitivity = sensitivity
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
        let processor = self.processor
        let refiner = self.refiner
        let styles = self.styles
        let refineStyle = self.refineStyle
        let sensitivity = self.sensitivity
        let dumpWav = self.dumpWav

        do {
            try monitor.start { event in
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
                    let verdict = CaptureGate.evaluate(
                        sampleCount: samples.count,
                        rms: rms,
                        sensitivity: sensitivity
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
                            var text = processor.process(raw)

                            if let refiner, !text.isEmpty {
                                let style = frontmostBundleID.flatMap { styles.style(for: $0) }
                                    ?? refineStyle
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
}
