import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    /// WhisperKit trims prompt tokens to this many before decoding
    /// (`(maxTokenContext / 2) - 1`), keeping the *last* ones. Truncating here
    /// instead keeps the user's earliest dictionary lines, which is the more
    /// predictable rule, and lets us warn instead of silently dropping terms.
    static let maxPromptTokens = 111

    let modelID: String
    private let model: TranscriptionModel
    private var language: LanguageSetting
    private var biasTerms: [String]
    private var pipeline: WhisperKit?
    private var cachedPromptTokens: [Int]??

    init(
        model: TranscriptionModel,
        language: LanguageSetting = .default,
        biasTerms: [String] = []
    ) {
        self.modelID = model.id
        self.model = model
        self.language = language
        self.biasTerms = biasTerms
    }

    func setLanguage(_ language: LanguageSetting) {
        self.language = language
    }

    func setBiasTerms(_ terms: [String]) {
        biasTerms = terms
        cachedPromptTokens = nil
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(model: whisperKitID, verbose: false, prewarm: true, load: true)
        pipeline = try await WhisperKit(config)
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: decodeOptions(pipeline)
        )
        let raw = results.map(\.text).joined(separator: " ")
        return Self.sanitize(raw)
    }

    private func decodeOptions(_ pipeline: WhisperKit) -> DecodingOptions {
        DecodingOptions(
            language: language.whisperCode,
            detectLanguage: language.detectLanguage,
            promptTokens: promptTokens(pipeline)
        )
    }

    /// Encodes the bias terms once per term-set. Note that supplying prompt
    /// tokens makes WhisperKit skip its prefill cache, so an empty dictionary
    /// must yield nil rather than an empty array to avoid paying that cost for
    /// nothing.
    private func promptTokens(_ pipeline: WhisperKit) -> [Int]? {
        if let cachedPromptTokens { return cachedPromptTokens }

        let tokens = encodePromptTokens(pipeline)
        cachedPromptTokens = .some(tokens)
        return tokens
    }

    private func encodePromptTokens(_ pipeline: WhisperKit) -> [Int]? {
        guard !biasTerms.isEmpty, let tokenizer = pipeline.tokenizer else { return nil }

        // Leading space so the first term tokenizes like a mid-sentence word.
        let encoded = tokenizer.encode(text: " " + biasTerms.joined(separator: ", "))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        guard !encoded.isEmpty else { return nil }

        guard encoded.count > Self.maxPromptTokens else { return encoded }
        FileHandle.standardError.write(Data(
            """
            ! dictionary is \(encoded.count) tokens, over the \(Self.maxPromptTokens)-token \
            prompt limit — only the first \(Self.maxPromptTokens) will bias the model
            """.utf8
        ))
        FileHandle.standardError.write(Data("\n".utf8))
        return Array(encoded.prefix(Self.maxPromptTokens))
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
