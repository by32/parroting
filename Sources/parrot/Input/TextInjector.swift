import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    static let chunkSize = 20

    /// Inject the given text at the current cursor location.
    static func inject(_ text: String) {
        for var chunk in chunks(text) {
            postChunk(&chunk)
        }
    }

    /// Splits text into UTF-16 runs small enough for one keyboard event, since
    /// the underlying API has a per-event character limit (~20 chars).
    ///
    /// Chunk boundaries never fall between the halves of a surrogate pair —
    /// splitting one would post two lone surrogates and corrupt the character
    /// (astral-plane text: emoji, some CJK extensions).
    static func chunks(_ text: String, size: Int = chunkSize) -> [[UniChar]] {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty, size > 0 else { return [] }

        var result: [[UniChar]] = []
        var index = 0
        while index < utf16.count {
            var end = min(index + size, utf16.count)
            if end < utf16.count, isHighSurrogate(utf16[end - 1]) {
                end -= 1
            }
            if end <= index {
                end = min(index + 2, utf16.count)
            }
            result.append(Array(utf16[index..<end]))
            index = end
        }
        return result
    }

    private static func isHighSurrogate(_ unit: UniChar) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
