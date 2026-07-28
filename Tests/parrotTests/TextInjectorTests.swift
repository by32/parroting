import XCTest

@testable import parrot

final class TextInjectorTests: XCTestCase {
    private func rejoin(_ chunks: [[UniChar]]) -> String {
        String(decoding: chunks.flatMap { $0 }, as: UTF16.self)
    }

    func testEmptyTextProducesNoChunks() {
        XCTAssertTrue(TextInjector.chunks("").isEmpty)
    }

    func testShortTextIsASingleChunk() {
        let chunks = TextInjector.chunks("hello world")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(rejoin(chunks), "hello world")
    }

    func testTextIsSplitAtTheChunkLimit() {
        let text = String(repeating: "a", count: 45)
        let chunks = TextInjector.chunks(text)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(rejoin(chunks), text)
    }

    func testExactMultipleOfChunkSizeDoesNotEmitEmptyChunk() {
        let chunks = TextInjector.chunks(String(repeating: "b", count: 40))
        XCTAssertEqual(chunks.map(\.count), [20, 20])
    }

    func testNoChunkExceedsTheLimit() {
        let text = String(repeating: "the quick brown fox ", count: 12)
        for chunk in TextInjector.chunks(text) {
            XCTAssertLessThanOrEqual(chunk.count, TextInjector.chunkSize)
        }
    }

    func testRoundTripsUnicodeText() {
        let text = "café naïve — Ω 日本語のテキスト, and then some more text to force a split"
        XCTAssertEqual(rejoin(TextInjector.chunks(text)), text)
    }

    /// A boundary landing between the halves of a surrogate pair would post two
    /// lone surrogates and corrupt the character.
    func testSurrogatePairsAreNeverSplit() {
        // 19 ASCII chars puts the 20-unit boundary inside the emoji that follows.
        let text = String(repeating: "x", count: 19) + "😀tail"
        let chunks = TextInjector.chunks(text)

        XCTAssertEqual(chunks[0].count, 19, "chunk should stop short of the pair")
        XCTAssertEqual(rejoin(chunks), text)
        for chunk in chunks {
            XCTAssertFalse(
                (0xD800...0xDBFF).contains(chunk.last ?? 0),
                "chunk ends on a high surrogate: \(chunk)"
            )
            XCTAssertFalse(
                (0xDC00...0xDFFF).contains(chunk.first ?? 0),
                "chunk starts on a low surrogate: \(chunk)"
            )
        }
    }

    func testAllEmojiTextRoundTrips() {
        let text = String(repeating: "😀", count: 15)
        let chunks = TextInjector.chunks(text)
        XCTAssertEqual(rejoin(chunks), text)
        for chunk in chunks {
            XCTAssertEqual(chunk.count % 2, 0, "surrogate pairs should stay intact")
        }
    }

    func testSurrogatePairSurvivesAChunkSizeThatCannotSplitIt() {
        // size 1 cannot hold a pair; the chunker must still make progress and
        // keep the pair together rather than looping or emitting halves.
        let chunks = TextInjector.chunks("😀😀", size: 1)
        XCTAssertEqual(rejoin(chunks), "😀😀")
        XCTAssertEqual(chunks.map(\.count), [2, 2])
    }

    func testNonPositiveChunkSizeProducesNoChunks() {
        XCTAssertTrue(TextInjector.chunks("hello", size: 0).isEmpty)
    }
}
