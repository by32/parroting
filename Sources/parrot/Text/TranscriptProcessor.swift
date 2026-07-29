import Foundation

/// Everything that happens to a transcript between the model and the cursor.
///
/// Kept separate from the daemon wiring so the whole chain is testable without a
/// microphone, and so stages can be swapped at runtime when settings change.
struct TranscriptProcessor {
    var snippets: Snippets = .empty
    var dictionary: UserDictionary = .empty

    func process(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // A snippet is a canned expansion, so it replaces the utterance outright
        // rather than being run through corrections meant for dictated prose.
        if let expansion = snippets.expansion(for: text) {
            return expansion
        }

        return dictionary.corrected(text)
    }
}
