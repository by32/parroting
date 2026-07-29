import XCTest

@testable import parrot

final class ConfigTests: XCTestCase {
    func testEmptyInputYieldsNoValues() throws {
        XCTAssertEqual(try Config.parse(""), Config.empty)
        XCTAssertEqual(try Config.parse("\n\n   \n"), Config.empty)
    }

    func testParsesAllKeys() throws {
        let config = try Config.parse(
            """
            model = "whisper-small.en"
            hotkey = "right-option"
            overlay = false
            """
        )
        XCTAssertEqual(config.model, "whisper-small.en")
        XCTAssertEqual(config.hotkey, .rightOption)
        XCTAssertEqual(config.overlay, false)
    }

    func testUnsetKeysStayNil() throws {
        let config = try Config.parse(#"hotkey = "fn""#)
        XCTAssertEqual(config.hotkey, .fn)
        XCTAssertNil(config.model)
        XCTAssertNil(config.overlay)
        XCTAssertNil(config.language)
    }

    func testParsesLanguageAsCodeOrName() throws {
        XCTAssertEqual(try Config.parse(#"language = "es""#).language, .code("es"))
        XCTAssertEqual(try Config.parse(#"language = "spanish""#).language, .code("es"))
        XCTAssertEqual(try Config.parse(#"language = "auto""#).language, .auto)
    }

    func testRejectsUnknownLanguage() {
        assertSyntaxError(#"language = "klingon""#, containing: "unknown language")
    }

    func testParsesSensitivity() throws {
        XCTAssertEqual(try Config.parse(#"sensitivity = "high""#).sensitivity, .high)
        XCTAssertEqual(try Config.parse(#"sensitivity = "normal""#).sensitivity, .normal)
    }

    func testRejectsUnknownSensitivity() {
        assertSyntaxError(#"sensitivity = "loud""#, containing: "unknown sensitivity")
    }

    func testIgnoresCommentsAndSurroundingWhitespace() throws {
        let config = try Config.parse(
            """
            # leading comment
              overlay   =   true    # trailing comment

            """
        )
        XCTAssertEqual(config.overlay, true)
    }

    func testHashInsideQuotesIsNotAComment() throws {
        let config = try Config.parse(##"model = "whisper#weird""##)
        XCTAssertEqual(config.model, "whisper#weird")
    }

    func testSingleQuotedStrings() throws {
        let config = try Config.parse("model = 'whisper-base.en'")
        XCTAssertEqual(config.model, "whisper-base.en")
    }

    func testLaterAssignmentWins() throws {
        let config = try Config.parse(
            """
            overlay = true
            overlay = false
            """
        )
        XCTAssertEqual(config.overlay, false)
    }

    func testAcceptsEmptyStringValue() throws {
        XCTAssertEqual(try Config.parse(#"model = """#).model, "")
    }

    // MARK: - Rejections

    func testRejectsUnknownKey() {
        assertSyntaxError(#"hotkeys = "fn""#, containing: #"unknown key "hotkeys""#)
    }

    func testRejectsUnknownHotkey() {
        assertSyntaxError(#"hotkey = "left-pinky""#, containing: "unknown hotkey")
    }

    func testRejectsUnquotedString() {
        assertSyntaxError("hotkey = fn", containing: "must be quoted")
    }

    func testRejectsUnterminatedString() {
        assertSyntaxError(#"model = "whisper"#, containing: "unterminated string")
    }

    func testRejectsNonBooleanOverlay() {
        assertSyntaxError("overlay = yes", containing: "must be true or false")
    }

    func testRejectsTables() {
        assertSyntaxError(
            """
            [general]
            hotkey = "fn"
            """,
            containing: "tables are not supported"
        )
    }

    func testRejectsLineWithoutEquals() {
        assertSyntaxError("hotkey", containing: "expected key = value")
    }

    func testRejectsMissingKey() {
        assertSyntaxError(#"= "fn""#, containing: "missing key")
    }

    func testErrorReportsLineNumberAndSource() {
        do {
            _ = try Config.parse(
                """
                # comment

                overlay = true
                bogus = "x"
                """,
                source: "/tmp/config.toml"
            )
            XCTFail("expected a syntax error")
        } catch let error as ConfigError {
            XCTAssertEqual(
                error.description,
                #"/tmp/config.toml:4: unknown key "bogus"; valid keys are "#
                    + Config.validKeys.joined(separator: ", ")
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testErrorWithoutSourceStillReportsLine() {
        do {
            _ = try Config.parse("overlay = nope")
            XCTFail("expected a syntax error")
        } catch let error as ConfigError {
            XCTAssertTrue(
                error.description.hasPrefix("line 1: "),
                "expected a line-prefixed message, got \(error.description)"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Loading

    func testLoadReturnsEmptyWhenFileMissing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-missing-\(UUID().uuidString).toml")
        XCTAssertEqual(try Config.load(from: url), Config.empty)
    }

    func testLoadReadsFileFromDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-config-\(UUID().uuidString).toml")
        try #"hotkey = "right-command""#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try Config.load(from: url).hotkey, .rightCommand)
    }

    func testLoadSurfacesParseErrorWithFilePath() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-bad-\(UUID().uuidString).toml")
        try "overlay = maybe".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try Config.load(from: url)
            XCTFail("expected a syntax error")
        } catch let error as ConfigError {
            XCTAssertTrue(
                error.description.contains(url.path),
                "expected the file path in \(error.description)"
            )
        }
    }

    // MARK: - Helpers

    private func assertSyntaxError(
        _ text: String,
        containing needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try Config.parse(text)
            XCTFail("expected a syntax error for \(text)", file: file, line: line)
        } catch let error as ConfigError {
            XCTAssertTrue(
                error.description.contains(needle),
                "expected \"\(needle)\" in \"\(error.description)\"",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
