import Foundation
import WhisperKit

/// Which language the transcriber should assume for an utterance.
enum LanguageSetting: Equatable {
    /// Detect the language per utterance. Costs a little latency and can guess
    /// wrong on short clips, so it is opt-in rather than the default.
    case auto
    /// Force a specific language, as a two-letter Whisper code.
    case code(String)

    static let `default` = LanguageSetting.code("en")

    /// Accepts `auto`, a Whisper language code ("es"), or an English language
    /// name ("spanish"), since both spellings are natural to reach for.
    init?(parsing raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.isEmpty { return nil }
        if normalized == "auto" {
            self = .auto
        } else if Constants.languageCodes.contains(normalized) {
            self = .code(normalized)
        } else if let code = Constants.languages[normalized] {
            self = .code(code)
        } else {
            return nil
        }
    }

    /// Language to pin decoding to; nil when detecting.
    var whisperCode: String? {
        switch self {
        case .auto: return nil
        case .code(let code): return code
        }
    }

    var detectLanguage: Bool { self == .auto }

    var displayName: String {
        switch self {
        case .auto: return "auto"
        case .code(let code): return code
        }
    }
}

extension TranscriptionModel {
    /// English-only Whisper builds declare exactly `["en"]`; multilingual ones
    /// declare `["multi"]`.
    var isEnglishOnly: Bool { languages == ["en"] }
}

/// An `.en` model cannot transcribe another language — it silently produces
/// English-looking gibberish rather than failing — so the mismatch is caught
/// before the daemon starts instead of at the first utterance.
enum LanguageCompatibility {
    static func problem(
        language: LanguageSetting,
        model: TranscriptionModel
    ) -> String? {
        guard model.isEnglishOnly else { return nil }

        let suggestion = ModelRegistry.shared
            .first { !$0.isEnglishOnly }
            .map { " use --model \($0.id)" } ?? ""

        switch language {
        case .code("en"):
            return nil
        case .code(let code):
            return "model \(model.id) is English-only and cannot transcribe \"\(code)\";"
                + (suggestion.isEmpty ? "" : suggestion)
        case .auto:
            return "model \(model.id) is English-only, so language detection has nothing to choose from;"
                + (suggestion.isEmpty ? "" : suggestion)
        }
    }
}
