import XCTest

@testable import parrot

final class SnippetsTests: XCTestCase {
    private func snippets(_ toml: String) throws -> Snippets {
        try Snippets.parse(toml)
    }

    func testEmptyFileYieldsNoSnippets() throws {
        XCTAssertTrue(try snippets("").isEmpty)
        XCTAssertTrue(try snippets("# only a comment").isEmpty)
    }

    func testExpandsAWholeUtterance() throws {
        let s = try snippets(#""my calendar link" = "https://cal.example/me""#)
        XCTAssertEqual(s.expansion(for: "my calendar link"), "https://cal.example/me")
    }

    func testCountsCues() throws {
        let s = try snippets(
            """
            "one" = "1"
            "two" = "2"
            """
        )
        XCTAssertEqual(s.count, 2)
    }

    func testNonMatchingUtteranceIsLeftAlone() throws {
        let s = try snippets(#""calendar" = "link""#)
        XCTAssertNil(s.expansion(for: "something else entirely"))
    }

    /// Speech-to-text decides capitalization and final punctuation on its own,
    /// so a cue has to match regardless of what Whisper chose.
    func testMatchingIgnoresCaseAndTrailingPunctuation() throws {
        let s = try snippets(#""my calendar link" = "URL""#)
        XCTAssertEqual(s.expansion(for: "My calendar link"), "URL")
        XCTAssertEqual(s.expansion(for: "my calendar link."), "URL")
        XCTAssertEqual(s.expansion(for: "My Calendar Link!"), "URL")
        XCTAssertEqual(s.expansion(for: "  my calendar link  "), "URL")
        XCTAssertEqual(s.expansion(for: "my calendar link?"), "URL")
    }

    func testMatchingCollapsesInternalWhitespace() throws {
        let s = try snippets(#""my calendar link" = "URL""#)
        XCTAssertEqual(s.expansion(for: "my  calendar\tlink"), "URL")
    }

    /// Partial matches must not fire, otherwise the cue phrase could never be
    /// dictated literally as part of a sentence.
    func testDoesNotExpandCuesInsideALongerUtterance() throws {
        let s = try snippets(#""calendar" = "URL""#)
        XCTAssertNil(s.expansion(for: "send me your calendar please"))
        XCTAssertNil(s.expansion(for: "calendar invite"))
    }

    func testExpansionPreservesItsOwnFormattingAndCase() throws {
        let s = try snippets(#""intro" = "Morning! Quick update:""#)
        XCTAssertEqual(s.expansion(for: "intro"), "Morning! Quick update:")
    }

    func testCueWithPunctuationInTheFileStillMatches() throws {
        let s = try snippets(#""My Calendar Link." = "URL""#)
        XCTAssertEqual(s.expansion(for: "my calendar link"), "URL")
    }

    func testRejectsDuplicateCues() {
        XCTAssertThrowsError(
            try snippets(
                """
                "a" = "1"
                "A." = "2"
                """
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("duplicate snippet cue"), "\(error)")
        }
    }

    func testRejectsEmptyCue() {
        XCTAssertThrowsError(try snippets(#""" = "x""#)) { error in
            XCTAssertTrue("\(error)".contains("cannot be empty"), "\(error)")
        }
    }

    func testRejectsUnquotedExpansion() {
        XCTAssertThrowsError(try snippets(#""cue" = bare"#))
    }

    func testErrorReportsLineNumber() {
        XCTAssertThrowsError(
            try Snippets.parse("\"a\" = \"1\"\n\"a\" = \"2\"", source: "/tmp/snippets.toml")
        ) { error in
            XCTAssertTrue("\(error)".contains("/tmp/snippets.toml:2"), "\(error)")
        }
    }

    func testLoadReturnsEmptyWhenFileMissing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-snippets-missing-\(UUID().uuidString).toml")
        XCTAssertTrue(try Snippets.load(from: url).isEmpty)
    }

    func testLoadReadsFromDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-snippets-\(UUID().uuidString).toml")
        try #""cue" = "expanded""#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try Snippets.load(from: url).expansion(for: "cue"), "expanded")
    }
}

final class TranscriptProcessorTests: XCTestCase {
    func testEmptyTextPassesThrough() {
        XCTAssertEqual(TranscriptProcessor().process(""), "")
    }

    func testPlainTextIsUnchangedWithNoConfiguration() {
        XCTAssertEqual(TranscriptProcessor().process("hello world"), "hello world")
    }

    func testAppliesDictionaryCorrections() throws {
        var processor = TranscriptProcessor()
        processor.dictionary = try UserDictionary.parse("sequel -> SQL")
        XCTAssertEqual(processor.process("I know sequel"), "I know SQL")
    }

    func testSnippetWins() throws {
        var processor = TranscriptProcessor()
        processor.snippets = try Snippets.parse(#""cue" = "expanded""#)
        processor.dictionary = try UserDictionary.parse("expanded -> WRONG")
        XCTAssertEqual(processor.process("cue"), "expanded")
    }

    func testDictionaryStillAppliesWhenNoSnippetMatches() throws {
        var processor = TranscriptProcessor()
        processor.snippets = try Snippets.parse(#""cue" = "expanded""#)
        processor.dictionary = try UserDictionary.parse("sequel -> SQL")
        XCTAssertEqual(processor.process("about sequel"), "about SQL")
    }
}
