import XCTest

@testable import parrot

final class LanguageSettingTests: XCTestCase {
    func testParsesAuto() {
        XCTAssertEqual(LanguageSetting(parsing: "auto"), .auto)
        XCTAssertEqual(LanguageSetting(parsing: "AUTO"), .auto)
        XCTAssertEqual(LanguageSetting(parsing: "  auto  "), .auto)
    }

    func testParsesLanguageCodes() {
        XCTAssertEqual(LanguageSetting(parsing: "en"), .code("en"))
        XCTAssertEqual(LanguageSetting(parsing: "es"), .code("es"))
        XCTAssertEqual(LanguageSetting(parsing: "ZH"), .code("zh"))
    }

    func testParsesEnglishLanguageNames() {
        XCTAssertEqual(LanguageSetting(parsing: "spanish"), .code("es"))
        XCTAssertEqual(LanguageSetting(parsing: "Japanese"), .code("ja"))
    }

    func testRejectsNonsense() {
        XCTAssertNil(LanguageSetting(parsing: "klingon"))
        XCTAssertNil(LanguageSetting(parsing: ""))
        XCTAssertNil(LanguageSetting(parsing: "   "))
        XCTAssertNil(LanguageSetting(parsing: "zzz"))
    }

    func testDefaultIsEnglish() {
        XCTAssertEqual(LanguageSetting.default, .code("en"))
    }

    // MARK: - Decoding options

    func testAutoDetectsAndPinsNoLanguage() {
        XCTAssertTrue(LanguageSetting.auto.detectLanguage)
        XCTAssertNil(LanguageSetting.auto.whisperCode)
    }

    func testExplicitCodePinsAndDoesNotDetect() {
        let setting = LanguageSetting.code("fr")
        XCTAssertFalse(setting.detectLanguage)
        XCTAssertEqual(setting.whisperCode, "fr")
    }

    func testDisplayNames() {
        XCTAssertEqual(LanguageSetting.auto.displayName, "auto")
        XCTAssertEqual(LanguageSetting.code("de").displayName, "de")
    }
}

final class LanguageCompatibilityTests: XCTestCase {
    private let englishOnly = TranscriptionModel(
        id: "whisper-base.en",
        displayName: "Whisper Base (English)",
        engine: .whisperKit,
        whisperKitID: "openai_whisper-base.en",
        sizeMB: 145,
        languages: ["en"],
        recommended: true
    )

    private let multilingual = TranscriptionModel(
        id: "whisper-large-v3-turbo",
        displayName: "Whisper Large v3 Turbo",
        engine: .whisperKit,
        whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
        sizeMB: 1620,
        languages: ["multi"],
        recommended: false
    )

    func testEnglishOnlyDetection() {
        XCTAssertTrue(englishOnly.isEnglishOnly)
        XCTAssertFalse(multilingual.isEnglishOnly)
    }

    func testEnglishOnEnglishModelIsFine() {
        XCTAssertNil(LanguageCompatibility.problem(language: .code("en"), model: englishOnly))
    }

    func testForeignLanguageOnEnglishModelIsRejected() throws {
        let problem = try XCTUnwrap(
            LanguageCompatibility.problem(language: .code("es"), model: englishOnly)
        )
        XCTAssertTrue(problem.contains("English-only"))
        XCTAssertTrue(problem.contains("es"))
    }

    func testAutoOnEnglishModelIsRejected() throws {
        let problem = try XCTUnwrap(
            LanguageCompatibility.problem(language: .auto, model: englishOnly)
        )
        XCTAssertTrue(problem.contains("English-only"))
    }

    func testRejectionSuggestsAMultilingualModelFromTheRegistry() throws {
        let problem = try XCTUnwrap(
            LanguageCompatibility.problem(language: .code("ja"), model: englishOnly)
        )
        let suggested = try XCTUnwrap(ModelRegistry.shared.first { !$0.isEnglishOnly })
        XCTAssertTrue(
            problem.contains(suggested.id),
            "expected a multilingual suggestion in \(problem)"
        )
    }

    func testMultilingualModelAcceptsAnything() {
        XCTAssertNil(LanguageCompatibility.problem(language: .auto, model: multilingual))
        XCTAssertNil(LanguageCompatibility.problem(language: .code("es"), model: multilingual))
        XCTAssertNil(LanguageCompatibility.problem(language: .code("en"), model: multilingual))
    }
}
