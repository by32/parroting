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

    @Option(
        name: .long,
        help: """
        Post-transcription cleanup: \(RefineMode.allValueStrings.joined(separator: ", ")). \
        Local uses the on-device model; cloud sends text to an OpenAI-compatible endpoint. \
        (default: off)
        """
    )
    var refine: RefineMode?

    @Option(
        name: .long,
        help: "Tone instruction for the refiner, e.g. formal, casual, concise."
    )
    var refineStyle: String?

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

        let snippets: Snippets
        do {
            snippets = try Snippets.load()
        } catch {
            FileHandle.standardError.write(Data("snippets error: \(error)\n".utf8))
            throw ExitCode(1)
        }
        if !snippets.isEmpty {
            FileHandle.standardError.write(Data("snippets: \(snippets.count) cues\n".utf8))
        }

        let styles: Styles
        do {
            styles = try Styles.load()
        } catch {
            FileHandle.standardError.write(Data("styles error: \(error)\n".utf8))
            throw ExitCode(1)
        }
        if !styles.isEmpty {
            FileHandle.standardError.write(Data("styles: \(styles.count) apps\n".utf8))
        }

        let processor = TranscriptProcessor(snippets: snippets, dictionary: dictionary)

        let refineMode = self.refine ?? config.refine ?? .off
        let effectiveRefineStyle = self.refineStyle ?? config.refineStyle

        let refiner: (any Refiner)?
        do {
            refiner = try makeRefiner(mode: refineMode)
        } catch {
            FileHandle.standardError.write(Data("refine error: \(error)\n".utf8))
            throw ExitCode(1)
        }
        if refiner != nil {
            FileHandle.standardError.write(Data("refine: \(refineMode.rawValue)\n".utf8))
        }

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

        try MainActor.assumeIsolated {
            let daemon = Daemon(
                transcriber: transcriber,
                processor: processor,
                refiner: refiner,
                refineMode: refineMode,
                refineStyle: effectiveRefineStyle,
                styles: styles,
                sensitivity: sensitivity,
                hotkey: hotkey,
                languageDisplayName: language.displayName,
                showOverlay: showOverlay,
                debugHotkey: debugHotkey,
                dumpWav: dumpWav,
                modelID: chosenModel.id,
                config: config
            )
            try daemon.run()
        }
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
