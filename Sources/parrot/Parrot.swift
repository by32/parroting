import AppKit
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(
        inversion: .prefixedNo,
        help: "Show the on-screen recording overlay. (default: true)"
    )
    var overlay: Bool?

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(
        name: .long,
        help: "Push-to-talk key: \(Hotkey.allValueStrings.joined(separator: ", ")). (default: fn)"
    )
    var hotkey: Hotkey?

    @Option(
        name: .long,
        help: "Language to transcribe: a Whisper code like en/es/fr, or auto to detect. (default: en)"
    )
    var language: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Mic sensitivity: \(CaptureGate.Sensitivity.allValueStrings.joined(separator: ", "))."
                + " Use high to dictate while whispering. (default: normal)"
        )
    )
    var sensitivity: CaptureGate.Sensitivity?

    func run() throws {
        let config: Config
        do {
            config = try Config.load()
        } catch {
            FileHandle.standardError.write(Data("config error: \(error)\n".utf8))
            throw ExitCode(1)
        }

        let hotkey = self.hotkey ?? config.hotkey ?? .fn
        let showOverlay = self.overlay ?? config.overlay ?? true
        let sensitivity = self.sensitivity ?? config.sensitivity ?? .normal

        let language: LanguageSetting
        if let raw = self.language {
            guard let parsed = LanguageSetting(parsing: raw) else {
                FileHandle.standardError.write(Data("unknown language: \(raw)\n".utf8))
                FileHandle.standardError.write(Data(
                    "expected auto or a Whisper language code like en, es, fr\n".utf8
                ))
                throw ExitCode(1)
            }
            language = parsed
        } else {
            language = config.language ?? .default
        }

        if !skipDoctor {
            let checks = DoctorReport.run(hotkey: hotkey)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let chosenModel: TranscriptionModel
        if let id = model ?? config.model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.recommended() else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        if let problem = LanguageCompatibility.problem(language: language, model: chosenModel) {
            FileHandle.standardError.write(Data("\(problem)\n".utf8))
            throw ExitCode(1)
        }

        let dictionary: UserDictionary
        do {
            dictionary = try UserDictionary.load()
        } catch {
            FileHandle.standardError.write(Data("dictionary error: \(error)\n".utf8))
            throw ExitCode(1)
        }
        if !dictionary.isEmpty {
            FileHandle.standardError.write(Data(
                "dictionary: \(dictionary.terms.count) terms, \(dictionary.corrections.count) corrections\n".utf8
            ))
        }
        let processor = TranscriptProcessor(dictionary: dictionary)

        let transcriber = WhisperKitTranscriber(
            model: chosenModel,
            language: language,
            biasTerms: dictionary.terms
        )
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(hotkey: hotkey, debug: debugHotkey)
        let capture = AudioCapture()
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = showOverlay
            ? MainActor.assumeIsolated { RecordingOverlay() }
            : nil
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(modelID: chosenModel.id, hotkeyName: hotkey.displayName)
        }

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
                            let text = processor.process(raw)
                            let elapsed = Date().timeIntervalSince(started)
                            FileHandle.standardError.write(Data(
                                String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                            ))
                            await MainActor.run {
                                TextInjector.inject(text)
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

        let banner = "listening on \(hotkey.displayName) hold · model: \(chosenModel.id)"
            + " · lang: \(language.displayName) · ^C to quit\n"
        FileHandle.standardError.write(Data(banner.utf8))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    @Option(
        name: .long,
        help: "Push-to-talk key to check for: \(Hotkey.allValueStrings.joined(separator: ", ")). (default: fn)"
    )
    var hotkey: Hotkey?

    func run() throws {
        let config = (try? Config.load()) ?? .empty
        let checks = DoctorReport.run(hotkey: hotkey ?? config.hotkey ?? .fn)
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}
