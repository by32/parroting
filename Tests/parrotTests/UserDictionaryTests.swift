import XCTest

@testable import parrot

final class UserDictionaryParseTests: XCTestCase {
    func testEmptyFileYieldsEmptyDictionary() throws {
        XCTAssertEqual(try UserDictionary.parse(""), .empty)
        XCTAssertTrue(try UserDictionary.parse("\n\n   \n").isEmpty)
    }

    func testBareLinesBecomeBiasTerms() throws {
        let dict = try UserDictionary.parse(
            """
            Kubernetes
            Grafana
            """
        )
        XCTAssertEqual(dict.terms, ["Kubernetes", "Grafana"])
        XCTAssertTrue(dict.corrections.isEmpty)
    }

    func testArrowLinesBecomeCorrections() throws {
        let dict = try UserDictionary.parse("kuber netes -> Kubernetes")
        XCTAssertTrue(dict.terms.isEmpty)
        XCTAssertEqual(dict.corrections, [.init(from: "kuber netes", to: "Kubernetes")])
    }

    func testMixedFile() throws {
        let dict = try UserDictionary.parse(
            """
            # my vocabulary
            Kubernetes

            see quel -> SQL      # trailing comment
            Grafana
            """
        )
        XCTAssertEqual(dict.terms, ["Kubernetes", "Grafana"])
        XCTAssertEqual(dict.corrections, [.init(from: "see quel", to: "SQL")])
    }

    func testCommentsAndWhitespaceIgnored() throws {
        let dict = try UserDictionary.parse(
            """
            # leading
               Padded
            """
        )
        XCTAssertEqual(dict.terms, ["Padded"])
    }

    func testMultiWordTermsPreserved() throws {
        XCTAssertEqual(try UserDictionary.parse("Wispr Flow").terms, ["Wispr Flow"])
    }

    func testRejectsCorrectionMissingReplacement() {
        XCTAssertThrowsError(try UserDictionary.parse("typo ->")) { error in
            XCTAssertTrue("\(error)".contains("replacement text"), "\(error)")
        }
    }

    func testRejectsCorrectionMissingSource() {
        XCTAssertThrowsError(try UserDictionary.parse("-> Replacement")) { error in
            XCTAssertTrue("\(error)".contains("text to replace"), "\(error)")
        }
    }

    func testErrorReportsLineNumber() {
        XCTAssertThrowsError(
            try UserDictionary.parse("ok\n\nbad ->", source: "/tmp/dictionary.txt")
        ) { error in
            XCTAssertTrue("\(error)".contains("/tmp/dictionary.txt:3"), "\(error)")
        }
    }

    func testLoadReturnsEmptyWhenFileMissing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-dict-missing-\(UUID().uuidString).txt")
        XCTAssertEqual(try UserDictionary.load(from: url), .empty)
    }

    func testLoadReadsFromDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-dict-\(UUID().uuidString).txt")
        try "Kubernetes\nkuber netes -> Kubernetes".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let dict = try UserDictionary.load(from: url)
        XCTAssertEqual(dict.terms, ["Kubernetes"])
        XCTAssertEqual(dict.corrections.count, 1)
    }

    func testPromptTextIsCommaSeparated() throws {
        let dict = try UserDictionary.parse("Kubernetes\nGrafana\nPrometheus")
        XCTAssertEqual(dict.promptText, "Kubernetes, Grafana, Prometheus")
    }
}

final class UserDictionaryCorrectionTests: XCTestCase {
    private func correcting(_ pairs: [(String, String)], _ input: String) -> String {
        var dict = UserDictionary()
        dict.corrections = pairs.map { .init(from: $0.0, to: $0.1) }
        return dict.corrected(input)
    }

    func testNoCorrectionsLeavesTextAlone() {
        XCTAssertEqual(UserDictionary.empty.corrected("hello world"), "hello world")
    }

    func testReplacesWholeWord() {
        XCTAssertEqual(correcting([("sequel", "SQL")], "I know sequel"), "I know SQL")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(correcting([("sequel", "SQL")], "Sequel and SEQUEL"), "SQL and SQL")
    }

    func testReplacementCasingIsPreservedAsWritten() {
        XCTAssertEqual(correcting([("iphone", "iPhone")], "my Iphone"), "my iPhone")
    }

    /// The whole point of word boundaries: a short correction must not fire
    /// inside a longer word.
    func testDoesNotMatchInsideLongerWords() {
        XCTAssertEqual(correcting([("netes", "NETES")], "kubernetes"), "kubernetes")
        XCTAssertEqual(correcting([("cat", "dog")], "concatenate"), "concatenate")
    }

    func testReplacesMultiWordPhrases() {
        XCTAssertEqual(
            correcting([("kuber netes", "Kubernetes")], "we run kuber netes here"),
            "we run Kubernetes here"
        )
    }

    func testAppliesEveryOccurrence() {
        XCTAssertEqual(correcting([("a", "b")], "a and a"), "b and b")
    }

    func testAppliesCorrectionsInFileOrder() {
        XCTAssertEqual(correcting([("one", "two"), ("two", "three")], "one"), "three")
    }

    func testHandlesPunctuationAdjacentMatches() {
        XCTAssertEqual(correcting([("sequel", "SQL")], "sequel, sequel."), "SQL, SQL.")
    }

    /// Correction text is user input, so regex metacharacters must be literal.
    func testRegexMetacharactersInSourceAreLiteral() {
        XCTAssertEqual(correcting([("c++", "cpp")], "I use c++"), "I use cpp")
        XCTAssertEqual(correcting([("a.b", "X")], "a.b"), "X")
        XCTAssertEqual(correcting([("a.b", "X")], "axb"), "axb")
    }

    /// `$1` in a replacement must not be interpreted as a capture reference.
    func testDollarSignsInReplacementAreLiteral() {
        XCTAssertEqual(correcting([("price", "$100")], "the price"), "the $100")
        XCTAssertEqual(correcting([("x", "$1 and \\y")], "x"), "$1 and \\y")
    }

    func testUnicodeCorrections() {
        XCTAssertEqual(correcting([("cafe", "café")], "the cafe"), "the café")
    }
}
