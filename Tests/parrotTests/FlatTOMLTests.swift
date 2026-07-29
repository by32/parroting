import XCTest

@testable import parrot

final class FlatTOMLTests: XCTestCase {
    private func parse(_ text: String) throws -> [FlatTOML.Pair] {
        try FlatTOML.parse(text)
    }

    func testEmptyInputYieldsNoPairs() throws {
        XCTAssertTrue(try parse("").isEmpty)
        XCTAssertTrue(try parse("\n  \n# just a comment\n").isEmpty)
    }

    func testParsesStringsAndBools() throws {
        let pairs = try parse(
            """
            name = "value"
            flag = true
            off = false
            """
        )
        XCTAssertEqual(pairs.map(\.key), ["name", "flag", "off"])
        XCTAssertEqual(pairs[0].value, .string("value"))
        XCTAssertEqual(pairs[1].value, .bool(true))
        XCTAssertEqual(pairs[2].value, .bool(false))
    }

    func testPreservesFileOrderAndDuplicates() throws {
        let pairs = try parse(
            """
            a = "1"
            b = "2"
            a = "3"
            """
        )
        XCTAssertEqual(pairs.map(\.key), ["a", "b", "a"])
        XCTAssertEqual(pairs[2].value, .string("3"))
    }

    func testRecordsLineNumbersSkippingBlanksAndComments() throws {
        let pairs = try parse(
            """
            # comment

            a = "1"

            b = "2"
            """
        )
        XCTAssertEqual(pairs[0].at.line, 3)
        XCTAssertEqual(pairs[1].at.line, 5)
    }

    func testQuotedKeysAreUnquoted() throws {
        // Snippet cues and bundle ids need spaces and dots in keys.
        let pairs = try parse(
            """
            "my calendar link" = "https://cal.example/me"
            "com.apple.mail" = "formal"
            """
        )
        XCTAssertEqual(pairs.map(\.key), ["my calendar link", "com.apple.mail"])
    }

    func testSingleQuotesWork() throws {
        XCTAssertEqual(try parse("a = 'x'")[0].value, .string("x"))
    }

    func testHashInsideAQuotedValueIsNotAComment() throws {
        XCTAssertEqual(try parse(##"a = "x#y""##)[0].value, .string("x#y"))
    }

    func testEqualsInsideAValueIsKept() throws {
        XCTAssertEqual(try parse(#"a = "x=y=z""#)[0].value, .string("x=y=z"))
    }

    func testEmptyStringValue() throws {
        XCTAssertEqual(try parse(#"a = """#)[0].value, .string(""))
    }

    func testWhitespaceIsTrimmed() throws {
        let pairs = try parse("   a    =    \"x\"   ")
        XCTAssertEqual(pairs[0].key, "a")
        XCTAssertEqual(pairs[0].value, .string("x"))
    }

    /// A bare token is neither a string nor a bool; it is carried as `.bare` so
    /// the schema layer can say which type that particular key wanted.
    func testUnquotedTokensBecomeBare() throws {
        XCTAssertEqual(try parse("a = yes")[0].value, .bare("yes"))
    }

    // MARK: - Typed accessors

    func testStringValueOnBareReportsQuotingHint() throws {
        let pair = try parse("a = yes")[0]
        XCTAssertThrowsError(try pair.stringValue()) { error in
            XCTAssertTrue("\(error)".contains(#"a must be quoted, e.g. a = "yes""#), "\(error)")
        }
    }

    func testBoolValueOnBareReportsBoolHint() throws {
        let pair = try parse("a = yes")[0]
        XCTAssertThrowsError(try pair.boolValue()) { error in
            XCTAssertTrue("\(error)".contains(#"a must be true or false, got "yes""#), "\(error)")
        }
    }

    func testBoolValueOnStringReportsBoolHint() throws {
        let pair = try parse(#"a = "true""#)[0]
        XCTAssertThrowsError(try pair.boolValue())
    }

    func testStringValueOnBoolReportsQuotingHint() throws {
        let pair = try parse("a = true")[0]
        XCTAssertThrowsError(try pair.stringValue())
    }

    func testAccessorsReturnValuesOfTheMatchingType() throws {
        XCTAssertEqual(try parse(#"a = "x""#)[0].stringValue(), "x")
        XCTAssertTrue(try parse("a = true")[0].boolValue())
    }

    // MARK: - Rejections

    func testRejectsTables() {
        XCTAssertThrowsError(try parse("[section]")) { error in
            XCTAssertTrue("\(error)".contains("tables are not supported"), "\(error)")
        }
    }

    func testRejectsLineWithoutEquals() {
        XCTAssertThrowsError(try parse("just a line")) { error in
            XCTAssertTrue("\(error)".contains("expected key = value"), "\(error)")
        }
    }

    func testRejectsMissingKey() {
        XCTAssertThrowsError(try parse(#"= "x""#)) { error in
            XCTAssertTrue("\(error)".contains("missing key"), "\(error)")
        }
    }

    func testRejectsUnterminatedString() {
        XCTAssertThrowsError(try parse(#"a = "x"#)) { error in
            XCTAssertTrue("\(error)".contains("unterminated string"), "\(error)")
        }
    }

    func testErrorIncludesSourceAndLine() {
        XCTAssertThrowsError(
            try FlatTOML.parse("a = \"1\"\n[bad]", source: "/tmp/x.toml")
        ) { error in
            XCTAssertEqual(
                (error as? ConfigError)?.description,
                "/tmp/x.toml:2: tables are not supported; use a flat list of key = value"
            )
        }
    }
}
