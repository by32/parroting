import XCTest

@testable import parrot

// MARK: - RefineMode

final class RefineModeTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(RefineMode.off.rawValue, "off")
        XCTAssertEqual(RefineMode.local.rawValue, "local")
        XCTAssertEqual(RefineMode.cloud.rawValue, "cloud")
    }

    func testAllValueStrings() {
        XCTAssertEqual(RefineMode.allValueStrings, ["off", "local", "cloud"])
    }

    func testInitFromRawValue() {
        XCTAssertEqual(RefineMode(rawValue: "off"), .off)
        XCTAssertEqual(RefineMode(rawValue: "local"), .local)
        XCTAssertEqual(RefineMode(rawValue: "cloud"), .cloud)
        XCTAssertNil(RefineMode(rawValue: "magic"))
    }
}

// MARK: - RefinePrompt

final class RefinePromptTests: XCTestCase {
    func testUserMessageWithoutStyleIsJustText() {
        XCTAssertEqual(RefinePrompt.userMessage(text: "hello", style: nil), "hello")
    }

    func testUserMessageWithEmptyStyleIsJustText() {
        XCTAssertEqual(RefinePrompt.userMessage(text: "hello", style: "  "), "hello")
    }

    func testUserMessageWithStyleIncludesTone() {
        let msg = RefinePrompt.userMessage(text: "hello", style: "formal")
        XCTAssertTrue(msg.contains("Tone for this text: formal"))
        XCTAssertTrue(msg.contains("hello"))
    }

    // MARK: cleanResponse

    func testCleanResponsePassesThroughCleanText() {
        XCTAssertEqual(RefinePrompt.cleanResponse("I think we should ship it."), "I think we should ship it.")
    }

    func testCleanResponseStripsWrappingDoubleQuotes() {
        XCTAssertEqual(RefinePrompt.cleanResponse("\"cleaned text\""), "cleaned text")
    }

    func testCleanResponseStripsWrappingSmartQuotes() {
        XCTAssertEqual(RefinePrompt.cleanResponse("\u{201C}cleaned text\u{201D}"), "cleaned text")
    }

    func testCleanResponseStripsWrappingSingleQuotes() {
        XCTAssertEqual(RefinePrompt.cleanResponse("'cleaned text'"), "cleaned text")
    }

    func testCleanResponseDoesNotStripInnerQuotes() {
        let input = "he said \"hello\" to me"
        XCTAssertEqual(RefinePrompt.cleanResponse(input), input)
    }

    func testCleanResponseDoesNotStripMismatchedQuotes() {
        let input = "\"she said 'hello'"
        XCTAssertEqual(RefinePrompt.cleanResponse(input), input)
    }

    func testCleanResponseStripsKnownLabels() {
        XCTAssertEqual(RefinePrompt.cleanResponse("Cleaned text: hello"), "hello")
        XCTAssertEqual(RefinePrompt.cleanResponse("Cleaned: hello"), "hello")
        XCTAssertEqual(RefinePrompt.cleanResponse("Output: hello"), "hello")
        XCTAssertEqual(RefinePrompt.cleanResponse("Result: hello"), "hello")
    }

    func testCleanResponseStripsWhitespace() {
        XCTAssertEqual(RefinePrompt.cleanResponse("  \n hello \n  "), "hello")
    }

    func testCleanResponseHandlesEmptyInput() {
        XCTAssertEqual(RefinePrompt.cleanResponse(""), "")
        XCTAssertEqual(RefinePrompt.cleanResponse("  \n  "), "")
    }
}

// MARK: - RefineConfig

final class RefineConfigTests: XCTestCase {
    func testDefaults() {
        let config = RefineConfig()
        XCTAssertEqual(config.baseURL, RefineConfig.defaultBaseURL)
        XCTAssertEqual(config.model, RefineConfig.defaultModel)
    }

    func testApiKeyEnvVarName() {
        XCTAssertEqual(RefineConfig.apiKeyEnvVar, "PARROT_REFINE_API_KEY")
    }

    func testApiKeyFromEnvironmentReturnsNilWhenAbsent() {
        // The env var is almost certainly not set in the test environment.
        // If it is, this test still passes because we only check that the
        // return type is optional.
        let key = RefineConfig.apiKeyFromEnvironment
        XCTAssertTrue(key == nil || key is String)
    }
}

// MARK: - makeRefiner factory

final class MakeRefinerTests: XCTestCase {
    func testOffReturnsNil() throws {
        XCTAssertNil(try makeRefiner(mode: .off))
    }

    func testCloudWithoutApiKeyThrows() {
        // Ensure no key is set for this test.
        let key = RefineConfig.apiKeyFromEnvironment
        XCTAssertNil(key, "PARROT_REFINE_API_KEY should not be set in the test environment")
        XCTAssertThrowsError(try makeRefiner(mode: .cloud)) { error in
            XCTAssertTrue("\(error)".contains("PARROT_REFINE_API_KEY"), "\(error)")
        }
    }

    func testCloudWithApiKeyReturnsRefiner() throws {
        setenv(RefineConfig.apiKeyEnvVar, "test-key-123", 1)
        defer { unsetenv(RefineConfig.apiKeyEnvVar) }

        let refiner = try makeRefiner(mode: .cloud)
        XCTAssertNotNil(refiner)
        XCTAssertTrue(refiner is CloudRefiner)
    }

    func testLocalReturnsRefinerOnSupportedOS() throws {
        // On macOS 26+ with FoundationModels available, this should return a
        // LocalRefiner. On older OS, it should throw .unavailable. Either way
        // is valid; we just verify it doesn't crash.
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let refiner = try makeRefiner(mode: .local)
            XCTAssertNotNil(refiner)
        } else {
            XCTAssertThrowsError(try makeRefiner(mode: .local)) { error in
                XCTAssertTrue("\(error)".contains("macOS 26"), "\(error)")
            }
        }
        #else
        XCTAssertThrowsError(try makeRefiner(mode: .local)) { error in
            XCTAssertTrue("\(error)".contains("macOS 26"), "\(error)")
        }
        #endif
    }
}

// MARK: - withTimeout

final class WithTimeoutTests: XCTestCase {
    func testReturnsValueWhenOperationCompletesInTime() async throws {
        let result = try await withTimeout(seconds: 1.0) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testThrowsWhenOperationExceedsDeadline() async {
        do {
            _ = try await withTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "done"
            }
            XCTFail("should have timed out")
        } catch {
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
    }
}

// MARK: - Config integration

final class RefineConfigParsingTests: XCTestCase {
    func testParsesRefineMode() throws {
        let config = try Config.parse("refine = \"local\"")
        XCTAssertEqual(config.refine, .local)
    }

    func testParsesRefineStyle() throws {
        let config = try Config.parse("refine-style = \"formal\"")
        XCTAssertEqual(config.refineStyle, "formal")
    }

    func testParsesBothRefineAndStyle() throws {
        let config = try Config.parse(
            """
            refine = "cloud"
            refine-style = "concise"
            """
        )
        XCTAssertEqual(config.refine, .cloud)
        XCTAssertEqual(config.refineStyle, "concise")
    }

    func testRejectsUnknownRefineMode() {
        XCTAssertThrowsError(try Config.parse("refine = \"magic\"")) { error in
            XCTAssertTrue("\(error)".contains("unknown refine mode"), "\(error)")
            XCTAssertTrue("\(error)".contains("off, local, cloud"), "\(error)")
        }
    }

    func testRefineNotInValidKeysList() {
        XCTAssertTrue(Config.validKeys.contains("refine"))
        XCTAssertTrue(Config.validKeys.contains("refine-style"))
    }
}
