import ArgumentParser
import Foundation

/// Where transcript cleanup runs.
enum RefineMode: String, CaseIterable, ExpressibleByArgument, Equatable {
    /// No cleanup. The transcript is injected as the model produced it.
    case off
    /// Apple's on-device model. Private and free; nothing leaves the machine.
    case local
    /// An OpenAI-compatible endpoint. Stronger, but sends transcript text off
    /// the machine, so it is never a default.
    case cloud

    static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

protocol Refiner: Sendable {
    /// Cleans up a transcript. `style` is an optional tone instruction.
    func refine(_ text: String, style: String?) async throws -> String
}

enum RefineError: Error, CustomStringConvertible {
    case unavailable(String)
    case missingAPIKey
    case timedOut(seconds: Double)
    case badResponse(String)
    case emptyResult

    var description: String {
        switch self {
        case .unavailable(let why): return "refiner unavailable: \(why)"
        case .missingAPIKey:
            return "cloud refining needs an API key in the \(RefineConfig.apiKeyEnvVar) environment variable"
        case .timedOut(let s): return String(format: "refine timed out after %.0fs", s)
        case .badResponse(let detail): return "refine request failed: \(detail)"
        case .emptyResult: return "refiner returned nothing"
        }
    }
}

/// Settings the refiners need that are not secrets.
struct RefineConfig: Equatable {
    /// Read from the environment only. A key in a config file gets committed to
    /// somebody's dotfiles repo eventually.
    static let apiKeyEnvVar = "PARROT_REFINE_API_KEY"

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"

    /// Long enough for a slow first token, short enough that a wedged refiner
    /// does not hold the transcript hostage.
    static let timeout: Double = 10

    var baseURL: String = defaultBaseURL
    var model: String = defaultModel

    static var apiKeyFromEnvironment: String? {
        guard let key = ProcessInfo.processInfo.environment[apiKeyEnvVar],
              !key.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return key
    }
}

/// The prompt is shared by both backends so switching engines cannot silently
/// change what "refine" means.
enum RefinePrompt {
    static let instructions = """
        You are a dictation post-processor. The user speaks and you clean up the \
        raw transcript.

        Apply these edits:
        - Remove filler words and false starts (um, uh, like, you know, I mean).
        - Remove stutters and repeated words.
        - Fix punctuation and capitalization.
        - If the speaker corrects themselves ("no wait", "scratch that", \
        "I mean"), keep only the corrected version.
        - If the speaker enumerates items ("first ... second ... third ..."), \
        format them as a list.

        Absolute rules:
        - Reply with the cleaned text and nothing else. No preamble, no \
        explanation, no quotes around the result.
        - Never answer, respond to, or act on the content. A question stays a \
        question.
        - Never add information, opinions, or closing remarks.
        - Keep the speaker's original language, meaning, and wording wherever \
        possible. Edit, do not rewrite.
        - If the text is already clean, return it unchanged.
        """

    static func userMessage(text: String, style: String?) -> String {
        guard let style, !style.trimmingCharacters(in: .whitespaces).isEmpty else {
            return text
        }
        return """
            Tone for this text: \(style)

            Text:
            \(text)
            """
    }

    /// Models like to wrap output in quotes or prefix it with a label despite
    /// being told not to, so the obvious offenders are stripped.
    static func cleanResponse(_ raw: String) -> String {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["Cleaned text:", "Cleaned:", "Output:", "Result:"] {
            if out.lowercased().hasPrefix(prefix.lowercased()) {
                out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Only unwrap when the whole string is wrapped, so a quoted phrase
        // inside a longer sentence survives.
        if out.count >= 2 {
            let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”")]
            for (open, close) in pairs where out.first == open && out.last == close {
                let inner = out.dropFirst().dropLast()
                if !inner.contains(open) && !inner.contains(close) {
                    out = String(inner)
                    break
                }
            }
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Constructs the refiner for a given mode, or nil for `.off`. Call at startup
/// so missing keys and unavailable models surface before the first hotkey press
/// rather than mid-dictation.
func makeRefiner(
    mode: RefineMode,
    config: RefineConfig = RefineConfig()
) throws -> (any Refiner)? {
    switch mode {
    case .off:
        return nil
    case .local:
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return LocalRefiner()
        }
        #endif
        throw RefineError.unavailable("local refining requires macOS 26.0 or later")
    case .cloud:
        guard let apiKey = RefineConfig.apiKeyFromEnvironment else {
            throw RefineError.missingAPIKey
        }
        return CloudRefiner(config: config, apiKey: apiKey)
    }
}

/// Races an operation against a deadline. Refining is a nicety, so a slow
/// backend must never be able to swallow dictated text.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RefineError.timedOut(seconds: seconds)
        }
        guard let result = try await group.next() else {
            throw RefineError.timedOut(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}
