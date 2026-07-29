import Foundation

/// Everything that happens to a transcript between the model and the cursor.
///
/// Kept separate from the daemon wiring so the whole chain is testable without a
/// microphone, and so stages can be swapped at runtime when settings change.
struct TranscriptProcessor {
    var dictionary: UserDictionary = .empty

    func process(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return dictionary.corrected(text)
    }
}
