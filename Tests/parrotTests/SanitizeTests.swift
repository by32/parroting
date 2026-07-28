import XCTest

@testable import parrot

/// Whisper emits non-speech annotations as literal text; pasting them at the
/// cursor is never what the user wanted.
final class SanitizeTests: XCTestCase {
    private func sanitize(_ text: String) -> String {
        WhisperKitTranscriber.sanitize(text)
    }

    func testPlainSpeechIsUnchanged() {
        XCTAssertEqual(sanitize("hello world"), "hello world")
    }

    func testStripsBracketedAnnotations() {
        XCTAssertEqual(sanitize("[BLANK_AUDIO]"), "")
        XCTAssertEqual(sanitize("[MUSIC] hello"), "hello")
        XCTAssertEqual(sanitize("hello [Applause] world"), "hello world")
    }

    func testStripsParentheticalAnnotations() {
        XCTAssertEqual(sanitize("(silence)"), "")
        XCTAssertEqual(sanitize("hello (music playing) world"), "hello world")
    }

    func testStripsSpecialTokens() {
        XCTAssertEqual(sanitize("<|nospeech|>"), "")
        XCTAssertEqual(sanitize("<|startoftranscript|>hi<|endoftext|>"), "hi")
    }

    func testStripsAsteriskAnnotations() {
        XCTAssertEqual(sanitize("*background noise* hello"), "hello")
    }

    func testCollapsesWhitespaceLeftBehind() {
        XCTAssertEqual(sanitize("hello    world"), "hello world")
        XCTAssertEqual(sanitize("[MUSIC]   [NOISE]  hello"), "hello")
        XCTAssertEqual(sanitize("hello\n\tworld"), "hello world")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(sanitize("  hello world  "), "hello world")
        XCTAssertEqual(sanitize("\n hello \n"), "hello")
    }

    func testSilenceOnlyOutputBecomesEmpty() {
        XCTAssertEqual(sanitize("  [BLANK_AUDIO]  "), "")
        XCTAssertEqual(sanitize(""), "")
    }

    func testKeepsRealPunctuation() {
        XCTAssertEqual(
            sanitize("Let's go, then; it's 3:40 p.m. — right?"),
            "Let's go, then; it's 3:40 p.m. — right?"
        )
    }

    func testHandlesMultipleAnnotationsOfMixedKinds() {
        XCTAssertEqual(
            sanitize("[MUSIC] the (pause) quick *cough* brown <|token|> fox"),
            "the quick brown fox"
        )
    }
}
